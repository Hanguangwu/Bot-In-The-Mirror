import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/sync_entity_store_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_ai_plan_repository.dart';
import 'package:chatwithalice/data/memory/memory_calendar_entry_repository.dart';
import 'package:chatwithalice/data/memory/memory_conversation_repository.dart';
import 'package:chatwithalice/data/memory/memory_project_repository.dart';
import 'package:chatwithalice/data/memory/memory_sync_entity_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/calendar.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/sync/entity_serializer.dart';
import 'package:chatwithalice/domain/sync/sync_change.dart';
import 'package:chatwithalice/domain/sync/sync_entity_store.dart';
import 'package:chatwithalice/domain/repositories/sync_operation_repository.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定 UTC 时间（含亚秒）。`build.yaml` 设 `store_date_time_values_as_text: true`，
/// Drift 以 ISO-8601 文本落库、保留亚秒精度，故这里用含毫秒/微秒的样本，
/// 真正覆盖「相等 version 比 updatedAt」的亚秒 LWW 分支。
final DateTime _t = DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456);
final DateTime _t2 = DateTime.utc(2026, 1, 3, 6, 7, 8, 789, 12);
final DateTime _t3 = DateTime.utc(2026, 1, 4, 9, 10, 11, 500, 999);

/// 构造会话（派生列可注入，用于「保留」断言）。
Conversation _conv({
  String id = 'c1',
  String title = '会话',
  int version = 1,
  DateTime? updatedAt,
  DateTime? deletedAt,
  String? lastMessagePreview,
  DateTime? lastMessageAt,
}) =>
    Conversation(
      id: id,
      userId: 'u1',
      createdAt: _t,
      updatedAt: updatedAt ?? _t,
      deletedAt: deletedAt,
      version: version,
      deviceId: 'device-remote',
      title: title,
      lastMessagePreview: lastMessagePreview,
      lastMessageAt: lastMessageAt,
    );

Task _task({
  String id = 't1',
  String title = '任务',
  int version = 1,
  DateTime? updatedAt,
  DateTime? deletedAt,
}) =>
    Task(
      id: id,
      userId: 'u1',
      createdAt: _t,
      updatedAt: updatedAt ?? _t,
      deletedAt: deletedAt,
      version: version,
      deviceId: 'device-remote',
      title: title,
    );

/// 按运行时类型分发到 `toSyncJson`（payload 为实体快照本身）。
Map<String, Object?> _payloadOf(Object entity) => switch (entity) {
      Conversation() => entity.toSyncJson(),
      Message() => entity.toSyncJson(),
      Task() => entity.toSyncJson(),
      AIPlan() => entity.toSyncJson(),
      CalendarEntry() => entity.toSyncJson(),
      Project() => entity.toSyncJson(),
      _ => throw ArgumentError('不支持的实体：${entity.runtimeType}'),
    };

SyncChange _change(
  Object entity, {
  required String entityType,
  required String entityId,
  required int version,
  required DateTime updatedAt,
  SyncOperationKind kind = SyncOperationKind.update,
  int seq = 1,
}) =>
    SyncChange(
      seq: seq,
      entityType: entityType,
      entityId: entityId,
      kind: kind,
      version: version,
      deviceId: 'device-remote',
      updatedAt: updatedAt,
      payload: _payloadOf(entity),
    );

SyncOperation _op({String id = 'op1', String entityType = 'task'}) =>
    SyncOperation(
      id: id,
      userId: 'user-1',
      createdAt: _t,
      updatedAt: _t,
      version: 1,
      deviceId: 'device-1',
      entityType: entityType,
      entityId: 'seed',
      kind: SyncOperationKind.create,
    );

