import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { hashToken } from "../src/auth";
import { push, register, registerOk, request, uniqueId } from "./helpers";

describe("POST /v1/auth/anonymous（§5.1）", () => {
  it("注册返回 token/workspaceId 并回显身份；建 owner 成员", async () => {
    const userId = uniqueId("user");
    const deviceId = uniqueId("device");
    const res = await register(userId, deviceId);
    expect(res.status).toBe(200);

    const session = res.body;
    expect(session.token).toMatch(/^[0-9a-f]{64}$/);
    expect(session.userId).toBe(userId);
    expect(session.deviceId).toBe(deviceId);
    expect(typeof session.workspaceId).toBe("string");
    expect(session.workspaceId.length).toBeGreaterThan(0);

    const workspace = await env.DB.prepare(
      "SELECT owner_user_id FROM workspaces WHERE id = ?",
    )
      .bind(session.workspaceId)
      .first<{ owner_user_id: string }>();
    expect(workspace?.owner_user_id).toBe(userId);

    const member = await env.DB.prepare(
      "SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
    )
      .bind(session.workspaceId, userId)
      .first<{ role: string }>();
    expect(member?.role).toBe("owner");

    const device = await env.DB.prepare(
      "SELECT user_id, workspace_id, revoked_at FROM devices WHERE id = ?",
    )
      .bind(deviceId)
      .first<Record<string, any>>();
    expect(device?.user_id).toBe(userId);
    expect(device?.workspace_id).toBe(session.workspaceId);
    expect(device?.revoked_at).toBeNull();
  });

  it("重复注册幂等：复用 workspace 并换发新 token，旧 token 仍有效", async () => {
    const userId = uniqueId("user");
    const deviceId = uniqueId("device");

    const first = await registerOk(userId, deviceId);
    const second = await registerOk(userId, deviceId);

    expect(second.workspaceId).toBe(first.workspaceId);
    expect(second.token).not.toBe(first.token);

    // 旧 token 未撤销 → 仍可鉴权。
    const res = await push(first.token, []);
    expect(res.status).toBe(200);
    expect(res.body.results).toEqual([]);

    const tokens = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM auth_tokens WHERE user_id = ?",
    )
      .bind(userId)
      .first<{ n: number }>();
    expect(tokens?.n).toBe(2);
  });

  it("同 userId 不同 deviceId 共享同一 workspace（单用户多设备）", async () => {
    const userId = uniqueId("user");
    const a = await registerOk(userId, uniqueId("device"));
    const b = await registerOk(userId, uniqueId("device"));
    expect(b.workspaceId).toBe(a.workspaceId);
  });

  it("非法身份返回 400 invalid_identity", async () => {
    const cases: unknown[][] = [
      ["", "device-1"],
      ["user-1", ""],
      ["a".repeat(129), "device-1"],
      ["bad*chars", "device-1"],
      ["用户一", "device-1"],
      [123, "device-1"],
      ["user-1", { nested: true }],
    ];

    for (const [userId, deviceId] of cases) {
      const res = await register(userId, deviceId);
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("invalid_identity");
    }
  });

  it("表内只存 SHA-256 哈希，不存明文", async () => {
    const userId = uniqueId("user");
    const deviceId = uniqueId("device");
    const session = await registerOk(userId, deviceId);
    const tokenHash = await hashToken(session.token);

    const byHash = await env.DB.prepare(
      "SELECT user_id, device_id, workspace_id FROM auth_tokens WHERE token_hash = ?",
    )
      .bind(tokenHash)
      .first<Record<string, any>>();
    expect(byHash?.user_id).toBe(userId);
    expect(byHash?.device_id).toBe(deviceId);
    expect(byHash?.workspace_id).toBe(session.workspaceId);

    // 明文不得出现在任何一列。
    const plaintext = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM auth_tokens WHERE token_hash = ? OR user_id = ? OR device_id = ?",
    )
      .bind(session.token, session.token, session.token)
      .first<{ n: number }>();
    expect(plaintext?.n).toBe(0);
  });
});

describe("鉴权（§11.1-6）", () => {
  it("无 token / 坏 token / 格式非法 → 401", async () => {
    const noToken = await request("/v1/sync/pull?cursor=0");
    expect(noToken.status).toBe(401);
    expect((await noToken.json<any>()).error.code).toBe("unauthorized");

    const badToken = await request("/v1/sync/pull?cursor=0", {
      headers: { Authorization: `Bearer ${"0".repeat(64)}` },
    });
    expect(badToken.status).toBe(401);

    const malformed = await request("/v1/sync/pull?cursor=0", {
      headers: { Authorization: "Token abc" },
    });
    expect(malformed.status).toBe(401);

    const shortToken = await request("/v1/sync/pull?cursor=0", {
      headers: { Authorization: "Bearer deadbeef" },
    });
    expect(shortToken.status).toBe(401);

    const pushNoToken = await request("/v1/sync/push", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operations: [] }),
    });
    expect(pushNoToken.status).toBe(401);
  });
});
