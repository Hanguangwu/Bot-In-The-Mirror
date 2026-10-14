# M2a 实施说明：本地同步基座与日历（Rev 1）

> 设计基线：`docs/产品与技术设计方案.md`（§3 信息架构五区、§4.1 领域模型、§5 存储 `line 136`「本地事务写实体和 `sync_operations`」、§7.2 任务拆解工作流、§11 M2 里程碑）。
> 前置：M1 已完成（`docs/M1-实施说明.md`，commit `aabfdd6`）。
> 用户决策（2026-10-13）：① M2 分两期——**M2a 本地优先**（本契约）与 M2b 云端（Worker API/D1/设备注册/增量同步/冲突提示/同步状态页，另立契约）；② 云端身份 = **匿名工作区 token**（M2b 用）；③ 同步**首期不加密**。
> 评审：Rev 0 经 oracle 设计评审（B1–B6 阻断 + A1–A10 建议全部吸收，见 §16）。

## 1. M2a 目标与验收

- **稳定匿名身份**（B1）：`userId`/`deviceId` 首启生成并持久化，注入全部仓储——同一库内所有实体与同步操作共享同一身份。
- **同步队列落库**：`SyncOperations` 表 + 仓储，**全部实体写路径在事务内入队**（B2；不触网，M2b 由 SyncEngine 消费）。
- **删除改用墓碑**：消除唯一物理删除路径（`clearMessages`），消息软删。
- **日历**：`CalendarEntries` 表 + 仓储 + 日/周/月视图；任务与日程统一展示；AI 拆解支持 `scheduleTask`（含 prompt 改造，B6）。
- **项目**：`Projects` 表 + 仓储；任务页内项目分组与管理（设计基线：项目在任务区内）。
- **导航扩为基线五区**：对话 / 任务 / 日历 / 健康（占位）/ 设置。
- **AI 计划自动过期**：`AIPlan.expired` 落地（含 `expiredAt` 列迁移，B3）。
- `flutter analyze` 0 issues；`flutter test` 全绿（数量在前一里程碑基础上增加）。

## 2. 边界（本期不做）

- **不做云端**（Worker/D1/设备注册/增量同步/冲突解决/同步状态页/同步开关）——M2b；`SyncEngine` 仍只声明不实现；`SyncState/SyncReport` 不消费。
- **不做健康功能**（M3）：健康 tab 仅占位页。
- **不做语音/成就/图片**（M3/M4）。
- **不做首页「最近对话/今日重点」卡片**（M1 已确认偏离，保持）。
- **不做任务过期状态迁移**：Task 无 `expired` 状态；「已过期」维持任务页视觉徽标。
- **不做日历拖拽排期/重复规则**：`repeatRule` 字段保留不实现；`allDay` 支持展示与创建。
- **不做 `scheduleTask` 的任务关联**（B5）：`taskIds` 恒空、`payload.taskId` 保留不用（AI 无从引用尚未生成的任务 id）。
- **不做同步队列清理/归档策略**（synced 操作删除）——M2b 定。
- **不改任务页已有三滤镜交互**（项目分组为附加维度）。

## 3. 目录与新增/改动文件

