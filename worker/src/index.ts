import { authenticate, parseBearer } from "./auth";
import type { Env } from "./db";
import { handleAuthAnonymous } from "./handlers/auth_anonymous";
import { handleSyncPull } from "./handlers/sync_pull";
import { handleSyncPush } from "./handlers/sync_push";

/**
 * 路由 + 鉴权中间件 + 错误体（§5、§8）。
 *
 * - 错误体统一 `{ error: { code, message } }`；状态码 400/401/404/405/429/500。
 * - 身份只来自 token（`authenticate`），请求体/查询串中的身份一律不信。
 * - 不记录 token 明文与完整 payload（仅请求级错误摘要）。
 */

/** 处理器统一返回：由本文件负责序列化 + CORS。 */
export interface HandlerResult {
  status: number;
  body: unknown;
}

type ReadBodyResult =
  | { ok: true; value: unknown }
  | { ok: false; status: number; code: string; message: string };

const AUTH_PATH = "/v1/auth/anonymous";
const PUSH_PATH = "/v1/sync/push";
const PULL_PATH = "/v1/sync/pull";

/** 请求体上限 1 MiB（§8）。 */
const MAX_BODY_BYTES = 1024 * 1024;

/** 基础限流保护位（§8/§14.3；不做精细配额）。 */
const RATE_LIMIT_MAX = 1000;
const RATE_LIMIT_WINDOW_MS = 60_000;
const rateBuckets = new Map<string, { count: number; resetAt: number }>();

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type",
  "Access-Control-Max-Age": "86400",
};

function errorBody(code: string, message: string): unknown {
  return { error: { code, message } };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...CORS_HEADERS,
    },
  });
}

function toResponse(result: HandlerResult): Response {
  return json(result.status, result.body);
}

function methodNotAllowed(): Response {
  return json(405, errorBody("method_not_allowed", "方法不允许"));
}

function unauthorized(): Response {
  return json(401, errorBody("unauthorized", "缺少或无效的访问令牌"));
}

function tooManyRequests(): Response {
  return json(429, errorBody("too_many_requests", "请求过于频繁，请稍后重试"));
}

function stripTrailingSlash(path: string): string {
  if (path.length > 1 && path.endsWith("/")) return path.slice(0, -1);
  return path;
}

/** 按 key 的基础滑动窗口计数；超过上限返回 true。 */
function rateLimited(key: string): boolean {
  const now = Date.now();
  const bucket = rateBuckets.get(key);
  if (bucket === undefined || bucket.resetAt <= now) {
    rateBuckets.set(key, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return false;
  }
  bucket.count += 1;
  return bucket.count > RATE_LIMIT_MAX;
}

function clientKey(request: Request): string {
  return `ip:${request.headers.get("CF-Connecting-IP") ?? "unknown"}`;
}

async function readJsonBody(request: Request): Promise<ReadBodyResult> {
  const declared = Number.parseInt(
    request.headers.get("Content-Length") ?? "",
    10,
  );
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return {
      ok: false,
      status: 400,
      code: "payload_too_large",
      message: "请求体超过 1 MiB 上限",
    };
  }

  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) {
    return {
      ok: false,
      status: 400,
      code: "payload_too_large",
      message: "请求体超过 1 MiB 上限",
    };
  }
  if (text.trim() === "") {
    return {
      ok: false,
      status: 400,
      code: "invalid_request",
      message: "请求体不能为空",
    };
  }

  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return {
      ok: false,
      status: 400,
      code: "invalid_json",
      message: "请求体不是合法 JSON",
    };
  }
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = stripTrailingSlash(url.pathname);
  const method = request.method.toUpperCase();

  if (method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (path === AUTH_PATH) {
    if (method !== "POST") return methodNotAllowed();
    if (rateLimited(clientKey(request))) return tooManyRequests();
    const parsed = await readJsonBody(request);
    if (!parsed.ok) return json(parsed.status, errorBody(parsed.code, parsed.message));
    return toResponse(await handleAuthAnonymous(parsed.value, env));
  }

  if (path === PUSH_PATH) {
    if (method !== "POST") return methodNotAllowed();
    const auth = await authenticate(env.DB, parseBearer(request));
    if (auth === null) return unauthorized();
    if (rateLimited(auth.tokenHash)) return tooManyRequests();
    const parsed = await readJsonBody(request);
    if (!parsed.ok) return json(parsed.status, errorBody(parsed.code, parsed.message));
    return toResponse(await handleSyncPush(parsed.value, auth, env));
  }

  if (path === PULL_PATH) {
    if (method !== "GET") return methodNotAllowed();
    const auth = await authenticate(env.DB, parseBearer(request));
    if (auth === null) return unauthorized();
    if (rateLimited(auth.tokenHash)) return tooManyRequests();
    return toResponse(await handleSyncPull(url, auth, env));
  }

  return json(404, errorBody("not_found", "路由不存在"));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      // 仅记录错误摘要：不记录 token 明文与完整 payload。
      console.error(
        "[sync-worker] unhandled error:",
        error instanceof Error ? error.message : typeof error,
      );
      return json(500, errorBody("internal_error", "服务内部错误"));
    }
  },
} satisfies ExportedHandler<Env>;
