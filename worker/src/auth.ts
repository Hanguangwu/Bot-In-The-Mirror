/**
 * 令牌生成 / 哈希 / 校验（§5.1、§8）。
 *
 * - 生成：32 随机字节 → 64 位十六进制明文（仅返回给客户端一次）；
 * - 存储：只存 `SHA-256(明文)` 的十六进制，D1 永不落明文；
 * - 校验：Bearer → SHA-256 → 查 `auth_tokens`（`revoked_at IS NULL`）。
 *   身份（userId/deviceId/workspaceId）**只来自 token**。
 */

const TOKEN_BYTES = 32;

/** 鉴权成功后的请求上下文；身份只来自 token。 */
export interface AuthContext {
  userId: string;
  deviceId: string;
  workspaceId: string;
  /** token 的 SHA-256 十六进制（用于限流分桶，避免在内存中留存明文）。 */
  tokenHash: string;
}

/** 字节数组 → 小写十六进制。 */
export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) {
    out += byte.toString(16).padStart(2, "0");
  }
  return out;
}

/** 生成 32 字节随机 token（64 位 hex 明文）。 */
export function generateToken(): string {
  const bytes = new Uint8Array(TOKEN_BYTES);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/** SHA-256(明文) → 64 位 hex。 */
export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return toHex(new Uint8Array(digest));
}

/** 形态校验：64 位十六进制。 */
export function isTokenShaped(token: string): boolean {
  return /^[0-9a-f]{64}$/.test(token);
}

/** 从请求头解析 Bearer 明文 token；缺失/格式非法返回 null（不区分原因）。 */
export function parseBearer(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (header === null) return null;
  const match = /^Bearer +([0-9A-Fa-f]{64})$/.exec(header.trim());
  return match === null ? null : match[1]!.toLowerCase();
}

/** 校验 token 并解析出身份；无效/已撤销返回 null。 */
export async function authenticate(
  db: D1Database,
  token: string | null,
): Promise<AuthContext | null> {
  if (token === null || !isTokenShaped(token)) return null;

  const tokenHash = await hashToken(token);
  const row = await db
    .prepare(
      `SELECT user_id, device_id, workspace_id
         FROM auth_tokens
        WHERE token_hash = ? AND revoked_at IS NULL`,
    )
    .bind(tokenHash)
    .first<{ user_id: string; device_id: string; workspace_id: string }>();

  if (row === null) return null;
  return {
    userId: row.user_id,
    deviceId: row.device_id,
    workspaceId: row.workspace_id,
    tokenHash,
  };
}
