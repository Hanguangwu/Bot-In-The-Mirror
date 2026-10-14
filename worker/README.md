# chatwithalice 同步服务（Cloudflare Worker + D1）

M2b Lane-A 交付物：Cloudflare Worker 作为**唯一远程入口**（基线 §6.2），提供匿名工作区鉴权与增量同步（push/pull）。客户端不直连 D1。

> 规格来源：`docs/M2b-实施说明.md`（§4 schema、§5 API 契约、§7.1 LWW、§8 实现要点、§11.1 测试）。
> 本轮**只交付代码与迁移，不执行真实部署**（用户决策 2026-10-14）。

## 目录结构

```
worker/
  package.json / tsconfig.json / wrangler.toml / vitest.config.ts
  migrations/0001_init.sql        # D1 schema + 索引（§4 逐字实现）
  src/index.ts                    # 路由 + 鉴权中间件 + CORS/错误体
  src/auth.ts                     # token 生成（32B→64hex）/ SHA-256 哈希 / 校验
  src/db.ts                       # D1 访问封装（prepare/bind/first/all/batch）
  src/lww.ts                      # LWW 比较（纯函数，与客户端同语义）
  src/handlers/auth_anonymous.ts  # POST /v1/auth/anonymous
  src/handlers/sync_push.ts       # POST /v1/sync/push
  src/handlers/sync_pull.ts       # GET  /v1/sync/pull
  test/*.test.ts                  # vitest（本地 workerd + D1，不触网）
```

## 环境要求

- Node.js 20+（本仓库验证于 Node 24）
- npm（验证于 npm 11）

## 安装

```bash
cd worker
npm install
```

> **npm 11 注意**：`esbuild` / `workerd` 带 postinstall 脚本。若 npm 提示
> `allow-scripts`，需执行 `npm install-scripts approve workerd esbuild` 才能下载
> 二进制（`package.json` 的 `allowScripts` 字段已记录批准项；升级依赖版本后需重新批准）。

## 本地运行

```bash
cd worker
npm run dev            # wrangler dev：本地 workerd + 本地 D1（首次会读取 wrangler.toml）
```

本地 D1 迁移：

```bash
npx wrangler d1 migrations apply chatwithalice-sync --local
```

## 测试

```bash
cd worker
npm test               # vitest run（@cloudflare/vitest-pool-workers：本地 workerd + D1，不触网）
npm run typecheck      # tsc --noEmit
```

- 迁移在测试启动时由 `test/apply-migrations.ts` 通过 `applyD1Migrations` 应用到本地 D1。
- 测试覆盖：`auth.test.ts`、`push.test.ts`、`pull.test.ts`、`lww.test.ts`、`schema.test.ts`（对齐 §11.1）。
- **本地 D1 在同一测试进程内不隔离**：每条测试用唯一 `userId` 自建工作区，避免用例间数据串扰。

## API 契约（§5）

基址 `{syncBaseUrl}/v1`；除 `POST /v1/auth/anonymous` 外一律 `Authorization: Bearer <token>`；
错误体统一 `{ "error": { "code": "<枚举>", "message": "<简述>" } }`，状态码 `400/401/404/405/429/500`。

### `POST /v1/auth/anonymous`
请求 `{ "userId": "...", "deviceId": "..." }`（非空、≤128、`[A-Za-z0-9_-]`）。
响应 `200`：`{ "token": "<64hex>", "userId", "workspaceId", "deviceId" }`；非法身份 `400 invalid_identity`。
行为：`users` upsert；无 workspace 则新建 `workspaces` + `workspace_members(role=owner)`；
`devices` upsert；生成随机 token（32B→64hex）并以 `SHA-256` 存 `auth_tokens.token_hash`（**不存明文**）。
重复调用（同 deviceId）复用 workspace 并换发新 token（旧 token 若未撤销仍有效）。

### `POST /v1/sync/push`
请求 `{ "operations": [ { "opId", "entityType", "entityId", "kind": "create|update|delete", "payload": {…} } ] }`
（单批 ≤ 100，超出 `400 batch_too_large`）。逐条处理，互不影响：

