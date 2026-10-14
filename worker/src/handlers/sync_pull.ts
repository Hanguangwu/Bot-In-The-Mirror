import type { AuthContext } from "../auth";
import type { Env } from "../db";
import { scanChangeLog } from "../db";
import type { HandlerResult } from "../index";

/**
 * `GET /v1/sync/pull?cursor=<int>&limit=<int>`（§5.3）。
 *
 * - `cursor` 必填（首次 0）；`limit` 可选，默认 200，上限 500。
 * - 扫描（B2）：`seq > cursor ORDER BY seq ASC LIMIT limit`（**全量扫描**，
 *   设备过滤不参与游标）。
 * - 组装：剔除 `device_id == 请求 token 的 deviceId` 的行（回声抑制，§7.3）。
 * - 游标推进（B2）：`cursor = max(本次扫描行的 seq)`；无扫描行则回显请求值；
 *   `hasMore = (扫描行数 == limit)`。**不得用 `MAX(seq)`**。
 */

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;

function errorResult(status: number, code: string, message: string): HandlerResult {
  return { status, body: { error: { code, message } } };
}

/** 非负整数解析；非法返回 null。 */
function parseNonNegativeInt(raw: string): number | null {
  if (!/^\d+$/.test(raw)) return null;
  const value = Number.parseInt(raw, 10);
  return Number.isSafeInteger(value) ? value : null;
}

/** `limit`：可选，默认 200，上限 500（超出则截断）。 */
function parseLimit(raw: string | null): number {
  if (raw === null) return DEFAULT_LIMIT;
  const value = parseNonNegativeInt(raw);
  if (value === null || value < 1) return DEFAULT_LIMIT;
  return Math.min(value, MAX_LIMIT);
}

export async function handleSyncPull(
  url: URL,
  auth: AuthContext,
  env: Env,
): Promise<HandlerResult> {
  const cursorRaw = url.searchParams.get("cursor");
  if (cursorRaw === null) {
    return errorResult(400, "invalid_cursor", "缺少 cursor 参数");
  }
  const cursor = parseNonNegativeInt(cursorRaw);
  if (cursor === null) {
    return errorResult(400, "invalid_cursor", "cursor 必须是非负整数");
  }

  const limit = parseLimit(url.searchParams.get("limit"));
  const { results: rows } = await scanChangeLog(
    env.DB,
    auth.workspaceId,
    cursor,
    limit,
  );

  // 游标 = 本次实际扫描行的 max seq（与设备过滤无关）；无扫描行则回显请求值。
  let nextCursor = cursor;
  const changes: unknown[] = [];
  for (const row of rows) {
    if (row.seq > nextCursor) nextCursor = row.seq;
    // 回声抑制：跳过发起设备自身的变更（§7.3）。
    if (row.device_id === auth.deviceId) continue;

    let payload: unknown;
    try {
      payload = JSON.parse(row.payload);
    } catch {
      // 不记录完整 payload；跳过不可解析行。
      continue;
    }

    changes.push({
      seq: row.seq,
      entityType: row.entity_type,
      entityId: row.entity_id,
      kind: row.kind,
      version: row.version,
      deviceId: row.device_id,
      updatedAt: row.updated_at,
      payload,
    });
  }

  return {
    status: 200,
    body: {
      changes,
      cursor: nextCursor,
      hasMore: rows.length === limit,
    },
  };
}