```
# 域层（新增）
lib/domain/repositories/sync_operation_repository.dart   # 同步队列仓储接口
lib/domain/repositories/calendar_entry_repository.dart   # 日历条目仓储接口
lib/domain/repositories/project_repository.dart          # 项目仓储接口
lib/domain/sync/entity_serializer.dart                   # 实体 → SyncOperation payload（仅 toSyncJson）
# 数据层（新增）
lib/data/local/sync_operation_repository_impl.dart       # 队列仓储（队列写入不入队）
lib/data/local/calendar_entry_repository_impl.dart       # 事务化 + 入队（save/delete → create/update/delete）
lib/data/local/project_repository_impl.dart              # 事务化 + 入队（save/delete → create/update/delete）
lib/data/local/identity_store.dart                       # 持久化匿名身份（shared_preferences）
lib/data/memory/memory_sync_operation_repository.dart
lib/data/memory/memory_calendar_entry_repository.dart
lib/data/memory/memory_project_repository.dart
lib/data/memory/memory_store.dart                        # Memory 全或无接缝（snapshot/restore 注册表）
# 改动
lib/domain/repositories/ai_plan_repository.dart          # + markExpired
lib/domain/entities/ai_plan.dart                         # + expiredAt、calendarEntryFromPlanChange
lib/domain/entities/calendar.dart                        # （无改动，已齐）
lib/core/config/app_config.dart                          # + aiPlanExpireAfter
lib/data/local/app_database.dart                         # schema v3 + onUpgrade(addColumn)
lib/data/local/app_database.g.dart                       # 重新生成
lib/data/local/conversation_repository_impl.dart         # 事务化 + 入队 + clearMessages 墓碑
lib/data/local/task_repository_impl.dart                 # 事务化 + 入队
lib/data/local/ai_plan_repository_impl.dart             # 事务化 + 入队 + scheduleTask 物化 + markExpired
lib/data/ai/openai_client.dart                           # prompt 增 scheduleTask + m2a-plan-v1
lib/data/memory/{memory_conversation_repository,memory_task_repository,memory_ai_plan_repository}.dart  # 入队 + 原子接缝
lib/features/tasks/application/{propose_task_plan,confirm_task_plan}.dart  # scheduleTask 支持
lib/features/tasks/application/expire_pending_plans.dart # 新：自动过期用例
lib/features/home/home_shell.dart                        # 五区导航
lib/features/health/health_screen.dart                   # 新：占位
lib/features/calendar/calendar_screen.dart               # 新：日/周/月
lib/features/calendar/widgets/entry_edit_dialog.dart     # 新
lib/features/tasks/tasks_screen.dart                     # 项目分组 + 过期扫描触发
lib/features/tasks/widgets/{task_edit_dialog,plan_preview_card}.dart  # 项目下拉 / scheduleTask 预览
lib/features/tasks/widgets/project_manage_dialog.dart    # 新：项目管理
lib/di.dart                                              # 身份 + 三新仓储 + 原子接缝装配
```

## 4. Schema v3（`app_database.dart`）

沿用 M1 模式：枚举列 TEXT（`.name`）、无外键、PK `{id}`；`beforeOpen` 注释更新为「M2a 起写路径统一入同步队列」。

### 4.1 SyncOperations
Syncable 七字段 + `entityType` TEXT、`entityId` TEXT、`kind` TEXT、`payload` TEXT（实体快照 JSON，§6）、`status` TEXT、`retryCount` INTEGER 默认 0、`lastError?` TEXT、`syncedAt?` TEXT。
索引：`sync_operations(entityType, status)`、`sync_operations(entityId)`。

### 4.2 CalendarEntries
Syncable 七字段 + `title` TEXT、`startAt`/`endAt` TEXT（ISO8601 本地时间，沿用 dueAt 落库模式）、`allDay` INTEGER 默认 0、`taskIds` TEXT（JSON 字符串数组）、`note?` TEXT。
索引：`calendar_entries(userId, startAt)`。

### 4.3 Projects
Syncable 七字段 + `name` TEXT、`goal?` TEXT、`isArchived` INTEGER 默认 0。
索引：`projects(userId)`。

### 4.4 onUpgrade（**含存量列迁移，B3**）
```
if (from < 3) {
  createTable(syncOperations); createTable(calendarEntries); createTable(projects);
  createIndex ×3;
  addColumn(aiPlans, aiPlans.expiredAt);   // M1 存量表补列（createTable 不会补）
}
```
验证：`app_database_v3_test` 断言 2→3 升级后三表存在且 `ai_plans.expiredAt` 列可读写。

## 5. 仓储接口

