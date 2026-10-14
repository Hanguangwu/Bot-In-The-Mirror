import { describe, expect, it } from "vitest";

import {
  newDevice,
  newWorkspace,
  operation,
  pull,
  push,
  request,
  taskSnapshot,
} from "./helpers";

/** 两设备共享同一工作区（同一 userId，不同 deviceId）。 */
async function setupTwoDevices() {
  const { session: a, userId } = await newWorkspace();
  const b = await newDevice(userId);
  expect(b.workspaceId).toBe(a.workspaceId);
  return { a, b, userId };
}

describe("GET /v1/sync/pull（§5.3）", () => {
  it("cursor=0 首次全量：按 seq 升序返回，cursor=本次最大 seq", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);
    await push(a.token, [
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
    ]);

    const res = await pull(b.token, 0);
    expect(res.status).toBe(200);
    expect(res.body.changes.map((c: any) => c.entityId)).toEqual([
      "task-1",
      "task-2",
    ]);

    const seqs = res.body.changes.map((c: any) => c.seq);
    expect(seqs).toEqual([...seqs].sort((x: number, y: number) => x - y));
    expect(res.body.cursor).toBe(seqs[seqs.length - 1]);
    expect(res.body.hasMore).toBe(false);

    const change = res.body.changes[0];
    expect(change).toMatchObject({
      entityType: "task",
      entityId: "task-1",
      kind: "create",
      version: 1,
      deviceId: a.deviceId,
      updatedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(change.payload).toMatchObject({ id: "task-1", title: "写周报" });
  });

  it("seq > cursor 过滤：已读变更不重复返回", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);
    const first = await pull(b.token, 0);
    const cursor = first.body.cursor;

    await push(a.token, [
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
    ]);

    const second = await pull(b.token, cursor);
    expect(second.body.changes.map((c: any) => c.entityId)).toEqual(["task-2"]);
    expect(second.body.cursor).toBeGreaterThan(cursor);
  });

  it("B2：limit/hasMore 语义 + 游标 = 本次扫描最大 seq（非 MAX(seq)，不漏读）", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
      operation("op-3", "task-3", "create", taskSnapshot({ userId, id: "task-3" })),
    ]);

    const page1 = await pull(b.token, 0, 2);
    expect(page1.body.changes).toHaveLength(2);
    expect(page1.body.hasMore).toBe(true);
    // 游标必须停在「本次扫描的最大 seq」（第 2 行），而不是全局 MAX(seq)。
    expect(page1.body.cursor).toBe(page1.body.changes[1].seq);

    const page2 = await pull(b.token, page1.body.cursor, 2);
    expect(page2.body.changes.map((c: any) => c.entityId)).toEqual(["task-3"]);
    expect(page2.body.hasMore).toBe(false);
    expect(page2.body.cursor).toBe(page2.body.changes[0].seq);
  });

  it("B2 并发写入不漏读：扫描与下一次写入之间插入更高 seq 仍被读到", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);

    const page1 = await pull(b.token, 0, 1);
    expect(page1.body.changes).toHaveLength(1);
    expect(page1.body.hasMore).toBe(true);
    const cursor = page1.body.cursor;

    // 扫描之后并发写入两条（seq 更高）。
    await push(a.token, [
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
      operation("op-3", "task-3", "create", taskSnapshot({ userId, id: "task-3" })),
    ]);

    const page2 = await pull(b.token, cursor, 10);
    expect(page2.body.changes.map((c: any) => c.entityId)).toEqual([
      "task-2",
      "task-3",
    ]);
  });

  it("B2 回声抑制：发起设备变更被过滤，但游标仍推进（设备过滤不参与游标）", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);
    await push(a.token, [
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
    ]);

    // B 视角：能看到 A 的全部变更，游标推进到最大扫描 seq。
    const fromB = await pull(b.token, 0);
    expect(fromB.body.changes).toHaveLength(2);
    const maxSeq = fromB.body.cursor;

    // A 视角：自己产生的变更全部被过滤，但游标同样推进到 maxSeq。
    const fromA = await pull(a.token, 0);
    expect(fromA.body.changes).toHaveLength(0);
    expect(fromA.body.cursor).toBe(maxSeq);
    expect(fromA.body.hasMore).toBe(false);

    // 后续写入来自 B，A 仍能读到。
    await push(b.token, [
      operation("op-3", "task-3", "create", taskSnapshot({ userId, id: "task-3" })),
    ]);
    const fromAAgain = await pull(a.token, fromA.body.cursor);
    expect(fromAAgain.body.changes.map((c: any) => c.entityId)).toEqual([
      "task-3",
    ]);
    expect(fromAAgain.body.changes[0].deviceId).toBe(b.deviceId);
  });

  it("无扫描行时回显请求 cursor", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);
    const first = await pull(b.token, 0);
    const cursor = first.body.cursor;

    const again = await pull(b.token, cursor);
    expect(again.status).toBe(200);
    expect(again.body.changes).toEqual([]);
    expect(again.body.cursor).toBe(cursor);
    expect(again.body.hasMore).toBe(false);
  });

  it("limit 默认 200、上限 500（超出截断，不报错）", async () => {
    const { a, b, userId } = await setupTwoDevices();

    await push(a.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
    ]);

    const huge = await pull(b.token, 0, 100000);
    expect(huge.status).toBe(200);
    expect(huge.body.changes).toHaveLength(1);
    expect(huge.body.hasMore).toBe(false);

    const noLimit = await request("/v1/sync/pull?cursor=0", {
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(noLimit.status).toBe(200);
    expect((await noLimit.json<any>()).changes).toHaveLength(1);
  });

  it("invalid_cursor：缺失 / 负数 / 非数字 → 400", async () => {
    const { b } = await setupTwoDevices();

    const missing = await request("/v1/sync/pull", {
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(missing.status).toBe(400);
    expect((await missing.json<any>()).error.code).toBe("invalid_cursor");

    for (const cursor of ["abc", "-1", "1.5", ""]) {
      const res = await request(
        `/v1/sync/pull?cursor=${encodeURIComponent(cursor)}`,
        { headers: { Authorization: `Bearer ${b.token}` } },
      );
      expect(res.status).toBe(400);
      expect((await res.json<any>()).error.code).toBe("invalid_cursor");
    }
  });

  it("工作区隔离：不同 userId 的变更互不可见", async () => {
    const { session: a1, userId: userA } = await newWorkspace();
    const a2 = await newDevice(userA);
    const { session: c1, userId: userC } = await newWorkspace();
    const c2 = await newDevice(userC);

    await push(a1.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId: userA, id: "task-1" })),
    ]);
    await push(c1.token, [
      operation("op-2", "task-2", "create", taskSnapshot({ userId: userC, id: "task-2" })),
    ]);

    const fromA = await pull(a2.token, 0);
    expect(fromA.body.changes.map((x: any) => x.entityId)).toEqual(["task-1"]);

    const fromC = await pull(c2.token, 0);
    expect(fromC.body.changes.map((x: any) => x.entityId)).toEqual(["task-2"]);
  });
});
