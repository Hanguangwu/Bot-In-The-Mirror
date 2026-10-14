# M2b 实施说明：云端同步（Cloudflare Worker + D1）（Rev 1）

> 设计基线：`docs/产品与技术设计方案.md`（§5 客户端架构与 `SyncEngine`、§6.2 Worker + D1 与同步协议、§10 安全与多用户扩展、§11 M2 里程碑、§12 验收标准）。
> 前置：M2a 已完成（`docs/M2a-实施说明.md`，commit `3841601`）——同步队列落库、全写路径事务化入队、`IdentityStore`、`entity_serializer.toSyncJson`、日历/项目仓储、五区导航。
> 用户决策（2026-10-14）：① 本轮**先写代码 + 契约，真实部署另行**；② 冲突首期 **LWW 自动解决**；③ 同步触发 = **设置页手动 + 应用启动自动**；首期**不加密**。
> 评审：Rev 0 经 oracle 设计评审（**B1–B5 阻断** + A1–A12 建议，处置见 §16）。

## 1. M2b 目标与验收

- **远端入口**：Cloudflare Worker 作为唯一远程入口（鉴权、校验、版本控制、D1 读写）；**客户端不直连 D1**（基线 §6.2）。
- **匿名工作区身份**：首启用 M2a 已持久化的本地 `userId`/`deviceId` 向 Worker 注册，换取**匿名工作区 token**（明文存设备安全存储，D1 只存哈希）；此后以 token 鉴权，**身份只来自 token**。
- **增量同步**：客户端「推送本地队列变更 + 拉取游标之后变更」双向流程（基线 §6.2）；游标持久化；重复同步不产生重复实体（幂等）。
- **冲突解决**：首期 **LWW**（`version` 优先，其次 `updatedAt`）；冲突可解释（`conflicted` 状态 + 摘要）。
- **离线优先**：无网络时写操作照常入队；恢复后下次同步推送；同步失败不阻塞 UI。
- **同步状态页**：设置页入口，展示状态/上次同步时间/待同步条数/失败与冲突摘要，支持手动触发与 Worker 地址配置。
- **可测试**：Worker 用 `vitest` + `@cloudflare/vitest-pool-workers`（本地 workerd + D1）；Dart 侧用 `MockClient`/假 `SyncApi` 测试，**不触网**。
- `flutter analyze` 0 issues；`flutter test` 全绿（较 M2a 增加）；`worker npm test` 绿。

## 2. 边界（本期不做）

- **不做真实部署**：不执行 `wrangler deploy`、不创建真实 D1；只交付可在本地 `wrangler dev`/`vitest` 运行的代码与迁移。
- **不做端到端加密**（用户决策）。
- **不做 CRDT / 字段级合并**：LWW 为**整实体级**；基线 §6.2「不同字段优先合并」后置。
- **不做账号登录/匿名数据迁移**。
- **不做实时推送**（WebSocket/SSE/Durable Objects）：仅请求-响应同步。
- **不做多工作区/成员权限**：远端 `workspace_members.role` 恒为 `owner`。
- **不做设备撤销 UI**（仅保留端点/字段；§14.4）。
- **不做同步队列历史归档**：`synced` 操作推送成功后**直接删除**（§7.5）。
- **不做图片/音频/健康数据上行**（`entity_type` 白名单见 §5.4）。
- **不做精细限流配额**（仅保留基础保护位；§14.3）。
- **不改 M2a 已冻结的 `toSyncJson`**（仅**新增** `fromSyncJson`）。

## 3. 目录与新增/改动文件

