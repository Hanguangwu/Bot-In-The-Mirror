import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  newWorkspace,
  operation,
  pull,
  push,
  taskSnapshot,
  uniqueId,
} from "./helpers";


const EXPECTED_TABLES = [
  "users",
  "workspaces",
  "workspace_members",
  "devices",
  "auth_tokens",
  "entities",
  "change_log",
];

const EXPECTED_INDEXES = [
  "idx_change_log_op",
  "idx_change_log_cursor",
  "idx_entities_type",
];

describe("D1 schema（§4、§11.1-5）", () => {
  it("迁移可应用：全部表与索引存在", async () => {
    const rows = await env.DB.prepare(
      "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'index')",
    ).all<{ name: string; type: string }>();
    const names = rows.results.map((row) => row.name);

    for (const table of EXPECTED_TABLES) {
      expect(names).toContain(table);
    }
    for (const index of EXPECTED_INDEXES) {
      expect(names).toContain(index);
    }
    // 迁移记录表（applyD1Migrations 默认 d1_migrations）。
    expect(names).toContain("d1_migrations");
  });

  it("change_log(workspace_id, op_id) 唯一约束生效", async () => {
    const workspaceId = uniqueId("w");
    const insert = env.DB.prepare(
      `INSERT INTO change_log
         (workspace_id, entity_type, entity_id, version, kind, device_id, op_id,
          payload, updated_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    const args = [
      workspaceId,
      "task",
      "task-1",
      1,
      "create",
      "device-1",
      "op-dup",
      "{}",
      "2026-01-01T00:00:00.000Z",
      "2026-01-01T00:00:00.000Z",
    ];

    await insert.bind(...args).run();
    await expect(insert.bind(...args).run()).rejects.toThrow();

    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM change_log WHERE workspace_id = ? AND op_id = ?",
    )
      .bind(workspaceId, "op-dup")
      .first<{ n: number }>();
    expect(count?.n).toBe(1);
  });

  it("change_log.seq 单调递增（AUTOINCREMENT）", async () => {
    const { session, userId } = await newWorkspace("user-seq");

    await push(session.token, [
      operation("op-1", "task-1", "create", taskSnapshot({ userId, id: "task-1" })),
      operation("op-2", "task-2", "create", taskSnapshot({ userId, id: "task-2" })),
      operation("op-3", "task-3", "create", taskSnapshot({ userId, id: "task-3" })),
    ]);

    const rows = await env.DB.prepare(
      "SELECT seq FROM change_log WHERE workspace_id = ? ORDER BY seq ASC",
    )
      .bind(session.workspaceId)
      .all<{ seq: number }>();

    const seqs = rows.results.map((row) => row.seq);
    expect(seqs).toHaveLength(3);
    for (let i = 1; i < seqs.length; i += 1) {
      expect(seqs[i]!).toBeGreaterThan(seqs[i - 1]!);
    }

    // pull 的游标与 seq 空间一致。
    const pulled = await pull(session.token, 0);
    expect(pulled.body.cursor).toBe(seqs[seqs.length - 1]);
  });

  it("entities 主键为 (workspace_id, entity_type, entity_id)：同 id 跨类型互不覆盖", async () => {
    const { session, userId } = await newWorkspace("user-ent");

    await push(session.token, [
      operation("op-task", "same-id", "create", taskSnapshot({ userId, id: "same-id" })),
      operation(
        "op-conv",
        "same-id",
        "create",
        {
          id: "same-id",
          userId,
          createdAt: "2026-01-01T00:00:00.000Z",
          updatedAt: "2026-01-01T00:00:00.000Z",
          version: 1,
          deviceId: session.deviceId,
          title: "会话",
          isArchived: false,
        },
        "conversation",
      ),
    ]);

    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM entities WHERE workspace_id = ? AND entity_id = ?",
    )
      .bind(session.workspaceId, "same-id")
      .first<{ n: number }>();
    expect(count?.n).toBe(2);
  });
});