### 5.1 SyncOperationRepository
```dart
abstract interface class SyncOperationRepository {
  Stream<List<SyncOperation>> watchPending();          // status==pending，createdAt,id 正序
  Future<List<SyncOperation>> getPending();
  Future<void> enqueue(SyncOperation operation);       // 调用方所在事务内执行，内部不另开事务
  Future<void> enqueueAll(List<SyncOperation> operations);
  Future<void> mark(SyncOperation operation);          // M2b 消费（本期仅测试用）
}
```
- **不得递归**：队列自身写入永不入队（实现保证，无回环）。
- 排序稳定：`createdAt` 相同按 `id` 兜底（A10）。

### 5.2 CalendarEntryRepository
```dart
abstract interface class CalendarEntryRepository {
  Future<List<CalendarEntry>> getInRange(DateTime start, DateTime end);   // 半开 [start,end)，按 startAt 命中
  Stream<List<CalendarEntry>> watchInRange(DateTime start, DateTime end); // 稳定排序 (startAt, id)
  Future<CalendarEntry?> get(String id);
  Future<CalendarEntry> save(CalendarEntry entry);
  Future<void> delete(String id);   // 软删墓碑
}
```
**区间语义（A8）**：按 `startAt ∈ [start, end)` 命中（跨夜条目按起始日归属）；已删一律过滤；排序 `(startAt, id)`。记档：M2a 不做 overlap 查询。
**写入语义（§7.3）**：`save`/`delete` 在 `_db.transaction` 内完成「实体写入 + 入队」——新建 `calendar_entry` `create`、更新 `update`、墓碑 `delete`（快照含 `deletedAt`）；Memory 实现经 `MemoryStore.runAtomic` 同语义。

### 5.3 ProjectRepository
```dart
abstract interface class ProjectRepository {
  Future<List<Project>> getProjects();
  Stream<List<Project>> watchProjects();
  Future<Project?> get(String id);
  Future<Project> save(Project project);
  Future<void> delete(String id);   // 仅墓碑化项目；不改任务（孤儿由 UI 按无分组展示），M2b 前不做级联
}
```
**写入语义（§7.3）**：同 §5.2——`save`/`delete` 事务内入队 `project` `create`/`update`/`delete`（墓碑快照含 `deletedAt`）。

### 5.4 IdentityStore（B1）
```dart
/// 设备级匿名身份；首启生成并持久化，之后恒定。
abstract interface class IdentityStore {
  String get userId;     // 稳定匿名用户 ID
  String get deviceId;   // 稳定设备 ID
  Future<void> load();   // configureDependencies 首启读取/生成
}
```
- 实现 `lib/data/local/identity_store.dart`：`shared_preferences` 读写键 `anonymous_user_id`/`anonymous_device_id`；缺失时用 `core/ids` 的 `newUserId()`/`newDeviceId()` 生成后写回。测试实现 `MemoryIdentityStore`（固定值）。
- **注入范围**：`configureDependencies` 在 `load()` 后把 `identity.userId/deviceId` 传给**全部**仓储（conversation/task/ai_plan/calendar/project/syncOperation）与 DI 内其它需要身份处；`resetDependenciesForTest` 注入固定值（如 `user-1`/`device-1`）。
- 清理：删除 `task_edit_dialog.dart` 里手写的 `newUserId()/newDeviceId()`（被仓储覆盖的死代码）。

## 6. 同步 payload 协议（`lib/domain/sync/entity_serializer.dart`）

冻结协议（M2b 不得改）；**本期只实现 `toSyncJson`**（A4，YAGNI）。

- **payload = 实体快照对象本身**（不回填 `entityType/entityId/kind`——它们已是 `SyncOperations` 列，避免漂移；A5）。
- 六实体：`Conversation`、`Message`、`Task`、`AIPlan`、`CalendarEntry`、`Project`。
- **时间一律 UTC ISO8601**（`.toUtc().toIso8601String()`，带 `Z`）——**修正 Rev 0 的「本地无偏移」错误（B4）**；DB 列仍用 Drift `DateTimeColumn`，不受影响。
- 枚举 `.name`；布尔 JSON bool；`List<String>` JSON 数组；可空字段为 null **则省略该键**；`kind=delete` 快照**必须含 `deletedAt`**（墓碑时间，供 M2b 排序/冲突判定）。
- **排除派生字段（A1）**：`Conversation.lastMessagePreview`/`lastMessageAt` **不进快照**（客户端派生数据，见 §7.2）。
- 测试：往返 + 固定样例快照断言（防字段漂移）。