```
# Worker（Cloudflare，TypeScript）
worker/
  package.json / tsconfig.json / wrangler.toml
  migrations/0001_init.sql        # 远端表结构（§4）
  src/index.ts                    # 路由 + 鉴权中间件 + CORS/错误
  src/auth.ts                     # token 生成/哈希/校验
  src/db.ts                       # D1 访问封装
  src/lww.ts                      # LWW 比较（纯函数）
  src/handlers/auth_anonymous.ts  # POST /v1/auth/anonymous（§5.1）
  src/handlers/sync_push.ts       # POST /v1/sync/push（§5.2）
  src/handlers/sync_pull.ts       # GET  /v1/sync/pull（§5.3）
  test/*.test.ts                  # vitest（workerd + D1）
  README.md                       # 本地运行/测试；部署步骤另附（不执行）

# 域层（新增/改动）
lib/domain/sync/sync_engine.dart        # 由 lib/domain/ai/sync_engine.dart 迁入并扩展（§6.6）
lib/domain/sync/sync_status.dart        # SyncStatus 值对象（state + lastReport + lastError + lastSyncAt）
lib/domain/sync/sync_api.dart           # RemoteSyncApi 接口
lib/domain/sync/sync_change.dart        # SyncChange / PushItemResult / PushResponse / PullResponse / AnonymousSession
lib/domain/sync/sync_entity_store.dart  # applyRemote + localVersion（§6.3）
lib/domain/sync/sync_cursor_store.dart  # 游标 + 上次同步时间持久化
lib/domain/sync/sync_credential_store.dart # token / workspaceId 持久化
lib/domain/sync/lww.dart                # LWW 判定（与 worker/src/lww.ts 同语义）
lib/domain/sync/entity_serializer.dart  # + fromSyncJson（六实体）
lib/domain/entities/sync.dart           # SyncReport.cursor：String? → int?（B3）
lib/domain/repositories/sync_operation_repository.dart # + deleteSynced/deleteConflicted/requeueFailed（§6.5）
lib/domain/repositories/settings_store.dart            # + syncBaseUrl（§9.3）
lib/core/errors/app_exception.dart      # + SyncApiException / SyncNetworkException / SyncDecodeException
# 数据层（新增）
lib/data/remote/worker_sync_api.dart    # RemoteSyncApi 的 HTTP 实现（注入 http.Client）
lib/data/remote/sync_json.dart          # DTO ↔ JSON
lib/data/sync/sync_engine_impl.dart     # SyncEngine 编排实现（推送/拉取/游标/退避/清理）
lib/data/local/sync_entity_store_impl.dart        # Drift：applyRemote（不入队）
lib/data/local/sync_cursor_store_impl.dart        # shared_preferences
lib/data/local/sync_credential_store_impl.dart    # flutter_secure_storage(token) + shared_preferences(workspaceId)
lib/data/memory/memory_sync_entity_store.dart
lib/data/memory/memory_sync_cursor_store.dart
lib/data/memory/memory_sync_credential_store.dart
lib/data/memory/{memory_task_repository,...}.dart # + 数据层内部「原始写入」接缝（§6.3，非域接口）
# 改动
lib/data/local/sync_operation_repository_impl.dart      # + deleteSynced/deleteConflicted/requeueFailed
lib/data/memory/memory_sync_operation_repository.dart   # 同上
lib/data/local/{app_database.dart,app_database.g.dart}  # 若无 schema 变更则不动
lib/data/local/persistent_settings_store.dart           # + syncBaseUrl
lib/data/memory/memory_settings_store.dart              # + syncBaseUrl
lib/core/config/app_config.dart                         # + defaultSyncBaseUrl / 批大小 / 拉取上限 / 退避
lib/di.dart                                             # 注册 SyncEngine/SyncApi/游标/凭证/实体写入；启动自动同步
lib/main.dart                                           # 启动后 fire-and-forget 自动同步（§9.4）
lib/features/settings/settings_screen.dart              # 同步入口
lib/features/sync/sync_status_screen.dart               # 新：同步状态页（§10）
# 测试（新增/改动）
test/domain/entities_test.dart                          # SyncReport.cursor int 化
test/data/sync_entity_store_contract_test.dart
test/data/sync_engine_test.dart
test/data/sync_engine_convergence_test.dart             # 双客户端 + 假 Worker 收敛（A7）
test/data/worker_sync_api_test.dart
test/domain/entity_deserializer_test.dart
test/data/sync_operation_repository_contract_test.dart  # + 新方法与清理断言
test/features/sync_status_screen_test.dart
```

### 3.1 `SyncEngine` 迁址
现状 `lib/domain/ai/sync_engine.dart`（M0 误置）。M2b 迁到 `lib/domain/sync/sync_engine.dart` 并按 §6.6 扩展。全仓 grep 确认无生产引用，属机械改动，纳入 Lane-0。

## 4. 远端 D1 schema（`worker/migrations/0001_init.sql`）

统一实体表 + 变更日志。时间列一律 **UTC ISO8601 文本**。

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,            -- 复用客户端匿名 userId
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,            -- 服务端生成
  owner_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE workspace_members (
  workspace_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'owner',   -- 预留
  created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);
