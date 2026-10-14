import { describe, expect, it } from "vitest";

import {
  countChangeLogForEntity,
  newWorkspace,
  operation,
  push,
  readChangeLog,
  readEntity,
  registerOk,
  request,
  taskSnapshot,
} from "./helpers";

const T1 = "2026-01-01T00:00:00.000Z";
const T2 = "2026-02-02T00:00:00.000Z";
const T3 = "2026-03-03T00:00:00.000Z";

describe("POST /v1/sync/push（§5.2）", () => {
  it("首写：写 entities + change_log，version/updated_at 取自 payload、device_id 取自 token", async () => {
    const { session, userId } = await newWorkspace();

    const payload = taskSnapshot({
      userId,
      deviceId: "device-evil", // 伪造设备，必须被忽略
      version: 7,
      updatedAt: T3,
    });
    const res = await push(session.token, [
      operation("op-1", "task-1", "create", payload),
    ]);

    expect(res.status).toBe(200);
    expect(res.body.results).toHaveLength(1);
    expect(res.body.results[0]).toEqual({
      opId: "op-1",
      status: "applied",
      reason: null,
      serverVersion: 7,
      serverUpdatedAt: T3,
    });
    // A3：push 响应不含 cursor。
    expect(res.body).not.toHaveProperty("cursor");

    const entity = await readEntity(session.workspaceId, "task", "task-1");
    expect(entity).not.toBeNull();
    expect(entity!.version).toBe(7); // 取自 payload
    expect(entity!.updated_at).toBe(T3); // 取自 payload
    expect(entity!.created_at).toBe(T1);
    expect(entity!.deleted_at).toBeNull();
    expect(entity!.user_id).toBe(userId);
    expect(entity!.device_id).toBe(session.deviceId); // 取自 token，非 payload.deviceId
    expect(JSON.parse(entity!.payload).deviceId).toBe("device-evil"); // 快照原样保存
    expect(JSON.parse(entity!.payload).title).toBe("写周报");

    const log = await readChangeLog(session.workspaceId, "op-1");
    expect(log).not.toBeNull();
    expect(log!.kind).toBe("create");
    expect(log!.version).toBe(7); // 取自 payload
    expect(log!.updated_at).toBe(T3); // 取自 payload
    expect(log!.device_id).toBe(session.deviceId); // 取自 token
    expect(log!.entity_type).toBe("task");
  });

  it("同 op_id 重放幂等：返回 applied，不重复写、不改写实体", async () => {
    const { session, userId } = await newWorkspace();

    const first = await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, version: 7, updatedAt: T3 }),
      ),
    ]);
    expect(first.body.results[0].status).toBe("applied");

    const replay = await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, version: 99, updatedAt: "2030-01-01T00:00:00.000Z" }),
      ),
    ]);
    expect(replay.status).toBe(200);
    expect(replay.body.results[0].status).toBe("applied");

    const rows = await countChangeLogForEntity(session.workspaceId, "task-1");
    expect(rows).toBe(1);

    const entity = await readEntity(session.workspaceId, "task", "task-1");
    expect(entity!.version).toBe(7); // 重放未改写实体
  });

  it("stale_version → conflict，附服务端版本且不写 change_log", async () => {
    const { session, userId } = await newWorkspace();

    await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, version: 2, updatedAt: T2 }),
      ),
    ]);

    const res = await push(session.token, [
      operation(
        "op-2",
        "task-1",
        "update",
        taskSnapshot({ userId, version: 1, updatedAt: T1 }),
      ),
    ]);

    expect(res.status).toBe(200);
    expect(res.body.results[0]).toEqual({
      opId: "op-2",
      status: "conflict",
      reason: "stale_version",
      serverVersion: 2,
      serverUpdatedAt: T2,
    });

    // 服务端未变：不写 change_log（只应有 op-1 一条）。
    expect(await countChangeLogForEntity(session.workspaceId, "task-1")).toBe(1);

    const entity = await readEntity(session.workspaceId, "task", "task-1");
    expect(entity!.version).toBe(2);
    expect(entity!.updated_at).toBe(T2);
  });

  it("version 相等时比 updatedAt：更新则 applied，相同则 conflict", async () => {
    const { session, userId } = await newWorkspace();

    await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, version: 2, updatedAt: T2 }),
      ),
    ]);

    const newer = await push(session.token, [
      operation(
        "op-2",
        "task-1",
        "update",
        taskSnapshot({ userId, version: 2, updatedAt: T3 }),
      ),
    ]);
    expect(newer.body.results[0].status).toBe("applied");
    expect(newer.body.results[0].serverVersion).toBe(2);
    expect(newer.body.results[0].serverUpdatedAt).toBe(T3);

    const same = await push(session.token, [
      operation(
        "op-3",
        "task-1",
        "update",
        taskSnapshot({ userId, version: 2, updatedAt: T3 }),
      ),
    ]);
    expect(same.body.results[0].status).toBe("conflict");
    expect(same.body.results[0].reason).toBe("stale_version");
    expect(same.body.results[0].serverUpdatedAt).toBe(T3);

    expect(await countChangeLogForEntity(session.workspaceId, "task-1")).toBe(2);
  });

  it("delete 快照：写墓碑 deleted_at 与 kind=delete（删除与更新同 LWW 规则）", async () => {
    const { session, userId } = await newWorkspace();

    await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, version: 1, updatedAt: T1 }),
      ),
    ]);

    const res = await push(session.token, [
      operation(
        "op-2",
        "task-1",
        "delete",
        taskSnapshot({ userId, version: 2, updatedAt: T2, deletedAt: T2 }),
      ),
    ]);
    expect(res.body.results[0].status).toBe("applied");

    const entity = await readEntity(session.workspaceId, "task", "task-1");
    expect(entity!.deleted_at).toBe(T2);
    expect(entity!.version).toBe(2);

    const log = await readChangeLog(session.workspaceId, "op-2");
    expect(log!.kind).toBe("delete");
  });

  it("entityId != payload.id → rejected invalid_payload", async () => {
    const { session, userId } = await newWorkspace();

    const res = await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId, id: "task-other" }),
      ),
    ]);
    expect(res.body.results[0]).toMatchObject({
      opId: "op-1",
      status: "rejected",
      reason: "invalid_payload",
    });
    expect(await readEntity(session.workspaceId, "task", "task-1")).toBeNull();
  });

  it("entityType 白名单外 → rejected invalid_payload", async () => {
    const { session, userId } = await newWorkspace();

    const res = await push(session.token, [
      operation(
        "op-1",
        "health-1",
        "create",
        taskSnapshot({ userId, id: "health-1" }),
        "health_record",
      ),
    ]);
    expect(res.body.results[0]).toMatchObject({
      opId: "op-1",
      status: "rejected",
      reason: "invalid_payload",
    });
  });

  it("payload.userId 与 token 不符 → rejected ownership_mismatch", async () => {
    const { session } = await newWorkspace();

    const res = await push(session.token, [
      operation(
        "op-1",
        "task-1",
        "create",
        taskSnapshot({ userId: "someone-else" }),
      ),
    ]);
    expect(res.body.results[0]).toMatchObject({
      opId: "op-1",
      status: "rejected",
      reason: "ownership_mismatch",
    });
    expect(await readEntity(session.workspaceId, "task", "task-1")).toBeNull();
  });

  it("结构非法（缺 version / updatedAt 非 ISO / kind 非法 / opId 缺失）→ rejected invalid_payload", async () => {
    const { session, userId } = await newWorkspace();

    const noVersion = taskSnapshot({ userId });
    delete noVersion.version;

    const badTime = taskSnapshot({ userId, updatedAt: "2026/01/01 00:00" });

    const res = await push(session.token, [
      operation("op-1", "task-1", "create", noVersion),
      operation("op-2", "task-2", "create", badTime),
      operation("op-3", "task-3", "destroy", taskSnapshot({ userId, id: "task-3" })),
      {
        entityType: "task",
        entityId: "task-4",
        kind: "create",
        payload: taskSnapshot({ userId, id: "task-4" }),
      },
    ]);

    expect(res.status).toBe(200);
    expect(res.body.results).toHaveLength(4);
    for (const result of res.body.results) {
      expect(result.status).toBe("rejected");
      expect(result.reason).toBe("invalid_payload");
    }
    expect(res.body.results[3].opId).toBeNull();
  });

  it("批量 > 100 → 400 batch_too_large", async () => {
    const { session, userId } = await newWorkspace();

    const operations = Array.from({ length: 101 }, (_, index) =>
      operation(
        `op-${index}`,
        `task-${index}`,
        "create",
        taskSnapshot({ userId, id: `task-${index}` }),
      ),
    );

    const res = await push(session.token, operations);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("batch_too_large");

    // 恰好 100 条应通过。
    const ok = await push(session.token, operations.slice(0, 100));
    expect(ok.status).toBe(200);
    expect(ok.body.results).toHaveLength(100);
  });

  it("单条失败不影响同批其它条目", async () => {
    const { session, userId } = await newWorkspace();

    const res = await push(session.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
      operation(
        "op-2",
        "task-2",
        "create",
        taskSnapshot({ userId: "hacker", id: "task-2" }),
      ),
      operation("op-3", "task-3", "create", taskSnapshot({ userId, id: "task-3" })),
    ]);

    expect(res.body.results.map((r: any) => r.status)).toEqual([
      "applied",
      "rejected",
      "applied",
    ]);
  });

  it("信封不参与 LWW：请求无 version/updatedAt/deviceId 字段", async () => {
    const { session, userId } = await newWorkspace();

    // 信封被塞入伪造字段，服务端必须忽略（B1）。
    const res = await push(session.token, [
      {
        opId: "op-1",
        entityType: "task",
        entityId: "task-1",
        kind: "create",
        version: 999,
        updatedAt: "2030-01-01T00:00:00.000Z",
        deviceId: "device-evil",
        payload: taskSnapshot({
          userId,
          version: 3,
          updatedAt: T2,
          deviceId: "device-evil",
        }),
      },
    ]);
    expect(res.body.results[0]).toMatchObject({
      status: "applied",
      serverVersion: 3,
      serverUpdatedAt: T2,
    });

    const entity = await readEntity(session.workspaceId, "task", "task-1");
    expect(entity!.version).toBe(3); // 信封的 999 未被采用
    expect(entity!.device_id).toBe(session.deviceId);
  });
});

describe("路由与错误体（§5、§8）", () => {
  it("方法不允许 → 405 method_not_allowed", async () => {
    const getPush = await request("/v1/sync/push");
    expect(getPush.status).toBe(405);
    expect((await getPush.json<any>()).error.code).toBe("method_not_allowed");

    const session = await registerOk("user-route", "device-route");
    const postPull = await request("/v1/sync/pull?cursor=0", {
      method: "POST",
      headers: { Authorization: `Bearer ${session.token}` },
    });
    expect(postPull.status).toBe(405);

    const getAuth = await request("/v1/auth/anonymous");
    expect(getAuth.status).toBe(405);
  });

  it("未知路由 → 404 not_found；OPTIONS → 204 CORS 预检", async () => {
    const notFound = await request("/v1/nope");
    expect(notFound.status).toBe(404);
    expect((await notFound.json<any>()).error.code).toBe("not_found");

    const preflight = await request("/v1/sync/push", { method: "OPTIONS" });
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("请求体非法 JSON → 400 invalid_json", async () => {
    const res = await request("/v1/auth/anonymous", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{not-json",
    });
    expect(res.status).toBe(400);
    expect((await res.json<any>()).error.code).toBe("invalid_json");
  });
});
