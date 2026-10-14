import { env, SELF } from "cloudflare:test";

/** 测试用共享工具：所有请求经 `SELF.fetch` 走完整 Worker 路由（不触真实网络）。 */

export const BASE_URL = "https://sync.test";

export interface Session {
  token: string;
  userId: string;
  workspaceId: string;
  deviceId: string;
}

export interface ApiResult {
  status: number;
  body: any;
}

let idCounter = 0;

/** 生成全仓唯一身份（本地 D1 在同一测试进程内不隔离，测试必须自建工作区）。 */
export function uniqueId(prefix: string): string {
  idCounter += 1;
  return `${prefix}-${idCounter}-${Math.floor(Math.random() * 1_000_000)}`;
}

async function readJson(res: Response): Promise<any> {
  const text = await res.text();
  if (text.length === 0) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export async function request(
  path: string,
  init?: RequestInit,
): Promise<Response> {
  return SELF.fetch(`${BASE_URL}${path}`, init);
}

function jsonInit(body: unknown, token?: string): RequestInit {
  const headers: Record<string, string> = {
    "Content-Type": "application/json; charset=utf-8",
  };
  if (token !== undefined) headers.Authorization = `Bearer ${token}`;
  return { method: "POST", headers, body: JSON.stringify(body) };
}

/** 调用注册端点，返回状态与解析后的响应体（不抛错，便于断言错误分支）。 */
export async function register(
  userId: unknown,
  deviceId: unknown,
): Promise<ApiResult> {
  const res = await request("/v1/auth/anonymous", jsonInit({ userId, deviceId }));
  return { status: res.status, body: await readJson(res) };
}

/** 注册并断言成功，返回会话。 */
export async function registerOk(
  userId: string,
  deviceId: string,
): Promise<Session> {
  const res = await register(userId, deviceId);
  if (res.status !== 200) {
    throw new Error(`register failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  return res.body as Session;
}

/** 新建一个独立工作区（全局唯一 userId/deviceId）。 */
export async function newWorkspace(prefix = "user"): Promise<{
  session: Session;
  userId: string;
}> {
  const userId = uniqueId(prefix);
  const session = await registerOk(userId, uniqueId("device"));
  return { session, userId };
}

/** 在同一工作区（同一 userId）下再注册一台设备。 */
export async function newDevice(userId: string): Promise<Session> {
  return registerOk(userId, uniqueId("device"));
}

export async function push(
  token: string,
  operations: unknown[],
): Promise<ApiResult> {
  const res = await request("/v1/sync/push", jsonInit({ operations }, token));
  return { status: res.status, body: await readJson(res) };
}

export async function pull(
  token: string,
  cursor: number | string,
  limit?: number,
): Promise<ApiResult> {
  const params = new URLSearchParams({ cursor: String(cursor) });
  if (limit !== undefined) params.set("limit", String(limit));
  const res = await request(`/v1/sync/pull?${params.toString()}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return { status: res.status, body: await readJson(res) };
}

/** Task 实体快照（M2a `toSyncJson` 语义：Syncable 七字段 + 专有字段）。 */
export function taskSnapshot(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id: "task-1",
    userId: "user-1",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    version: 1,
    deviceId: "device-1",
    title: "写周报",
    status: "todo",
    priority: "medium",
    sortOrder: 0,
    ...overrides,
  };
}

/** 构造 push 操作条目（信封**不含** version/updatedAt/deviceId）。 */
export function operation(
  opId: string,
  entityId: string,
  kind: string,
  payload: unknown,
  entityType = "task",
): Record<string, unknown> {
  return { opId, entityType, entityId, kind, payload };
}

/** 读取某工作区内某实体行。 */
export function readEntity(
  workspaceId: string,
  entityType: string,
  entityId: string,
) {
  return env.DB.prepare(
    `SELECT * FROM entities
      WHERE workspace_id = ? AND entity_type = ? AND entity_id = ?`,
  )
    .bind(workspaceId, entityType, entityId)
    .first<Record<string, any>>();
}

/** 读取某工作区内某 op_id 的变更日志行。 */
export function readChangeLog(workspaceId: string, opId: string) {
  return env.DB.prepare(
    "SELECT * FROM change_log WHERE workspace_id = ? AND op_id = ?",
  )
    .bind(workspaceId, opId)
    .first<Record<string, any>>();
}

/** 计数某工作区内某实体的变更日志条数。 */
export async function countChangeLogForEntity(
  workspaceId: string,
  entityId: string,
): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM change_log WHERE workspace_id = ? AND entity_id = ?",
  )
    .bind(workspaceId, entityId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}