## 7. 入队规则矩阵（写路径 → SyncOperation）

### 7.1 原子性总原则（B2）
- **所有写路径必须包 `_db.transaction`（Drift）**：新增 M1 未事务化的 `TaskRepositoryImpl.save`、`createConversation`/`updateConversation`/`deleteConversation`/`ensureDefaultConversation`、`AIPlanRepositoryImpl.save`/`reject`；已事务化的 `addMessage`/`clearMessages`/`applyChanges`/`confirm` 保持。
- 实体写入与 `enqueue` 在**同一事务**；M2a 新增 `runInWrite(callback)` 私有接缝统一包裹。
- **回滚不留孤儿操作**（§12 断言）：事务内异常时队列与实体一并回滚。

### 7.2 Memory 全或无接缝（A6）
`lib/data/memory/memory_store.dart`：注册表式 `MemoryStore`，各 Memory 仓储启动时注册 `snapshot()/restore()`；`runAtomic(fn)` 先快照全部注册方，`fn` 抛异常则全部 restore。跨仓储 `confirm`（tasks+calendar+plan+queue）与单仓储写都经 `runAtomic`，使双实现可等价断言。

### 7.3 矩阵

| 写路径 | kind | entityType | 备注 |
|---|---|---|---|
| createConversation | create | conversation | 事务化（新） |
| updateConversation | update | conversation | 事务化（新） |
| deleteConversation | delete | conversation | 墓碑；事务化（新） |
| addMessage | create | message | 与摘要同事务；**仅消息入队** |
| clearMessages | delete ×N | message | 逐条墓碑化入队（`enqueueAll` 单事务，B/通过项） |
| TaskRepository.save 新建/更新 | create/update | task | 事务化（新） |
| applyChanges 内 Inserted/Updated/Deleted | create/update/delete | task | 同事务入队，快照=最终实体 |
| AIPlanRepository.save | create/update | ai_plan | 事务化（新） |
| confirm 物化 | create ×(N+M) + update ×1 | task / calendar_entry / ai_plan | 同一事务：任务与日历条目 create、计划 applied 的 update |
| reject / markExpired | update | ai_plan | **改/补事务**（状态更新 + 入队原子） |
| CalendarEntry save/delete | create/update/delete | calendar_entry | |
| Project save/delete | create/update/delete | project | |
| ensureDefaultConversation | create | conversation | 仅真正创建时 |

其它入队字段：`id: generateId()`、`userId/deviceId` 取注入身份、`createdAt=updatedAt=now`、`version: 1`、`payload: entity.toSyncJson()`、`status: pending`。

### 7.4 会话摘要不入队、不 bump version（A1）
`addMessage`/`clearMessages` 更新 `lastMessagePreview`/`lastMessageAt` 时**不改 `conversation.updatedAt`、不 bump `conversation.version`、不入队**（派生字段；且已排除出快照 §6）。会话列表排序仍按 `lastMessageAt`。记档：避免与 M2b「同字段以较新 `updatedAt` 为准」产生永久偏差。

## 8. clearMessages 墓碑化

事务内：`UPDATE messages SET deletedAt=now, updatedAt=now, version=version+1 WHERE conversationId=? AND deletedAt IS NULL`；逐条 `enqueueAll` message delete（快照含 deletedAt）；会话摘要重置同 §7.4。
查询语义：`watchMessages`/`getMessages` 一律**过滤 `deletedAt IS NULL`**（M1 已如此，Rev 0 §8 措辞笔误已修，A9）。契约测试更新为软删断言（行仍存在、列表不含）。

## 9. AI 计划自动过期