1. 结构校验（`entityType` 白名单、`entityId === payload.id`、`payload.version`(int)/`updatedAt`(ISO)）→ 否则 `rejected`/`invalid_payload`；
2. 所有权校验（`payload.userId === token.userId`）→ 否则 `rejected`/`ownership_mismatch`；
3. 幂等：`change_log(workspace_id, op_id)` 已存在 → `applied`（不重复写）；
4. LWW（§7.1）：接受则 upsert `entities` + 追加 `change_log`（`db.batch()` 单次往返）；拒绝则 `conflict`/`stale_version` + `serverVersion`/`serverUpdatedAt`，**不写** `change_log`。

响应 `200`：`{ "results": [ { "opId", "status": "applied|conflict|rejected", "reason", "serverVersion", "serverUpdatedAt" } ] }`。
**push 不返回游标**（A3）；信封中的 `version`/`updatedAt`/`deviceId` 一律忽略。

**字段来源（B1，强约束）**：`entities.version/updated_at/deleted_at` 与 `change_log.version/updated_at`
一律取自 **payload 快照**；`entities.device_id` / `change_log.device_id` 一律取自 **token**。

### `GET /v1/sync/pull?cursor=<int>&limit=<int>`
`cursor` 必填（首次 0）；`limit` 可选，默认 200，上限 500。
扫描 `seq > cursor ORDER BY seq ASC LIMIT limit`（**全量扫描**）；组装时剔除
`device_id == 请求 token 的 deviceId` 的行（回声抑制）；`cursor = max(本次扫描行的 seq)`
（无扫描行则回显请求值）；`hasMore = (扫描行数 == limit)`。**不使用 `MAX(seq)`**（会漏读并发写入）。
错误：`401`、`400 invalid_cursor`。

响应 `200`：
```json
{ "changes": [ { "seq": 121, "entityType": "task", "entityId": "…", "kind": "update",
                 "version": 4, "deviceId": "…", "updatedAt": "2026-05-01T09:00:00.000Z",
                 "payload": { } } ],
  "cursor": 140, "hasMore": false }
```

### payload 白名单（§5.4）
`conversation`、`message`、`task`、`ai_plan`、`calendar_entry`、`project`。
服务端**不解释领域字段**，仅从快照提取 `version`/`updatedAt`/`deletedAt`；身份/设备一律来自 token。

## 安全

- `auth_tokens` 只存 `SHA-256(token)`；明文只在注册响应中返回一次。
- 身份只来自 token；请求体/查询串中的 `userId`/`workspaceId` 不被信任。
- 不记录 token 明文与完整 payload（仅错误摘要）。
- 请求体上限 1 MiB；按 token（哈希分桶）的基础限流保护位（§14.3，非精细配额）。
- 匿名注册信任客户端 `userId`（A1 显式接受，登录/迁移后置）。

## 部署步骤（**本轮不执行**，仅文档化）

1. `npx wrangler login`
2. `npx wrangler d1 create chatwithalice-sync` → 将返回的 `database_id` 写入 `wrangler.toml`
   （当前为占位 `00000000-0000-0000-0000-000000000000`），并在 `wrangler.toml` 填入 `account_id`。
3. `npx wrangler d1 migrations apply chatwithalice-sync --remote`
4. `npm run deploy`（= `wrangler deploy`）
5. 在客户端「设置 → 同步 → 服务地址」填入 Worker 的 `https://<name>.<subdomain>.workers.dev`。

> 生产前待办（§15 记档）：`change_log` 保留/压缩策略、多写者安全水位、精细限流、设备撤销。

## 已知事项

- `@cloudflare/vitest-pool-workers` 已改名为 `@cloudflare/vitest-plugin`（npm 会打印 WARNING）。
  本仓库按契约仍使用 `@cloudflare/vitest-pool-workers`（0.23.0）；迁移可用
  `npx @cloudflare/codemods vitest:pool-workers-to-vitest-plugin`。
- `wrangler.toml` 的 `database_id` / `account_id` 均为占位，真实部署前必须替换。
