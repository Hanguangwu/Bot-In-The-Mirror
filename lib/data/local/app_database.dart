import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// 会话表。字段与领域实体 `Conversation` 严格对应。
@DataClassName('ConversationRow')
class Conversations extends Table {
  /// 会话 ID（客户端生成）。
  TextColumn get id => text()();

  /// 所属用户 ID。
  TextColumn get userId => text()();

  /// 会话标题。
  TextColumn get title => text()();

  /// 是否归档。
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  /// 最近消息预览。
  TextColumn get lastMessagePreview => text().nullable()();

  /// 最近消息时间。
  DateTimeColumn get lastMessageAt => dateTime().nullable()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除墓碑时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 乐观并发版本。
  IntColumn get version => integer().withDefault(const Constant(1))();

  /// 来源设备 ID。
  TextColumn get deviceId => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 消息表。字段与领域实体 `Message` 严格对应；`metadata` 存 JSON 字符串。
@DataClassName('MessageRow')
@TableIndex(name: 'idx_messages_conversation_id', columns: {#conversationId})
class Messages extends Table {
  /// 消息 ID（客户端生成）。
  TextColumn get id => text()();

  /// 所属会话 ID。
  TextColumn get conversationId => text()();

  /// 所属用户 ID。
  TextColumn get userId => text()();

  /// 角色：user/assistant/system。
  TextColumn get role => text()();

  /// 类型：text/voiceTranscription/imageReference/systemEvent。
  TextColumn get type => text()();

  /// 消息正文。
  TextColumn get content => text()();

  /// 状态：sending/sent/failed。
  TextColumn get status => text()();

  /// 生成该消息的模型名。
  TextColumn get aiModel => text().nullable()();

  /// 附加元数据（JSON 字符串）。
  TextColumn get metadata => text().withDefault(const Constant('{}'))();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除墓碑时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 乐观并发版本。
  IntColumn get version => integer().withDefault(const Constant(1))();

  /// 来源设备 ID。
  TextColumn get deviceId => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 任务表（schema v2）。字段与领域实体 `Task` 严格对应。
///
/// `status`/`priority` 为枚举列，一律存 TEXT（枚举 `.name`），与 M0
/// Conversations/Messages 一致：可读且增删枚举值不会错位历史数据（S6）。
@DataClassName('TaskRow')
@TableIndex(name: 'idx_tasks_user_status', columns: {#userId, #status})
@TableIndex(name: 'idx_tasks_user_due_at', columns: {#userId, #dueAt})
class Tasks extends Table {
  /// 任务 ID（客户端生成）。
  TextColumn get id => text()();

  /// 所属用户 ID。
  TextColumn get userId => text()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除墓碑时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 乐观并发版本。
  IntColumn get version => integer().withDefault(const Constant(1))();

  /// 来源设备 ID。
  TextColumn get deviceId => text()();

  /// 所属项目 ID（M1 恒 null，Projects 表留 M2）。
  TextColumn get projectId => text().nullable()();

  /// 任务标题。
  TextColumn get title => text()();

  /// 详细描述。
  TextColumn get description => text().nullable()();

  /// 状态：inbox/planned/doing/done/cancelled（TEXT 枚举）。
  TextColumn get status => text()();

  /// 优先级：low/medium/high/urgent（TEXT 枚举）。
  TextColumn get priority => text()();

  /// 截止时间。
  DateTimeColumn get dueAt => dateTime().nullable()();

  /// 父任务 ID（M1 恒 null，子任务 UI 留 M2）。
  TextColumn get parentTaskId => text().nullable()();

  /// 重复规则（RRULE 风格，M2 起使用）。
  TextColumn get repeatRule => text().nullable()();

  /// 来源消息 ID，用于追溯到原始对话。
  TextColumn get sourceMessageId => text().nullable()();

  /// 手动排序值，越小越靠前。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// AI 计划表（schema v2）。字段与领域实体 `AIPlan` 严格对应；
/// `changes` 存 [encodeChanges] 编出的 JSON 字符串。
///
/// `status` 为枚举列，存 TEXT（枚举 `.name`）。
@DataClassName('AiPlanRow')
@TableIndex(name: 'idx_ai_plans_user_status', columns: {#userId, #status})
class AiPlans extends Table {
  /// 计划 ID（客户端生成）。
  TextColumn get id => text()();

  /// 所属用户 ID。
  TextColumn get userId => text()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 软删除墓碑时间。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 乐观并发版本。
  IntColumn get version => integer().withDefault(const Constant(1))();

  /// 来源设备 ID。
  TextColumn get deviceId => text()();

  /// 来源会话 ID。
  TextColumn get conversationId => text()();

  /// 来源消息 ID。
  TextColumn get sourceMessageId => text()();

  /// 状态：draft/awaitingConfirmation/applied/rejected/expired（TEXT 枚举）。
  TextColumn get status => text()();

  /// 生成计划的模型名。
  TextColumn get aiModel => text()();

  /// 模型版本。
  TextColumn get aiModelVersion => text().nullable()();

  /// 提示词版本，便于回溯。
  TextColumn get promptVersion => text()();

  /// 待确认的变更列表（JSON 字符串）。
  TextColumn get changes => text()();

  /// 用户确认时间。
  DateTimeColumn get confirmedAt => dateTime().nullable()();

  /// 应用完成时间。
  DateTimeColumn get appliedAt => dateTime().nullable()();

  /// 用户拒绝时间。
  DateTimeColumn get rejectedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本地 Drift 数据库（schemaVersion = 2）。
@DriftDatabase(tables: [Conversations, Messages, Tasks, AiPlans])
class AppDatabase extends _$AppDatabase {
  /// 使用给定执行器创建数据库（测试可传内存执行器）。
  AppDatabase(super.e);

  /// 打开设备上的持久化数据库。
  factory AppDatabase.open() =>
      AppDatabase(driftDatabase(name: 'chatwithalice'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 → v2：新增任务表与 AI 计划表（含索引）。1→2 无历史数据价值，
          // 仅建表建索引，不做数据迁移（§5.1）。Drift 一次 createTable 一张表。
          if (from < 2) {
            await m.createTable(tasks);
            await m.createTable(aiPlans);
            await m.createIndex(idxTasksUserStatus);
            await m.createIndex(idxTasksUserDueAt);
            await m.createIndex(idxAiPlansUserStatus);
          }
        },
        beforeOpen: (details) async {
          // F3：消息独立于会话（无外键约束、无级联删除），删除与同步统一由应用层
          // 负责，M2 起改用同步墓碑；因此不再设置未生效的 PRAGMA foreign_keys，
          // 避免给人「存在外键约束」的错觉。消息表的会话 ID 索引见 Messages 表定义。
          // 任务与 AI 计划同样无外键：幽灵消息/孤儿任务合法，利于 M2 同步墓碑。
          // F10：启用 WAL 提升并发读性能；内存库会忽略该设置，不影响测试。
          await customStatement('PRAGMA journal_mode = WAL');
        },
      );
}