- `AIPlan` 增加 `expiredAt?`；`copyWith` 不加 clearX（该字段只设不清；注释标注为 M2 约定的例外）。
- 策略：**读取时惰性**。`ExpirePendingPlans`：找 `status==awaitingConfirmation && createdAt 距今 > aiPlanExpireAfter` → `AIPlanRepository.markExpired(ids)`（事务内：置 expired + expiredAt=now + 入队 ai_plan update）。
- `aiPlanExpireAfter` 默认 `Duration(hours: 48)`，置于 `app_config.dart`（测试注入短时长或构造旧 `createdAt`）。
- 触发点：`TasksScreen.initState` fire-and-forget（`IndexedStack` 启动即构建，等价启动扫描）。**不启动定时器**。
- `confirm`/`reject` 前置校验遇非 `awaitingConfirmation` 抛 `ConflictException`（M1 语义延续，含 expired）。

## 10. AI 拆解 `scheduleTask` 支持

- **prompt 改造（B6）**：`openai_client.dart` 的 `planSystemPrompt` 增加 `scheduleTask` 输出说明（键 `title` 必填、`startAt`/`endAt` ISO、`note?`）；`planPromptVersion` → **`m2a-plan-v1`**。
- `_parsePlan` 接收 `scheduleTask`：校验 `title` 非空、`endAt > startAt`（解析后比较），否则抛 `PlanValidationException`；不再「见到即抛」。
- **不关联任务（B5）**：`taskIds` 恒空；`payload.taskId` 键保留但忽略。
- 新增 `calendarEntryFromPlanChange(AIPlan plan, AIPlanChange change, {required String userId, required String deviceId, required DateTime now})` 于 `ai_plan.dart`，与 `taskFromPlanChange` 同签名风格；`allDay=false`、`taskIds=[]`、`note` 从 payload。
- `confirm` 原子事务：物化 createTask → TaskInserted；物化 scheduleTask → CalendarEntry；计划 applied。全部入队（§7.3）。
- 预览卡 `_buildChange` 分支：createTask 现状；scheduleTask 显示「日程 · {title} · {HH:mm–HH:mm}」。
- 空变更规则不变（S4：changes 空 → 整个不落库，`propose` 返回 null）。

## 11. UI 规格（中文文案）

### 11.1 五区导航（`home_shell.dart`）
`BottomNavigationBar` 5 items：对话(`chat_bubble_outline`)/任务(`checklist`)/日历(`calendar_month`)/健康(`favorite_border`)/设置(`settings`)；`IndexedStack` 5 child。健康 = `HealthScreen`（居中图标 + 灰字「健康功能将在后续版本提供」）。新 tab 不加 FAB；沿用 `heroTag` 约束。
**记档偏离（A10）**：第五区沿用「设置」而非设计基线的「我的」；同步状态页 M2b 落位时再评估是否更名。

### 11.2 任务页：项目分组 + 过期扫描
- 三滤镜 chips 下方加「项目」`DropdownButton`（全部/各项目名）；选中即本地过滤 `task.projectId`（不下推）。
- AppBar actions 加项目管理入口 → `ProjectManageDialog`（列表：名称/目标/归档切换/删除；「新建项目」；删除二次确认）。
- `initState` 触发 `ExpirePendingPlans`（fire-and-forget，失败静默）。
- 任务编辑对话框加「项目」下拉（可选，取 `watchProjects`）。

### 11.3 日历页（`calendar_screen.dart`）
- 自带 `Scaffold` + `AppBar('日历')`；`SegmentedButton` 日/周/月；数据源 `watchInRange(区间)`（切视图重订阅）+ `watchTasks(const TaskQuery())` 叠加 `dueAt` 任务。
- 日：按时段分组的卡片列表（不做像素级时间格）；周：7 列 × 每日小区块列条目标题/任务标题；月：7 列网格，日格最多 3 条 + 「+N」。
- 条目 = CalendarEntry（标题 + `HH:mm` 起止）+ 当日 `dueAt` 未完成任务（按状态灰名/划线）。点条目→编辑；点空白→新建（预填日期）。
- `entry_edit_dialog.dart`：标题必填、起止 date+time picker（校验 end>start）、allDay 开关、关联任务多选 chips、备注多行、编辑态删除（确认→软删）。
- 空态：「这一天还没有安排，点右下角按钮添加」。

