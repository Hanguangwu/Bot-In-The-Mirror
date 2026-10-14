import { generateToken, hashToken } from "../auth";
import type { Env } from "../db";
import { nowIso } from "../db";
import type { HandlerResult } from "../index";

/**
 * `POST /v1/auth/anonymous`（§5.1）：注册/换发匿名工作区令牌。
 *
 * - 校验身份：非空、长度 ≤ 128、字符白名单 `[A-Za-z0-9_-]`；否则 400 `invalid_identity`。
 * - 幂等：`users` upsert；无 workspace 则新建 `workspaces` + `workspace_members(owner)`；
 *   `devices` upsert；每次调用换发新 token（旧 token 若未撤销仍有效）。
 * - 只存 `SHA-256(token)`；明文仅在此响应中返回一次。
 */

const ID_PATTERN = /^[A-Za-z0-9_-]+$/;
const MAX_ID_LENGTH = 128;

function errorResult(status: number, code: string, message: string): HandlerResult {
  return { status, body: { error: { code, message } } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** 身份字段校验（§5.1）。 */
export function isValidIdentity(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= MAX_ID_LENGTH &&
    ID_PATTERN.test(value)
  );
}

/** 取该 userId 已有工作区；无则新建（含 owner 成员行）。 */
async function resolveWorkspace(
  env: Env,
  userId: string,
  now: string,
): Promise<string> {
  const existing = await env.DB.prepare(
    `SELECT workspace_id FROM workspace_members
      WHERE user_id = ?
      ORDER BY created_at ASC, workspace_id ASC
      LIMIT 1`,
  )
    .bind(userId)
    .first<{ workspace_id: string }>();
  if (existing !== null) return existing.workspace_id;

  const workspaceId = crypto.randomUUID();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO workspaces (id, owner_user_id, created_at, updated_at)
       VALUES (?, ?, ?, ?)`,
    ).bind(workspaceId, userId, now, now),
    env.DB.prepare(
      `INSERT INTO workspace_members (workspace_id, user_id, role, created_at)
       VALUES (?, ?, 'owner', ?)`,
    ).bind(workspaceId, userId, now),
  ]);
  return workspaceId;
}

export async function handleAuthAnonymous(
  body: unknown,
  env: Env,
): Promise<HandlerResult> {
  if (!isRecord(body)) {
    return errorResult(400, "invalid_identity", "请求体必须为对象");
  }
  const { userId, deviceId } = body;
  if (!isValidIdentity(userId) || !isValidIdentity(deviceId)) {
    return errorResult(
      400,
      "invalid_identity",
      "userId/deviceId 必须为非空、≤128 且仅含 [A-Za-z0-9_-] 的字符串",
    );
  }

  const now = nowIso();
  const workspaceId = await resolveWorkspace(env, userId, now);

  const token = generateToken();
  const tokenHash = await hashToken(token);

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO users (id, created_at, updated_at) VALUES (?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at`,
    ).bind(userId, now, now),
    env.DB.prepare(
      `INSERT INTO devices (id, user_id, workspace_id, last_sync_at, revoked_at, created_at)
       VALUES (?, ?, ?, NULL, NULL, ?)
       ON CONFLICT(id) DO UPDATE SET
         user_id = excluded.user_id,
         workspace_id = excluded.workspace_id`,
    ).bind(deviceId, userId, workspaceId, now),
    env.DB.prepare(
      `INSERT INTO auth_tokens (token_hash, user_id, device_id, workspace_id, created_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, NULL)`,
    ).bind(tokenHash, userId, deviceId, workspaceId, now),
  ]);

  return {
    status: 200,
    body: { token, userId, workspaceId, deviceId },
  };
}
