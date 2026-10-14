import type { AuthContext } from "../auth";
import type { Env } from "../db";
import {
  applyEntityChange,
  getEntity,
  hasChangeLogOp,
  nowIso,
} from "../db";
import type { HandlerResult } from "../index";
import { accept } from "../lww";

/**
 * `POST /v1/sync/push`（§5.2）。
 *
 * 字段来源（B1，强约束）：
 * - `version` / `updatedAt` / `deletedAt` 一律取自 **payload 快照**；
 * - `deviceId` 一律取自 **token**（信封无 version/updatedAt/deviceId，一律忽略）。
 *
 * 逐条处理（顺序无关，单条失败不影响其它）：
 *   1. 结构校验（entityType 白名单、entityId === payload.id、version/updatedAt 合法）
 *      → 否则 `rejected` + `invalid_payload`；
 *   2. 所有权校验（payload.userId === token.userId）→ 否则 `rejected` + `ownership_mismatch`；
 *   3. 幂等（change_log(workspace_id, op_id) 已存在 → `applied`，不重复写）；
 *   4. LWW（§7.1）：接受则 `entities` upsert + `change_log` 追加（`db.batch()` 单次往返）；
 *      拒绝则 `conflict` + `stale_version` + 服务端版本，且**不写** `change_log`。
 */

const ENTITY_TYPES = new Set([
  "conversation",
  "message",
  "task",
  "ai_plan",
  "calendar_entry",
  "project",
]);

const KINDS = new Set(["create", "update", "delete"]);

/** 单批上限（§5.2）。 */
const MAX_BATCH_SIZE = 100;

const MAX_OP_ID_LENGTH = 256;
const MAX_ENTITY_ID_LENGTH = 256;

/** UTC ISO8601（带 Z）。 */
const ISO_UTC_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)$/;

type PushStatus = "applied" | "conflict" | "rejected";

interface PushItemResult {
  opId: string | null;
  status: PushStatus;
  reason: string | null;
  serverVersion: number | null;
  serverUpdatedAt: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIsoUtc(value: string): boolean {
  return ISO_UTC_PATTERN.test(value) && !Number.isNaN(Date.parse(value));
}

function rejected(
  opId: string | null,
  reason: "invalid_payload" | "ownership_mismatch",
): PushItemResult {
  return {
    opId,
    status: "rejected",
    reason,
    serverVersion: null,
    serverUpdatedAt: null,
  };
}

async function processOperation(
  raw: unknown,
  auth: AuthContext,
  env: Env,
): Promise<PushItemResult> {
  const opId =
    isRecord(raw) && typeof raw.opId === "string" ? raw.opId : null;

  if (!isRecord(raw)) return rejected(opId, "invalid_payload");

  const { entityType, entityId, kind, payload } = raw;
  if (opId === null || opId.length === 0 || opId.length > MAX_OP_ID_LENGTH) {
    return rejected(opId, "invalid_payload");
  }
  if (typeof entityType !== "string" || !ENTITY_TYPES.has(entityType)) {
    return rejected(opId, "invalid_payload");
  }
  if (
    typeof entityId !== "string" ||
    entityId.length === 0 ||
    entityId.length > MAX_ENTITY_ID_LENGTH
  ) {
    return rejected(opId, "invalid_payload");
  }
  if (typeof kind !== "string" || !KINDS.has(kind)) {
    return rejected(opId, "invalid_payload");
  }
  if (!isRecord(payload)) return rejected(opId, "invalid_payload");
  if (payload.id !== entityId) return rejected(opId, "invalid_payload");

  const version = payload.version;
  if (typeof version !== "number" || !Number.isInteger(version) || version < 0) {
    return rejected(opId, "invalid_payload");
  }

  const updatedAt = payload.updatedAt;
  if (typeof updatedAt !== "string" || !isIsoUtc(updatedAt)) {
    return rejected(opId, "invalid_payload");
  }

  let deletedAt: string | null = null;
  if (payload.deletedAt !== undefined && payload.deletedAt !== null) {
    if (
      typeof payload.deletedAt !== "string" ||
      !isIsoUtc(payload.deletedAt)
    ) {
      return rejected(opId, "invalid_payload");
    }
    deletedAt = payload.deletedAt;
  }

  // 所有权：身份只来自 token。
  if (typeof payload.userId !== "string" || payload.userId !== auth.userId) {
    return rejected(opId, "ownership_mismatch");
  }

  // 幂等：(workspace_id, op_id) 唯一；已生效则直接 applied，不重复写。
  if (await hasChangeLogOp(env.DB, auth.workspaceId, opId)) {
    const current = await getEntity(env.DB, auth.workspaceId, entityType, entityId);
    return {
      opId,
      status: "applied",
      reason: null,
      serverVersion: current?.version ?? version,
      serverUpdatedAt: current?.updated_at ?? updatedAt,
    };
  }

  const stored = await getEntity(env.DB, auth.workspaceId, entityType, entityId);
  const accepted = accept(
    { version, updatedAt },
    stored === null
      ? null
      : { version: stored.version, updatedAt: stored.updated_at },
  );

  if (!accepted) {
    // 服务端未变：不写 change_log。
    return {
      opId,
      status: "conflict",
      reason: "stale_version",
      serverVersion: stored!.version,
      serverUpdatedAt: stored!.updated_at,
    };
  }

  const createdAt =
    typeof payload.createdAt === "string" ? payload.createdAt : nowIso();

  await applyEntityChange(env.DB, {
    workspaceId: auth.workspaceId,
    entityType,
    entityId,
    userId: auth.userId,
    deviceId: auth.deviceId,
    version,
    createdAt,
    updatedAt,
    deletedAt,
    kind,
    opId,
    payloadJson: JSON.stringify(payload),
  });

  return {
    opId,
    status: "applied",
    reason: null,
    serverVersion: version,
    serverUpdatedAt: updatedAt,
  };
}

export async function handleSyncPush(
  body: unknown,
  auth: AuthContext,
  env: Env,
): Promise<HandlerResult> {
  if (!isRecord(body) || !Array.isArray(body.operations)) {
    return {
      status: 400,
      body: {
        error: { code: "invalid_request", message: "operations 必须为数组" },
      },
    };
  }

  if (body.operations.length > MAX_BATCH_SIZE) {
    return {
      status: 400,
      body: {
        error: {
          code: "batch_too_large",
          message: `单批操作数不得超过 ${MAX_BATCH_SIZE} 条`,
        },
      },
    };
  }

  const results: PushItemResult[] = [];
  for (const operation of body.operations) {
    results.push(await processOperation(operation, auth, env));
  }

  // B/A3：push 不返回游标。
  return { status: 200, body: { results } };
}