### 11.4 设置页不动。

## 12. 测试方案（不触网、不依赖真实 LLM/平台存储、不调生产 `configureDependencies()`）

沿用 M1 契约测试双实现（`_runContract` + Memory vs Drift `NativeDatabase.memory()`；`_MutableClock`）。新增：
1. `sync_operation_repository_contract_test`：enqueue/enqueueAll/getPending/watchPending 排序（含 id 兜底）、mark 状态流转、双实现。
2. `calendar_entry_repository_contract_test`：save 齐全/version 递增、`getInRange`/`watchInRange` 半开区间、软删过滤、稳定排序、**save/delete 入队（calendar_entry create/update/delete + 墓碑快照含 deletedAt）**、双实现。
3. `project_repository_contract_test`：save/软删/watchProjects 过滤、**save/delete 入队（project create/update/delete）**、双实现。
4. `entity_serializer_test`：六实体 `toSyncJson` 键/值断言（UTC 时间、枚举 `.name`、空值省键、delete 含 deletedAt、会话派生字段被排除）+ 固定样例快照。
5. `expire_pending_plans_test`：47h59m 不过期 / 48h01m 过期、已 applied/rejected 不动、`markExpired` 入队、确认过期计划抛 ConflictException。
6. `app_database_v3_test`：2→3 升级建表 + `ai_plans.expiredAt` 列可用 + `clearMessages` 墓碑化（行仍在、`get/watch` 不含、入队 message delete ×N）。
7. 入队原子性断言（**B2**）：制造事务中途失败（如 applyChanges 目标不存在），断言实体与队列**均无残留**（双实现）。
8. `confirm_task_plan` 用例增补：含 scheduleTask 的确认物化 CalendarEntry + 入队 task/calendar_entry/ai_plan 三类；拒绝/过期计划抛 ConflictException。
9. `conversation_repository_contract_test`：clearMessages 软删断言更新。
10. widget 测试：五 tab 可达（`calendar_month`/`favorite_border` 图标）、健康占位文案、日历空态、项目分组切换。

## 13. 验收清单

- [ ] 身份持久化 + 注入全部仓储（同库 userId 一致、deviceId 稳定）+ 死代码清理
- [ ] schema v3 建表 + `aiPlans.expiredAt` addColumn + 生成文件
- [ ] 三新仓储双实现 + 契约测试绿
- [ ] 六实体 `toSyncJson` + UTC + 样例断言
- [ ] 全部写路径**事务化**并入队（矩阵逐行 + 回滚无孤儿断言）
- [ ] `clearMessages` 墓碑化 + 契约断言更新
- [ ] `ExpirePendingPlans` + `markExpired` + 边界测试
- [ ] scheduleTask：prompt(m2a-plan-v1)/解析/物化/预览/确认闭环 + 测试
- [ ] 五区导航 + 健康占位 + widget 测试
- [ ] 日历三视图 + 条目 CRUD + 任务叠加
- [ ] 项目分组 + 管理对话框 + 任务对话框项目下拉
- [ ] analyze 0 issues；test 全绿

## 14. 分 lane

- **Lane-0 契约冻结**（先行，A7）：`IdentityStore`/`MemoryIdentityStore`、`SyncOperationRepository`/`CalendarEntryRepository`/`ProjectRepository` 接口、`entity_serializer.dart` 接口与实现、`AIPlan.expiredAt`、`calendarEntryFromPlanChange`、`app_config.aiPlanExpireAfter`。冻结后 A/B/C 不再改接口。
- **Lane-A 数据层**：schema v3 + onUpgrade + 生成文件 + 三新仓储双实现 + `MemoryStore` 原子接缝 + `AIPlanRepository.markExpired`（接口签名 + 双实现，与入队基建同时落，避免 Lane-0 留临时抛错桩）+ di 装配 + 契约测试（1–3、6）。
- **Lane-B 写路径与策略**：全写路径事务化 + 入队矩阵 + clearMessages 墓碑 + scheduleTask 解析/物化 + ExpirePendingPlans + 原子性/序列化/用例测试（4–5、7–9）。
- **Lane-C UI**：五区导航 + 健康占位 + 日历三视图 + 条目对话框 + 项目分组/管理 + 预览卡 scheduleTask 分支 + widget 测试（10）。

