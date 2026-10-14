/**
 * LWW 判定（纯函数，§7.1）。与客户端 `lib/domain/sync/lww.dart` 同语义。
 *
 * `accept(incoming, stored)` 当且仅当：
 *   `stored == null` 或 `incoming.version > stored.version`
 *   或（`incoming.version == stored.version` 且 `incoming.updatedAt > stored.updatedAt`）。
 *
 * 删除与更新同规则（不额外「删除必胜」）；字段级合并后置。
 */

/** LWW 比较所需的最小快照视图。 */
export interface Versioned {
  version: number;
  /** 协议时间：UTC ISO8601（带 Z）。 */
  updatedAt: string;
}

/**
 * 将协议时间归一化为定宽、可字典序比较的字符串（等价于时刻比较）。
 *
 * 客户端 `toIso8601String()`（UTC）小数位在 3（毫秒）或 6（微秒非零）之间浮动，
 * 直接字符串比较会把 `…:00.000Z` 排在 `…:00.000001Z` 之后（错误）。
 * 这里统一换算为「epoch 微秒」定宽串，任何合法 ISO8601（含时区偏移）都可比较。
 * 无法解析的输入原样返回（defensive；协议保证 UTC+Z）。
 */
export function normalizeIso(value: string): string {
  const match =
    /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?$/.exec(
      value,
    );
  if (match === null) return value;

  const seconds = match[1]!;
  const fraction = match[2] ?? "";
  const offset = match[3] ?? "Z";

  const baseMs = Date.parse(`${seconds}${offset}`);
  if (Number.isNaN(baseMs)) return value;

  const micros = Number.parseInt((fraction + "000000").slice(0, 6), 10);
  const totalMicros = BigInt(baseMs) * 1000n + BigInt(micros);
  return totalMicros.toString().padStart(20, "0");
}

/** 比较两个协议时间：a 晚于 b 返回正数，早于返回负数，相同返回 0。 */
export function compareIso(a: string, b: string): number {
  if (a === b) return 0;
  const na = normalizeIso(a);
  const nb = normalizeIso(b);
  if (na === nb) return 0;
  return na < nb ? -1 : 1;
}

/** LWW 接受判定；`stored == null` 表示首写。 */
export function accept(incoming: Versioned, stored: Versioned | null): boolean {
  if (stored === null) return true;
  if (incoming.version > stored.version) return true;
  if (incoming.version === stored.version) {
    return compareIso(incoming.updatedAt, stored.updatedAt) > 0;
  }
  return false;
}