CREATE TABLE devices (
  id TEXT PRIMARY KEY,            -- 客户端 deviceId
  user_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  last_sync_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE auth_tokens (
  token_hash TEXT PRIMARY KEY,    -- SHA-256(token) 十六进制；不存明文
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
-- 一行 = 某工作区内某实体当前最新快照
CREATE TABLE entities (
  workspace_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,      -- conversation|message|task|ai_plan|calendar_entry|project
  entity_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,        -- 产生此版本的设备（用于诊断）
  version INTEGER NOT NULL,       -- 取自 payload（§5.4）
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,       -- 取自 payload
  deleted_at TEXT,                -- 取自 payload；NULL 表示未删
  payload TEXT NOT NULL,          -- 实体快照 JSON
  PRIMARY KEY (workspace_id, entity_type, entity_id)
);
-- 变更日志：增量拉取游标
CREATE TABLE change_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- 单调游标
  workspace_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  version INTEGER NOT NULL,       -- 取自 payload
  kind TEXT NOT NULL,             -- create|update|delete
  device_id TEXT NOT NULL,        -- 取自 token（§5.4）
  op_id TEXT NOT NULL,            -- 幂等键（客户端 SyncOperation.id）
  payload TEXT NOT NULL,          -- 该次变更后的实体快照
  updated_at TEXT NOT NULL,       -- 取自 payload
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_change_log_op ON change_log (workspace_id, op_id);
CREATE INDEX idx_change_log_cursor ON change_log (workspace_id, seq);
CREATE INDEX idx_entities_type ON entities (workspace_id, entity_type);
```

**来源规则（B1，强约束）**：`entities.version/updated_at/deleted_at` 与 `change_log.version/updated_at` **一律取自 payload 快照**；`entities.device_id`/`change_log.device_id` **一律取自 token**（不得取信封，防伪造）。客户端 `SyncOperation` 信封自身的 `version/updatedAt`（M2a `buildSyncOperation` 恒 `version:1`、`updatedAt:now`）**服务端不使用**。

验证（`test/schema.test.ts`）：迁移可应用、表/索引存在、`seq` 单调。

## 5. Worker API 契约

- 基址：`{syncBaseUrl}/v1`（客户端配置，默认空 = 未启用）。
- 传输：HTTPS + JSON（`Content-Type: application/json; charset=utf-8`）。
- 鉴权：除 `/v1/auth/anonymous` 外一律 `Authorization: Bearer <token>`。
- 时间：一律 UTC ISO8601（带 `Z`）。
- 错误体统一：`{ "error": { "code": "<枚举>", "message": "<简述>" } }`；HTTP：`400` 参数错、`401` 未授权、`404` 路由不存在、`405` 方法不允许、`429` 限流、`500` 服务错。

### 5.1 `POST /v1/auth/anonymous`（注册/换发令牌）
请求：`{ "userId": "<本地匿名 userId>", "deviceId": "<本地 deviceId>" }`
- 校验：非空、长度 ≤ 128、字符白名单 `[A-Za-z0-9_-]`。
- 行为（幂等）：`users` upsert；无 workspace 则新建 `workspaces` + `workspace_members(role=owner)`；`devices` upsert；生成随机 token（32 字节 → 64 位 hex），存 `auth_tokens.token_hash = SHA-256(token)`；返回明文。
- 重复调用（同 deviceId）：换发新 token（旧 token 若未撤销仍有效）。

响应 `200`：`{ "token": "<64hex>", "userId": "<回显>", "workspaceId": "<服务端生成>", "deviceId": "<回显>" }`；错误 `400 invalid_identity`。

### 5.2 `POST /v1/sync/push`
请求（鉴权）：
```json
{ "operations": [
    { "opId": "<SyncOperation.id>", "entityType": "task", "entityId": "<id>",
      "kind": "create|update|delete", "payload": { /* 实体快照，§5.4 */ } }
] }
```
- 上限：单批 ≤ 100 条；超出 `400 batch_too_large`。
- 逐条处理（顺序无关；单条失败不影响其它）：
  1. **结构校验**：`entityType` 在白名单、`entityId` 与 `payload.id` 一致、payload 含 `version`(int)/`updatedAt`(ISO)；否则 `status="rejected"`, `reason="invalid_payload"`。
  2. **所有权校验（基线 §10）**：`payload.userId == token.userId` 且 `entityType` 白名单；否则 `rejected`, `reason="ownership_mismatch"`。
  3. **幂等**：若 `change_log(workspace_id, op_id)` 已存在 → `status="applied"`（不重复写）。
  4. **LWW**（§7.1）：读 `entities` 当前行；接受当且仅当 `stored==null` 或 `incoming.version > stored.version` 或（`==` 且 `incoming.updatedAt > stored.updatedAt`）。
     - 接受：upsert `entities`（`payload`、`deleted_at`、`version`、`updated_at` 取自 payload；`device_id` 取自 token），追加 `change_log`（`kind` 取请求、`device_id` 取自 token），返回 `applied`。
     - 拒绝：返回 `conflict`, `reason="stale_version"`，附 `serverVersion`/`serverUpdatedAt`；**不写 `change_log`**（服务端未变）。
- `entities` 与 `change_log` 的写入用 `db.batch()` 单次往返。

响应 `200`：
```json
{ "results": [ { "opId": "...", "status": "applied|conflict|rejected",
                 "reason": null, "serverVersion": 4, "serverUpdatedAt": "..." } ] }
```
（B/A3：push **不返回游标**——客户端拉取独立进行，请求亦无 cursor 字段。）

### 5.3 `GET /v1/sync/pull?cursor=<int>&limit=<int>`
- `cursor` 必填（首次 `0`）；`limit` 可选，默认 200，上限 500。
- **扫描**（B2）：`SELECT ... WHERE workspace_id=? AND seq > ? ORDER BY seq ASC LIMIT ?`（**全量扫描，设备过滤不参与游标**）。
- **组装**：剔除 `device_id == 请求 token 的 deviceId` 的行（回声抑制，§7.3）。
- **游标推进（B2）**：`cursor = max(本次扫描行的 seq)`；无扫描行则 `cursor` 回显请求值；`hasMore = (扫描行数 == limit)`。**不得用 `MAX(seq)`**（会跳过扫描与聚合之间并发写入的高 seq，导致永久漏读）。

响应 `200`：
```json
{ "changes": [ { "seq": 121, "entityType": "task", "entityId": "<id>", "kind": "update",
                 "version": 4, "deviceId": "<产生变更的设备>",
                 "updatedAt": "2026-05-01T09:00:00.000Z", "payload": { /* 快照 */ } } ],
  "cursor": 140, "hasMore": false }
```
- 错误：`401`、`400 invalid_cursor`。
- **记档**：`seq` 为 `AUTOINCREMENT`，D1 并发提交可能乱序可见；本轮依赖「扫描水位 = 本次实际扫描最大 seq」+ 单写者序列化假设；生产前若引入多写者需补安全水位（§15）。

### 5.4 payload 与白名单
- `payload` = 客户端 `toSyncJson()` 快照对象本身（M2a 冻结）：Syncable 七字段（`deletedAt` 空则省键）+ 专有字段；时间 UTC ISO8601；枚举 `.name`。
- 白名单：`conversation`、`message`、`task`、`ai_plan`、`calendar_entry`、`project`。
- **服务端不解释领域字段**，仅从快照提取 `version`/`updatedAt`/`deletedAt`；身份/设备一律来自 token（§4、B1）。

## 6. 客户端同步协议与接口

### 6.1 流程（`SyncEngineImpl.sync`）
状态：`sync()` 开始时置 `SyncState.syncing` 并广播 `SyncStatus`；结束置 `idle`（有失败 → `failed`；网络异常 → `offline`）。
1. **前置**：`syncBaseUrl` 为空 → 直接返回空 `SyncReport` 且状态 `idle`（不报错、不触网）；无 token → `register`（§5.1）并持久化 token/workspaceId。
2. **推送**（A2：循环分批）：循环 `pending = getPending()`，每次取前 `pushBatchSize`（默认 100）条 → `api.push`；直至无 pending 或达到 `maxPushPasses`（默认 5）。
   - `applied` → `mark(synced)`；`conflict` → `mark(conflicted, lastError='版本落后，服务端已更新')`；`rejected` → `mark(failed, lastError=reason)`。
   - 整批网络/`5xx` 失败 → 操作**保持 `pending`**、`retryCount++`、`lastError`，`failed += n`，退出推送循环。
   - 推送结束后 `deleteSynced()`（§7.5）。
3. **拉取**（B2 游标）：`cursor = cursorStore.read()`；循环 `pull(cursor, limit)`；对每条 change：跳过 `deviceId==本机`（服务端已过滤，双保险）→ `SyncEntityStore.applyRemote`（§6.3，LWW，无入队）→ `pulled++`；`cursor = resp.cursor`；`hasMore` 为真且未超 `maxPullPages`（默认 10）继续。
   - 持久化 `cursor` 与 `lastSyncAt=now`（§9.2）。
4. **收敛清理**（A4）：拉取完成后 `deleteConflicted()`（本地已被 LWW 覆盖，冲突行无需保留）。
5. **收尾**：构造 `SyncReport(pushed, pulled, failed, cursor: <int>, at: now)`（B3：`cursor` 为 `int?`）；广播 `SyncStatus`。
6. **重试/退避**：网络类失败保持 `pending`，随下次同步自动重试；引擎记录 `lastAttemptAt`，**自动同步**在距上次 `< backoff`（默认 30s，指数升至上限 10min）时跳过；**手动同步忽略退避**。
7. **`syncing` 状态（`SyncOperationStatus.syncing`）本轮不使用**——若使用则崩溃后操作会卡在 `syncing` 且不被 `getPending` 取回，需配套恢复逻辑；记档为保留态（§15）。

### 6.2 `RemoteSyncApi`（`lib/domain/sync/sync_api.dart`）
```dart
abstract interface class RemoteSyncApi {
  Future<AnonymousSession> register({required String userId, required String deviceId});
  Future<PushResponse> push({required String token, required List<SyncOperation> operations});
  Future<PullResponse> pull({required String token, required int cursor, int limit});
}
```
- HTTP 实现 `WorkerSyncApi`（A11）：**构造注入 `http.Client`（默认 `http.Client()`）与基址 provider**（`() => settingsStore.syncBaseUrl`），便于 `MockClient` 测试；`Authorization: Bearer <token>`；JSON UTF-8；非 2xx → `SyncApiException(code, status)`；网络异常 → `SyncNetworkException`。
- DTO（`sync_change.dart`/`sync_json.dart`）：`AnonymousSession(token,userId,workspaceId,deviceId)`、`PushResponse(List<PushItemResult>)`、`PushItemResult(opId,status,reason?,serverVersion?,serverUpdatedAt?)`、`PullResponse(List<SyncChange>, int cursor, bool hasMore)`、`SyncChange(seq,entityType,entityId,kind,version,deviceId,updatedAt,payload)`。

### 6.3 `SyncEntityStore`（应用远端变更；**不经仓储写路径，不入队**）
```dart
abstract interface class SyncEntityStore {
  /// 以 LWW 应用一条远端变更；返回是否实际写入。
  Future<bool> applyRemote(SyncChange change);
  /// 读本地当前版本（判 LWW）；不存在返回 null。
  Future<({int version, DateTime updatedAt})?> localVersion(String entityType, String entityId);
}
```
- **实现（B5）**：
  - Drift `SyncEntityStoreImpl(db)`：按 `entityType` 分派到六张表，`insertOnConflictUpdate` / 墓碑列写入，**不走**仓储 `save`/`delete`。
  - Memory `MemorySyncEntityStore`：在**数据层内部**为六个内存仓储补「原始写入（不入队）」窄接缝（如 `applyRemoteSnapshot` / `localVersionOf`，**属 data 层具体类方法，不进 `lib/domain/repositories/*` 域接口**），由本 store 聚合委托；写入后照常广播其变更流（UI 需刷新），但**不触发入队**。
  - 该接缝的**域侧接口（`SyncEntityStore`）在 Lane-0 冻结**，内存侧具体方法是 Lane-B 的内部实现细节。
- **LWW**：与 §7.1 同规则（`version` 优先，其次 `updatedAt`）；`payload` 含非空 `deletedAt` 即写墓碑（B5/A10 措辞明确）。
- **Conversation 派生列（B5）**：`conversation` 的 applyRemote 必须**列级写入**，保留本地 `lastMessagePreview`/`lastMessageAt`（快照已排除该两列，M2a §6/§7.4）；本地无该行则插入（派生列留空）。**记档**：远端消息经 applyRemote 入库**不重算**会话预览（绕过 `addMessage`），第二台设备预览可能长期为空——本轮接受，M3 再评估。
- 未知 `entityType` → 忽略并计数（不崩）。
- 测试：双实现契约（LWW/墓碑/无入队/未知类型）+ 收敛用例（§11）。

### 6.4 `fromSyncJson`（`entity_serializer.dart` 新增）
- 六实体各加 `Xxx.fromSyncJson(Map<String,Object?>)`，**严格往返** `toSyncJson`：时间 UTC → `DateTime`；枚举 `byName`；`List<String>` 还原；缺键 → 可空字段 null；`deletedAt` 缺键 → null。
- **错误类型（A8）**：快照结构/类型/枚举非法统一抛 `SyncDecodeException`（`core/errors`）；`AIPlan.changes` 内部沿用既有 `PlanValidationException` 并由 `SyncDecodeException` 包装（不泄露实现细节）。
- 测试：六实体往返 + 固定样例 + 未知枚举抛 `SyncDecodeException`。

### 6.5 `SyncOperationRepository` 扩展（M2b）
```dart
Future<void> deleteSynced();       // 推送成功后删除 status==synced
Future<void> deleteConflicted();   // 拉取收敛后删除 status==conflicted
Future<void> requeueFailed();      // 手动重试：status==failed → pending，清 lastError
```
- 双实现同步补齐；契约测试增断言。

### 6.6 `SyncEngine` 与 `SyncStatus`（B4）
```dart
class SyncStatus {
  const SyncStatus({required this.state, this.lastReport, this.lastError, this.lastSyncAt});
  final SyncState state;
  final SyncReport? lastReport;
  final String? lastError;
  final DateTime? lastSyncAt;
}

abstract interface class SyncEngine {
  Future<SyncReport> sync({bool manual = false});
  Stream<SyncStatus> watchStatus();
  SyncStatus get status;
}
```
- 取代基线 §5 的 `watchState()` 草图（携带报告/错误/上次时间，供状态页；**记档偏离**）。
- 待同步条数仍由 `SyncOperationRepository.watchPending` 提供（不重复）。

## 7. 冲突与一致性规则

### 7.1 LWW
`accept(incoming, stored)` 当且仅当 `stored==null` 或 `incoming.version > stored.version` 或（`==` 且 `incoming.updatedAt > stored.updatedAt`）。纯函数置于 `worker/src/lww.ts` 与 `lib/domain/sync/lww.dart`（同语义、各自单测）。**删除与更新同规则**（不额外「删除必胜」）；字段级合并后置。

### 7.2 幂等
服务端 `(workspace_id, op_id)` 唯一索引保证同一操作只生效一次，重放返回 `applied`；客户端推送成功后 `deleteSynced()`。网络抖动导致「服务端已应用但响应丢失」由幂等键兜底，不产生重复实体。

### 7.3 回声抑制
服务端 pull 按 token 的 `device_id` 过滤发起设备变更（§5.3）；客户端再按 `deviceId == 本机` 二次过滤。

### 7.4 离线
断网时引擎捕获 `SyncNetworkException`：操作保持 `pending`、状态 `offline`、`SyncReport.failed` 计数；UI 不报致命错误。

### 7.5 队列生命周期（A4/A5）
- `applied` → `mark(synced)` → 推送后 `deleteSynced()`。
- `conflict` → `mark(conflicted)` → 拉取（LWW 覆盖本地）后 `deleteConflicted()`。
- `rejected`/整批网络失败累积的 `failed` → 保留供状态页展示与排查；**手动**「重试失败项」（状态页）调 `requeueFailed()` 归零重试。
- `syncing` 保留不用（§6.1）。

## 8. Worker 实现要点

- 路由：`src/index.ts` 按 method+path 分派；`OPTIONS` → CORS 预检。
- 鉴权中间件：Bearer token → `SHA-256` → 查 `auth_tokens`（`revoked_at IS NULL`）→ 注入 `{userId, deviceId, workspaceId}`；失败 `401`。**身份只来自 token**。
- D1：仅 `prepare().bind().all()/run()/first()`；实体+日志写入用 `db.batch()`。
- 校验：请求体大小上限（1 MiB）、字段类型/长度、`limit` 上限、`cursor` 非负整数。
- 限流（基础位）：按 token 简单计数（可选；§14.3）。
- 安全：不记录 token 明文与完整 payload（仅请求 ID + 摘要）；`auth_tokens` 只存哈希。

## 9. 身份、凭证与配置

### 9.1 `SyncCredentialStore`
```dart
abstract interface class SyncCredentialStore {
  Future<String?> readToken(); Future<void> saveToken(String token);
  Future<String?> readWorkspaceId(); Future<void> saveWorkspaceId(String workspaceId);
  Future<void> clear();
}
```
- 生产：token → `SecretStore`（键 `sync_token`）；`workspaceId` → shared_preferences（键 `sync_workspace_id`）。测试：内存实现。

### 9.2 `SyncCursorStore`（A6）
```dart
abstract interface class SyncCursorStore {
  Future<int> read(); Future<void> write(int cursor);
  Future<DateTime?> readLastSyncAt(); Future<void> writeLastSyncAt(DateTime at);
}
```
- 生产：shared_preferences（`sync_cursor` / `sync_last_at`）；测试：内存。`lastSyncAt` 持久化以支撑冷启动后状态页「上次同步时间」。

### 9.3 设置（`SettingsStore` 扩展）
- 新增 `String get syncBaseUrl;`、`Future<void> saveSyncBaseUrl(String url);`（`PersistentSettingsStore` 键 `sync_base_url`；`MemorySettingsStore` 同步）。
- 常量（`app_config.dart`）：`defaultSyncBaseUrl=''`、`syncPushBatchSize=100`、`syncPullLimit=200`、`maxPushPasses=5`、`maxPullPages=10`、`syncBackoffBase=Duration(seconds:30)`、`syncBackoffMax=Duration(minutes:10)`。

### 9.4 触发
- **启动自动**：`main.dart` 在 `configureDependencies()` 后 fire-and-forget `getIt<SyncEngine>().sync()`（未配置基址则内部空转，不触网）。
- **手动**：状态页「立即同步」→ `sync(manual: true)`（忽略退避）。
- 不做写后即同步/定时轮询（用户决策）。

## 10. UI 规格（中文文案）

### 10.1 同步状态页（`lib/features/sync/sync_status_screen.dart`）
- `Scaffold` + `AppBar('同步')`；设置页新增入口 ListTile「同步」（图标 `sync`）。
- 状态区：`StreamBuilder<SyncStatus>` → 闲置/同步中/离线/失败；上次同步时间（`lastSyncAt`，`yyyy-MM-dd HH:mm`）；待同步条数（`watchPending` 长度）。
- 操作：「立即同步」（同步中禁用 + 进度指示）。
- **冲突/失败摘要（A10）**：列出 `watchPending`（含 pending/…) 之外的 `failed`/`conflicted` 计数与最近 `lastError`；提供「重试失败项」（`requeueFailed()`）。
- 配置区：「服务地址」`TextField`（默认 `syncBaseUrl`，保存 → `saveSyncBaseUrl`，去尾斜杠）；未配置提示「填写同步服务地址后可用」。
- 身份区：`userId`/`workspaceId` 脱敏显示（如 `abcd…wxyz`）；token 状态「已连接/未连接」（不显示明文）。
- 边界：未配置/无 token/网络失败均有明确文案，不崩溃。

### 10.2 设置页
- 新增「同步」入口（图标 `sync`）。

## 11. 测试方案（不触网、不依赖真实平台存储/LLM）

### 11.1 Worker（`worker/test/*.test.ts`，vitest-pool-workers + 本地 D1）
1. `auth.test.ts`：注册返回 token/workspaceId；重复注册幂等；非法身份 `400`；表内只存哈希。
2. `push.test.ts`：首写 → `entities`+`change_log`；同 `op_id` 重放幂等；`stale_version` → `conflict` 且不写 `change_log`；白名单外/`payload.userId` 不符 → `rejected`；`entityId != payload.id` → `rejected`；批量 >100 → `400`；**version/updated_at 取自 payload**（信封不动摇 LWW）。
3. `pull.test.ts`：`seq > cursor` 过滤、升序、`limit`/`hasMore` 语义、**发起设备变更被过滤且不影响游标推进（B2 回归）**、`cursor=0` 首次全量、**并发写入不漏读**（模拟扫描间插入更高 seq）。
4. `lww.test.ts`：纯函数边界（version 递增/相等比 updatedAt/首写/墓碑）。
5. `schema.test.ts`：迁移 + 索引 + `seq` 单调。
6. 鉴权：无/坏 token → `401`。

### 11.2 Dart（`flutter test`，不触网）
7. `worker_sync_api_test`：`MockClient` 校验 URL/方法/头/体与响应解析；`401`/`400`/网络异常 → `SyncApiException`/`SyncNetworkException`。
8. `sync_engine_test`：假 `RemoteSyncApi` + 内存仓储——推送 applied→synced→删除；conflict→conflicted→拉取后删除；rejected/网络失败→failed/pending；多批推送循环；拉取游标推进/持久化/`hasMore` 循环上限；回声跳过；未配置空转；退避（自动跳过、手动忽略）；`requeueFailed`。
9. `sync_entity_store_contract_test`：双实现 `applyRemote` LWW（新胜/旧拒/相等比 updatedAt/首写）、墓碑、**不产生入队**（`getPending` 不变）、**conversation 派生列保留**、未知类型忽略。
10. `sync_engine_convergence_test`（A7）：假 Worker（内存 `change_log` + 同 LWW 纯函数）+ 两个内存仓储实例模拟双设备——交替推送/拉取后**最终一致**、重复同步**不产生重复实体**（对齐基线 §12）。
11. `entity_deserializer_test`：六实体往返 + 固定样例 + 未知枚举抛 `SyncDecodeException`。
12. `sync_operation_repository_contract_test`：+`deleteSynced`/`deleteConflicted`/`requeueFailed`。
13. `sync_status_screen_test`：未配置提示、手动同步触发（假引擎）、状态文案、失败/冲突摘要、脱敏显示。
14. 既有回归：`resetDependenciesForTest` 增注册 `SyncEngine`/`RemoteSyncApi`（假）/游标/凭证，**不得触网**。

### 11.3 装配测试缝
- `resetDependenciesForTest` 增可选参数：`syncEngine`、`remoteSyncApi`（默认假实现，`sync()` 返回空报告、不触网）、`syncCredentialStore`/`syncCursorStore`（默认内存）。生产 `configureDependencies` 注册真实实现；**启动自动同步不得在测试中触网**（测试不调生产装配，沿用 M2a 约定）。

## 12. 验收清单

- [ ] Worker：三端点 + 鉴权 + 错误码 + 幂等 + LWW（payload 权威 + token 身份/所有权校验）+ 设备过滤 + 游标推进，`vitest` 全绿；D1 迁移/索引可用。
- [ ] 客户端：`WorkerSyncApi`（注入 `http.Client`）、`SyncEngineImpl`（推送多批/拉取/游标/退避/离线/清理）、`SyncEntityStore` 双实现无入队与 conversation 派生列保留、`fromSyncJson` 往返。
- [ ] 幂等：同 `op_id` 重放不产生重复实体（Worker + 引擎测试）。
- [ ] 增量：`cursor` 持久化、`seq` 过滤、`hasMore` 循环、发起设备过滤、**无 MAX(seq) 漏读**。
- [ ] 收敛：双客户端 + 假 Worker 最终一致、重复同步不重复实体（A7）。
- [ ] LWW：服务端/客户端同规则；冲突可解释（`conflicted` + 摘要 + 收敛清理）。
- [ ] 离线：断网入队、状态 `offline`、恢复后同步。
- [ ] 配置/身份：`syncBaseUrl` 持久化、token 安全存储（不落库/不日志）、`workspaceId`/`lastSyncAt` 持久化。
- [ ] 触发：设置页手动 + 启动自动（未配置空转）。
- [ ] 状态页：状态/上次时间/待同步数/失败与冲突摘要/手动同步/重试失败/配置/脱敏/错误文案。
- [ ] `flutter analyze` 0 issues；`flutter test` 全绿；`worker npm test` 全绿。
- [ ] 文档：`worker/README.md`（本地运行/测试/部署步骤）；§16 修订记录。

## 13. 分 lane

- **Lane-0 契约冻结**（先行，含 B1–B5 落实）：域接口/值对象（`sync_api`/`sync_change`/`sync_entity_store`/`sync_cursor_store`/`sync_credential_store`/`sync_status`/`lww.dart`、`SyncEngine` 迁址与扩展）、`SyncReport.cursor:int?`、`SyncOperationRepository` 三新方法、`SettingsStore.syncBaseUrl`、`app_config` 常量、`core/errors` 三异常、`fromSyncJson` **签名**。冻结后 A–D 不再改接口。
- **Lane-A Worker**：`worker/` 全量（TS + D1 迁移 + vitest）。**可独立验收**。
- **Lane-B 客户端落库与应用**：`SyncEntityStore` 双实现（含内存侧数据层接缝 + conversation 列级写入）+ `fromSyncJson` 实现 + 仓储三新方法 + 凭证/游标存储 + 契约/反序列化测试。（依赖 Lane-0；与 A 并行）
- **Lane-C 客户端引擎**：`WorkerSyncApi` + `SyncEngineImpl` + `di` 装配 + `main` 启动触发 + 引擎/API/收敛测试。（依赖 Lane-0 与 Lane-B 接口；可与 A 并行）
- **Lane-D UI**：同步状态页 + 设置入口 + widget 测试。（依赖 Lane-0 的 `SyncStatus` 接口；可并行）
- **Lane-E 终审**：oracle 独立复核 Worker 协议 + 客户端引擎一致性（幂等/LWW/游标/回声/收敛），再里程碑验证。

顺序：Lane-0 →（A ∥ B ∥ D，C 待 B 接口就绪）→ 合流 → Lane-E → 单 commit。

## 14. 开放问题

1. ~~冲突后即时收敛~~ → **已裁决（A9）**：push→pull 同次同步内 LWW 覆盖本地即收敛，无需额外立即拉取；由 §6.1 步骤 3/4 保证。
2. ~~游标漏读~~ → **已裁决（B2）**：游标 = 本次扫描最大 seq，设备过滤不参与游标。
3. **服务端限流**：首期实现基础限流（每 token 每分钟 N 请求）或仅记档后置？
4. **设备撤销**：状态页是否暴露「退出同步/撤销设备」（清 token + 撤销端点），或后置？
5. **多设备同 `userId`**：同匿名 `userId` 多设备共享同一 workspace（符合单用户多设备）；是否需防误绑校验？
6. **token 失效**：`401` 时引擎是否自动重新 `register` 一次并重试，或直接失败待手动？（建议：自动重注册一次）
7. **统一 `entities` 表**：首期是否足够，或按实体分表（基线二者皆可）——建议统一表。
8. **拉取上限**：`limit` 上限 500 是否足够，或需服务端分批/压缩。

## 15. 与设计基线的偏离（记档）

- 第五区沿用「设置」而非「我的」（M2a A10 延续）；同步为设置子页。
- 基线 §6.2「不同字段优先合并」→ 首期整实体 LWW（用户决策②）。
- **基线 §6.2 冲突提示**：基线要求「任务完成状态、删除、日历时间变更需生成冲突提示、不静默覆盖」。Rev 1 为纯 LWW + 状态页 `conflicted`/`failed` 摘要展示（A10），**不弹交互式提示**——记为已知偏离，M3 评估。
- 基线 §5 `SyncEngine.watchState()` 草图 → `watchStatus()`（携带报告/错误/上次时间，B4）。
- **匿名注册信任客户端 `userId`（A1）**：在 `userId=UUIDv4`（`core/ids`，满足熵）+ 仅经 TLS 传输 + 从不日志/外发的假设下**显式接受**；此后身份只来自 token；pull/push 不接受客户端 `workspaceId`。
- `SyncOperationStatus.syncing` 保留不用（§6.1/§7.5）。
- `change_log` 无压缩/保留策略（A5）：生产前必须补，且不得改动已发出的 `seq` 空间；本轮不在范围。
- 真实部署不在本轮（用户决策）。
- 远端消息不重算会话预览（§6.3，M3 评估）。

## 16. 修订记录（Rev 0 → Rev 1）

| 编号 | 处置 |
|---|---|
| **B1** push 字段来源不一致（LWW 主键失效） | §4/§5.2/§5.4：`version/updatedAt/deletedAt` 权威来源 = **payload**；`device_id` 取自 **token**；push 信封删除 `version/updatedAt/deviceId`；新增所有权校验 `payload.userId==token.userId` |
| **B2** pull 游标漏读 | §5.3：游标 = 本次扫描最大 `seq`，设备过滤仅在组装阶段；弃用 `MAX(seq)`；§11.1-3 增并发不漏读回归；§14.2 关闭 |
| **B3** `SyncReport.cursor` 类型 | §3/§6.1/§6.6：`String?` → `int?`（同步 `copyWith` 与 `entities_test`） |
| **B4** UI 观测接口缺失 | §6.6 新增 `SyncStatus` + `watchStatus()`/`status`；取代基线 `watchState()` |
| **B5** `applyRemote` 语义未闭合 | §6.3：内存侧数据层内部接缝（不进域接口）+ conversation **列级写入**保留派生列 + 墓碑措辞明确；§6.3/§15 记档预览不重算 |
| A1 匿名信任 userId | §15 记为显式接受风险；身份只来自 token |
| A2 推送不循环分批 | §6.1 步骤 2 改为循环分批（`maxPushPasses`） |
| A3 push 响应游标无定义 | §5.2 删除 push 的 `cursor` |
| A4 `conflicted`/`failed` 生命周期 | §6.1/§7.5：`deleteConflicted` + `requeueFailed`；§6.5 三方法 |
| A5 `change_log` 无保留策略 | §15 记档（生产前补） |
| A6 `lastSyncAt` 未持久化 | §9.2 `SyncCursorStore` 增 `readLastSyncAt/writeLastSyncAt` |
| A7 缺跨设备收敛验收 | §11.2-10 `sync_engine_convergence_test`；§12 增项 |
| A8 `fromSyncJson` 错误类型 | §6.4 统一 `SyncDecodeException`；嵌套 `changes` 包装 `PlanValidationException` |
| A9 §14.1 冲突即时收敛 | §14.1 关闭（push→pull 已收敛） |
| A10 基线冲突提示偏离 | §10.1 状态页增失败/冲突摘要 + 「重试失败项」；§15 记档 |
| A11 `WorkerSyncApi` 注入 `http.Client` | §6.2 明确构造注入 |
| A12 lane 顺序 | §13 依 B1–B5 修订；Lane-0 增接口，D 因 B4 解除阻塞 |

## 17. 交付记录（Rev 1 实施）

**状态**：M2b 已实施完成，§12 验收全部达成；单 commit 提交。

### 17.1 分 lane 结果
- **Lane-0 契约冻结**：`SyncEngine` 迁址 + `SyncStatus`/`sync_api`/`sync_change`/`sync_entity_store`/`sync_cursor_store`/`sync_credential_store`/`lww`；`SyncReport.cursor: int?`；`SyncOperationRepository` 三新方法；`SettingsStore.syncBaseUrl`；三异常；`app_config` 常量。
- **Lane-A Worker**：`worker/`（TS + D1 迁移 + vitest）全量；**未部署**（用户决策）。
- **Lane-B 落库与应用**：`fromSyncJson`（六实体）+ `SyncEntityStore` 双实现（Drift/内存，含内存侧数据层接缝 + conversation 列级写入）+ 游标/凭证存储 + 契约测试。
- **Lane-C 引擎**：`WorkerSyncApi` + `SyncEngineImpl` + `di` 装配 + `main` 启动触发 + 引擎/API/收敛测试。
- **Lane-D UI**：同步状态页 + 设置入口 + widget 测试。
- **Lane-E 终审**：@oracle 独立复核（结论见 17.3）。

### 17.2 验证（提交前实测）
- `flutter analyze`：**0 issues**。
- `flutter test`（全量）：**313 通过**（M2a 基线 238 → 313，+75）。
- `worker`：`tsc --noEmit` 干净；`npm test` **5 文件 / 41 用例通过**。

### 17.3 终审结论与处置
@oracle 对 Rev 1 实现的终审：**1 阻断（B1）+ 4 建议**。
- **B1（已修·阻断）**：`SyncEngineImpl.sync()` 缺 `finally` → 依赖抛**非 `AppException`**（损坏 payload `FormatException`、枚举漂移 `ArgumentError`、Drift `SqliteException`）时状态永久停在 `syncing`，重入护栏令同步**不可自愈砖化**。修复：补 `finally` 落地 `failed` 终态，并增针对性测试。
- **A1（已修）**：推送多轮时 401 重注册后的新 token 未回写外层变量 → 每轮重复注册；改为每轮回读。
- **A2（已修）**：`WorkerSyncApi._buildUri/_effectiveBaseUrl` 分支冗余、`//` 隐患；收敛为统一归一化并补测试。
- **A4（已修）**：`sync_entity_store_contract_test` 注释与 `store_date_time_values_as_text` 事实不符；修正并改用含亚秒样本 + 新增亚秒 LWW 用例。
- **A3（延后·记档）**：Worker 推送幂等为「先读后写」非原子，同 `op_id` 并发竞争可撞唯一索引返回 500、客户端重试后收敛。契约 §5.3 已记单写者假设；本轮不改动 Worker 以免扰动已绿的 41 项测试。建议生产前改为 `INSERT ... ON CONFLICT(workspace_id, op_id) DO NOTHING` 并据 `changes()` 返回 `applied`。