顺序 Lane-0 → A → B → C；每 lane 独立验证后合流。**Lane-A/B 即 M2b 前置**，先独立可验收，UI（C）不阻塞地基。

## 15. 开放问题（已裁决）

1. 入队放仓储内事务 → **采纳**（B2 补事务包裹）；Memory 注入同一队列实例。
2. `expiredAt` 新字段 → **采纳**（B3 补 addColumn）。
3. delete 快照含 `deletedAt` → **采纳**。
4. 月/周视图简化 → **采纳**（保证区间正确 + 稳定排序 + 空态）。
5. 48h 过期 → **采纳**，配置化；`TasksScreen.initState` 触发足够。
6. reject 改事务 → **采纳**，并覆盖 `markExpired` 与 `confirm`。

## 16. 修订记录（Rev 0 → Rev 1）

| 编号 | 处置 |
|---|---|
| B1 身份不持久 | §5.4 新增 `IdentityStore`（shared_preferences 首启生成持久化）+ §3/§14 落地；清理死代码 |
| B2 入队原子性 | §7.1 全部写路径事务化 + §7.2 Memory 原子接缝 + §12.7 回滚无孤儿断言 |
| B3 expiredAt 缺迁移 | §4.4 onUpgrade 增 `addColumn(aiPlans.expiredAt)` + §12.6 列断言 |
| B4 时间格式矛盾 | §6 统一 **UTC ISO8601**；更正 Rev 0 措辞 |
| B5 scheduleTask 关联矛盾 | §2/§10 `taskIds` 恒空、`taskId` 保留不用；`calendarEntryFromPlanChange` 签名补齐 userId/deviceId/now |
| B6 prompt 不产 scheduleTask | §3/§10 prompt 改造 + `m2a-plan-v1` + §12 解析测试 |
| A1 摘要 version 偏差 | §6/§7.4 摘要派生、不入队、不 bump version、排除出快照 |
| A2 §4.2 自相矛盾 | 删除 projectId 列描述 |
| A3 文件清单遗漏 | §3 补全 |
| A4 fromSyncJson 死代码 | §6 仅实现 `toSyncJson` |
| A5 payload 冗余 | §6 payload=实体快照本身，不回填信封 |
| A6 Memory 原子性 | §7.2 `MemoryStore` 接缝 |
| A7 缺契约冻结层 | §14 新增 Lane-0 |
| A8 区间语义 | §5.2 半开 [start,end) 按 startAt + `(startAt,id)` 排序 + 记档 |
| A9 措辞错误 | §8 改 `deletedAt IS NULL` |
| A10 其它 | §11.1 记档五区命名；§5.1 队列不递归；§5.1/§5.2 id 兜底排序；§5.4 清死代码 |
| 范围建议 | 保留六块但 Lane-A/B 为 M2b 前置、先独立验收，UI 不阻塞地基 |
| **D1 实现评审（ora-3）** | calendar/project 仓储 save/delete 未事务化、未入队（§7.3 两行未实现）；修：两仓储注入队列 + 事务 + 入队（墓碑快照），**confirm 内手工 calendar_entry 入队移除**（避免重复），§5.2/§5.3/§12.2/§12.3 措辞补齐 |
| A-1 身份散落 | `openai_client` 内 `newUserId/newDeviceId` 造 AIPlan（当前被仓储覆盖，非阻断）——记档后置 |
| A-4 回滚测试偏弱 | `task`/`ai_plan` 回滚用例发生在写入前校验；建议补「部分写入后回滚」——后置 |