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

/// 本地 Drift 数据库（schemaVersion = 1）。
@DriftDatabase(tables: [Conversations, Messages])
class AppDatabase extends _$AppDatabase {
  /// 使用给定执行器创建数据库（测试可传内存执行器）。
  AppDatabase(super.e);

  /// 打开设备上的持久化数据库。
  factory AppDatabase.open() =>
      AppDatabase(driftDatabase(name: 'chatwithalice'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          // F3：消息独立于会话（无外键约束、无级联删除），删除与同步统一由应用层
          // 负责，M2 起改用同步墓碑；因此不再设置未生效的 PRAGMA foreign_keys，
          // 避免给人「存在外键约束」的错觉。消息表的会话 ID 索引见 Messages 表定义。
          // F10：启用 WAL 提升并发读性能；内存库会忽略该设置，不影响测试。
          await customStatement('PRAGMA journal_mode = WAL');
        },
      );
}