/// 被测实现与资源释放器/读取接缝的组合。
class _Harness {
  _Harness({
    required this.store,
    required this.queue,
    required this.seedConversation,
    required this.readConversation,
    required this.readTask,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  final SyncEntityStore store;
  final SyncOperationRepository queue;
  final Future<void> Function(Conversation conversation) seedConversation;
  final Future<Conversation?> Function(String id) readConversation;
  final Future<Task?> Function(String id) readTask;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 对内存实现与 Drift 实现跑同一组契约断言。
void _runContract(
  String name, {
  required Future<_Harness> Function() create,
}) {
  group(name, () {
    late _Harness harness;
    late SyncEntityStore store;
    late SyncOperationRepository queue;

    setUp(() async {
      harness = await create();
      store = harness.store;
      queue = harness.queue;
    });

    tearDown(() => harness.dispose());

    test('首写：远端变更落地且 localVersion 反映', () async {
      final entity = _task(title: '首写');
      final applied = await store.applyRemote(
        _change(entity, entityType: 'task', entityId: 't1', version: 1, updatedAt: _t),
      );

      expect(applied, isTrue);
      final local = await store.localVersion('task', 't1');
      expect(local!.version, 1);
      expect(local.updatedAt.toUtc(), _t);
      expect((await harness.readTask('t1'))!.title, '首写');
    });

    test('LWW 新胜：更高 version 覆盖', () async {
      await store.applyRemote(
        _change(_task(title: '旧'),
            entityType: 'task', entityId: 't1', version: 1, updatedAt: _t),
      );
      final applied = await store.applyRemote(
        _change(_task(title: '新', version: 2),
            entityType: 'task', entityId: 't1', version: 2, updatedAt: _t2),
      );

      expect(applied, isTrue);
      expect((await store.localVersion('task', 't1'))!.version, 2);
      expect((await harness.readTask('t1'))!.title, '新');
    });

    test('LWW 旧拒：更低 version 被拒且不覆盖', () async {
      await store.applyRemote(
        _change(_task(title: '本地新', version: 3),
            entityType: 'task', entityId: 't1', version: 3, updatedAt: _t2),
      );
      final applied = await store.applyRemote(
        _change(_task(title: '远端旧'),
            entityType: 'task', entityId: 't1', version: 1, updatedAt: _t),
      );

      expect(applied, isFalse);
      expect((await store.localVersion('task', 't1'))!.version, 3);
      expect((await harness.readTask('t1'))!.title, '本地新');
    });

    test('LWW 相等 version 比 updatedAt', () async {
      await store.applyRemote(
        _change(_task(title: '基准', updatedAt: _t2),
            entityType: 'task', entityId: 't1', version: 2, updatedAt: _t2),
      );

      // 同版本但更早：拒绝。
      final staleApplied = await store.applyRemote(
        _change(_task(title: '更早', updatedAt: _t),
            entityType: 'task', entityId: 't1', version: 2, updatedAt: _t),
      );
      expect(staleApplied, isFalse);
      expect((await harness.readTask('t1'))!.title, '基准');

      // 同版本但更晚：接受。
      final freshApplied = await store.applyRemote(
        _change(_task(title: '更晚', updatedAt: _t3),
            entityType: 'task', entityId: 't1', version: 2, updatedAt: _t3),
      );
      expect(freshApplied, isTrue);
      expect((await harness.readTask('t1'))!.title, '更晚');
    });

    test('LWW 亚秒：同秒内 updatedAt 微秒差仍能正确判胜负', () async {
      final base = DateTime.utc(2026, 2, 1, 12, 0, 0, 250, 500);
      final earlier = base.subtract(const Duration(microseconds: 400));
      final later = base.add(const Duration(microseconds: 400));

      await store.applyRemote(
        _change(_task(title: '基准', version: 5, updatedAt: base),
            entityType: 'task', entityId: 't1', version: 5, updatedAt: base),
      );

      // 同秒、同版本，但 updatedAt 早 400 微秒：拒绝。
      final staleApplied = await store.applyRemote(
        _change(_task(title: '更早', version: 5, updatedAt: earlier),
            entityType: 'task',
            entityId: 't1',
            version: 5,
            updatedAt: earlier),
      );
      expect(staleApplied, isFalse);
      expect((await harness.readTask('t1'))!.title, '基准');

      // 同秒、同版本，但 updatedAt 晚 400 微秒：接受。
      final freshApplied = await store.applyRemote(
        _change(_task(title: '更晚', version: 5, updatedAt: later),
            entityType: 'task', entityId: 't1', version: 5, updatedAt: later),
      );
      expect(freshApplied, isTrue);
      expect((await harness.readTask('t1'))!.title, '更晚');
    });

    test('墓碑：payload.deletedAt 非空 → 写入且后续读过滤', () async {
      final tombstone = _conv(version: 2, updatedAt: _t2, deletedAt: _t2);
      final applied = await store.applyRemote(
        _change(tombstone,
            entityType: 'conversation',
            entityId: 'c1',
            version: 2,
            updatedAt: _t2,
            kind: SyncOperationKind.delete),
      );

      expect(applied, isTrue);
      expect((await store.localVersion('conversation', 'c1'))!.version, 2);
      expect(await harness.readConversation('c1'), isNull);

      // 墓碑参与 LWW：更旧版本被拒。
      final olderApplied = await store.applyRemote(
        _change(_conv(version: 1, updatedAt: _t),
            entityType: 'conversation', entityId: 'c1', version: 1, updatedAt: _t),
      );
      expect(olderApplied, isFalse);
    });

    test('不产生入队：applyRemote 前后 getPending 不变', () async {
      await queue.enqueue(_op(id: 'op-seed'));
      final before = await queue.getPending();
      expect(before.length, 1);

      await store.applyRemote(
        _change(_task(), entityType: 'task', entityId: 't1', version: 1, updatedAt: _t),
      );
      await store.applyRemote(
        _change(_conv(), entityType: 'conversation', entityId: 'c1', version: 1, updatedAt: _t),
      );

      final after = await queue.getPending();
      expect(after.length, 1);
      expect(after.single.id, 'op-seed');
    });

    test('conversation 派生列保留：快照更新不改本地预览/时间', () async {
      await harness.seedConversation(
        _conv(
          title: '本地标题',
          lastMessagePreview: '本地预览',
          lastMessageAt: _t2,
        ),
      );

      final applied = await store.applyRemote(
        _change(_conv(title: '远端标题', version: 2),
            entityType: 'conversation', entityId: 'c1', version: 2, updatedAt: _t2),
      );

      expect(applied, isTrue);
      final loaded = (await harness.readConversation('c1'))!;
      expect(loaded.title, '远端标题');
      expect(loaded.lastMessagePreview, '本地预览');
      expect(loaded.lastMessageAt!.toUtc(), _t2);
    });

    test('未知类型：返回 false 且不崩', () async {
      final applied = await store.applyRemote(
        SyncChange(
          seq: 1,
          entityType: 'unknown_type',
          entityId: 'x',
          kind: SyncOperationKind.update,
          version: 1,
          deviceId: 'device-remote',
          updatedAt: _t,
          payload: const <String, Object?>{'id': 'x'},
        ),
      );
      expect(applied, isFalse);
      expect(await store.localVersion('unknown_type', 'x'), isNull);
    });
  });
}

void main() {
  _runContract(
    'MemorySyncEntityStore',
    create: () async {
      final queue = MemorySyncOperationRepository(
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final conversations = MemoryConversationRepository(
        syncOperationRepository: queue,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final tasks = MemoryTaskRepository(
        syncOperationRepository: queue,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final calendarEntries = MemoryCalendarEntryRepository(
        syncOperationRepository: queue,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final projects = MemoryProjectRepository(
        syncOperationRepository: queue,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final plans = MemoryAIPlanRepository(
        tasks,
        syncOperationRepository: queue,
        calendarEntryRepository: calendarEntries,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final store = MemorySyncEntityStore(
        conversations: conversations,
        tasks: tasks,
        plans: plans,
        calendarEntries: calendarEntries,
        projects: projects,
      );
      return _Harness(
        store: store,
        queue: queue,
        seedConversation: (conversation) async =>
            conversations.applyRemoteConversation(conversation),
        readConversation: conversations.getConversation,
        readTask: (id) async {
          final all = await tasks.getTasks(const TaskQuery());
          for (final task in all) {
            if (task.id == id) {
              return task;
            }
          }
          return null;
        },
        dispose: () async {
          conversations.dispose();
          tasks.dispose();
          calendarEntries.dispose();
          projects.dispose();
          plans.dispose();
          queue.dispose();
        },
      );
    },
  );

  _runContract(
    'SyncEntityStoreImpl（Drift 内存库）',
    create: () async {
      final database = AppDatabase(NativeDatabase.memory());
      const clock = SystemClock();
      final queue = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final store = SyncEntityStoreImpl(database);
      return _Harness(
        store: store,
        queue: queue,
        seedConversation: (conversation) async {
          await database.into(database.conversations).insert(
                ConversationsCompanion.insert(
                  id: conversation.id,
                  userId: conversation.userId,
                  title: conversation.title,
                  createdAt: conversation.createdAt,
                  updatedAt: conversation.updatedAt,
                  deviceId: conversation.deviceId,
                  isArchived: Value(conversation.isArchived),
                  lastMessagePreview: Value(conversation.lastMessagePreview),
                  lastMessageAt: Value(conversation.lastMessageAt),
                  version: Value(conversation.version),
                ),
              );
        },
        readConversation: (id) async {
          final row = await (database.select(database.conversations)
                ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
              .getSingleOrNull();
          if (row == null) {
            return null;
          }
          return Conversation(
            id: row.id,
            userId: row.userId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
            version: row.version,
            deviceId: row.deviceId,
            title: row.title,
            isArchived: row.isArchived,
            lastMessagePreview: row.lastMessagePreview,
            lastMessageAt: row.lastMessageAt,
          );
        },
        readTask: (id) async {
          final row = await (database.select(database.tasks)
                ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
              .getSingleOrNull();
          if (row == null) {
            return null;
          }
          return Task(
            id: row.id,
            userId: row.userId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
            version: row.version,
            deviceId: row.deviceId,
            title: row.title,
            status: TaskStatus.values.byName(row.status),
            priority: TaskPriority.values.byName(row.priority),
            sortOrder: row.sortOrder,
          );
        },
        dispose: () async => database.close(),
      );
    },
  );
}
