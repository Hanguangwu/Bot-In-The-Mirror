import { describe, expect, it } from "vitest";

import { accept, compareIso, normalizeIso } from "../src/lww";

const T1 = "2026-01-01T00:00:00.000Z";
const T2 = "2026-01-02T00:00:00.000Z";

describe("LWW 纯函数（§7.1）", () => {
  it("首写：stored 为 null 一律接受", () => {
    expect(accept({ version: 1, updatedAt: T1 }, null)).toBe(true);
    expect(accept({ version: 0, updatedAt: T1 }, null)).toBe(true);
  });

  it("version 更大接受、更小拒绝（忽略 updatedAt）", () => {
    expect(accept({ version: 3, updatedAt: T1 }, { version: 2, updatedAt: T2 })).toBe(true);
    expect(accept({ version: 1, updatedAt: T2 }, { version: 2, updatedAt: T1 })).toBe(false);
  });

  it("version 相等时比 updatedAt：更晚接受、更早拒绝、相同拒绝", () => {
    expect(accept({ version: 2, updatedAt: T2 }, { version: 2, updatedAt: T1 })).toBe(true);
    expect(accept({ version: 2, updatedAt: T1 }, { version: 2, updatedAt: T2 })).toBe(false);
    expect(accept({ version: 2, updatedAt: T1 }, { version: 2, updatedAt: T1 })).toBe(false);
  });

  it("删除与更新同规则（墓碑不享有额外优先级）", () => {
    // 墓碑（通常带更晚 updatedAt）在 version 更高时被接受。
    expect(accept({ version: 5, updatedAt: T2 }, { version: 4, updatedAt: T2 })).toBe(true);
    // 低版本墓碑被拒。
    expect(accept({ version: 3, updatedAt: T2 }, { version: 4, updatedAt: T1 })).toBe(false);
  });

  it("微秒精度按时刻比较（不是裸字符串比较）", () => {
    const base = "2026-01-01T00:00:00.000Z";
    const plusOneMicro = "2026-01-01T00:00:00.000001Z";
    expect(compareIso(plusOneMicro, base)).toBeGreaterThan(0);
    expect(compareIso(base, plusOneMicro)).toBeLessThan(0);
    expect(accept({ version: 1, updatedAt: plusOneMicro }, { version: 1, updatedAt: base })).toBe(true);
    expect(accept({ version: 1, updatedAt: base }, { version: 1, updatedAt: plusOneMicro })).toBe(false);
  });

  it("毫秒/微秒不同位数归一化后等价比较", () => {
    expect(compareIso("2026-01-01T00:00:00Z", "2026-01-01T00:00:00.000Z")).toBe(0);
    expect(compareIso("2026-01-01T00:00:00.5Z", "2026-01-01T00:00:00.500Z")).toBe(0);
    expect(compareIso("2026-01-01T00:00:00.123456Z", "2026-01-01T00:00:00.123456Z")).toBe(0);
    expect(compareIso("2026-01-01T00:00:00.123456Z", "2026-01-01T00:00:00.123457Z")).toBeLessThan(0);
    // 归一化为定宽可比较串。
    expect(normalizeIso("2026-01-01T00:00:00Z")).toBe(
      normalizeIso("2026-01-01T00:00:00.000000Z"),
    );
  });

  it("带时区偏移的时间按时刻比较（不抛错）", () => {
    const a = "2026-01-01T08:00:00+08:00";
    const b = "2026-01-01T00:00:00Z";
    expect(compareIso(a, b)).toBe(0); // 同一时刻
    expect(accept({ version: 1, updatedAt: a }, { version: 1, updatedAt: b })).toBe(false);
    expect(
      accept({ version: 1, updatedAt: b }, { version: 1, updatedAt: a }),
    ).toBe(false);
  });
});
