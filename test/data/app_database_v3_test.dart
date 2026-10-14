import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/conversation_repository_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造待落库消息（id/时间由仓储维护）。
Message _message(String conversationId, String content) {
  final stamp = DateTime(2000);
  return Message(
    id: '',
    userId: '',
    createdAt: stamp,
    updatedAt: stamp,
    version: 0,
    deviceId: '',
    conversationId: conversationId,
    role: MessageRole.user,
    type: MessageType.text,
    content: content,
    status: MessageStatus.sent,
  );
}

/// M1（schema v2）的 `ai_plans` 建表语句，缺少 v3 新增的 `expired_at` 列。
///
/// 用于在不依赖 drift 迁移工具链的前提下，构造一个真实存在于内存中的 v2 库，
/// 再交给 [AppDatabase]（schemaVersion=3）触发 `onUpgrade(2, 3)`（B3）。
const String _v2AiPlansDdl = '''
CREATE TABLE ai_plans (
  id TEXT NOT NULL PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 1,
  device_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  source_message_id TEXT NOT NULL,
  status TEXT NOT NULL,
  ai_model TEXT NOT NULL,
  ai_model_version TEXT,
  prompt_version TEXT NOT NULL,
  changes TEXT NOT NULL,
  confirmed_at INTEGER,
  applied_at INTEGER,
  rejected_at INTEGER
)''';

void main() {
  group('AppDatabase schema v3', () {
    test('2→3 升级：三表建立且 ai_plans.expired_at 可读写', () async {
      final executor = NativeDatabase.memory(
        setup: (db) {
          db.execute(_v2AiPlansDdl);
          db.execute('PRAGMA user_version = 2');
        },
      );
      final database = AppDatabase(executor);
      addTearDown(database.close);

      // 首次查询触发迁移。
      final version = (await database
              .customSelect('PRAGMA user_version')
              .getSingle())
          .read<int>('user_version');
      expect(version, 3);

      // 三张新表已建立（可查询，空表）。
      expect(await database.select(database.syncOperations).get(), isEmpty);
      expect(await database.select(database.calendarEntries).get(), isEmpty);
      expect(await database.select(database.projects).get(), isEmpty);

      // expired_at 列经 addColumn 补入，可写可读。
      final columns =
          await database.customSelect("PRAGMA table_info('ai_plans')").get();
      expect(
        columns.map((row) => row.read<String>('name')),
        contains('expired_at'),
      );

      await database.customStatement(
        "INSERT INTO ai_plans (id, user_id, created_at, updated_at, version, "
        "device_id, conversation_id, source_message_id, status, ai_model, "
        "prompt_version, changes) "
        "VALUES ('p1','u1',0,0,1,'d1','c1','m1','awaitingConfirmation','m','v',"
        "'{\"changes\":[]}')",
      );
      await database.customStatement(
        "UPDATE ai_plans SET expired_at = 456 WHERE id = 'p1'",
      );
      final row = await database
          .customSelect("SELECT expired_at FROM ai_plans WHERE id = 'p1'")
          .getSingle();
      expect(row.read<int>('expired_at'), 456);
    });

    test('全新建库（onCreate）含三新表且 expired_at 列可用', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final version = (await database
              .customSelect('PRAGMA user_version')
              .getSingle())
          .read<int>('user_version');
      expect(version, 3);

      expect(await database.select(database.syncOperations).get(), isEmpty);
      expect(await database.select(database.calendarEntries).get(), isEmpty);
      expect(await database.select(database.projects).get(), isEmpty);

      final columns =
          await database.customSelect("PRAGMA table_info('ai_plans')").get();
      expect(
        columns.map((row) => row.read<String>('name')),
        contains('expired_at'),
      );
    });

    test('clearMessages 墓碑化：物理行仍在、deleted_at 非空、查询不含（§8）', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = ConversationRepositoryImpl(
        database,
        const SystemClock(),
        syncOperationRepository: SyncOperationRepositoryImpl(
          database,
          const SystemClock(),
          userId: 'u1',
          deviceId: 'd1',
        ),
        userId: 'u1',
        deviceId: 'd1',
      );

      final conversation = await repository.createConversation(title: '会话');
      await repository.addMessage(_message(conversation.id, 'a'));
      await repository.addMessage(_message(conversation.id, 'b'));
      expect((await repository.getMessages(conversation.id)).length, 2);

      await repository.clearMessages(conversation.id);

      // 查询语义：过滤 deletedAt IS NULL。
      expect(await repository.getMessages(conversation.id), isEmpty);

      // 物理行仍在，且墓碑字段与版本已写（用聚合规避 DateTime 存储格式差异）。
      final counts = await database
          .customSelect(
            'SELECT COUNT(*) AS total, '
            'SUM(CASE WHEN deleted_at IS NOT NULL THEN 1 ELSE 0 END) AS tombstoned, '
            'MIN(version) AS min_version '
            'FROM messages WHERE conversation_id = ?',
            variables: <Variable<Object>>[
              Variable.withString(conversation.id),
            ],
          )
          .getSingle();
      expect(counts.read<int>('total'), 2);
      expect(counts.read<int>('tombstoned'), 2);
      expect(counts.read<int>('min_version'), 2);
    });
  });
}
