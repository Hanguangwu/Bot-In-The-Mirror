import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/ai_plan_repository_impl.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/calendar_entry_repository_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/local/task_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_ai_plan_repository.dart';
import 'package:chatwithalice/data/memory/memory_calendar_entry_repository.dart';
import 'package:chatwithalice/data/memory/memory_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/repositories/ai_plan_repository.dart';
import 'package:chatwithalice/domain/repositories/calendar_entry_repository.dart';
import 'package:chatwithalice/domain/repositories/sync_operation_repository.dart';
import 'package:chatwithalice/domain/repositories/task_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控时钟，便于构造确定性的时间顺序。
class _MutableClock implements Clock {
  _MutableClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;
}

/// 被测实现、共享任务/日历仓储、队列、计划读取器与资源释放器的组合。
class _Harness {
  _Harness({
    required this.repository,
    required this.taskRepository,
    required this.calendarRepository,
    required this.syncOperationRepository,
    required this.readPlan,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  final AIPlanRepository repository;
  final TaskRepository taskRepository;
  final CalendarEntryRepository calendarRepository;
  final SyncOperationRepository syncOperationRepository;
  final Future<AIPlan?> Function(String id) readPlan;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 构造计划实体（id/userId/deviceId/时间由仓储在写入时维护）。
AIPlan _plan({
  required String id,
  AIPlanStatus status = AIPlanStatus.awaitingConfirmation,
  List<AIPlanChange> changes = const <AIPlanChange>[],
}) {
  return AIPlan(
    id: id,
    userId: '',
    createdAt: DateTime(2000),
    updatedAt: DateTime(2000),
    version: 1,
    deviceId: '',
    conversationId: 'c1',
    sourceMessageId: 'm1',
    status: status,
    aiModel: 'gpt-3.5-turbo',
    promptVersion: 'm1-plan-v1',
    changes: changes,
  );
}

/// 构造 createTask 变更（payload 为纯 JSON 类型）。
AIPlanChange _createTaskChange(
  String title, {
  String? description,
  String priority = 'medium',
  String? dueAt,
}) {
  return AIPlanChange(
    type: AIPlanChangeType.createTask,
    payload: <String, Object?>{
      'title': title,
      if (description != null) 'description': description,
      'priority': priority,
      if (dueAt != null) 'dueAt': dueAt,
    },
  );
}

/// 构造 scheduleTask 变更（时间用本地朴素 ISO，避免测试受宿主时区影响）。
AIPlanChange _scheduleChange(
  String title, {
  required String startAt,
  required String endAt,
  String? note,
}) {
  return AIPlanChange(
    type: AIPlanChangeType.scheduleTask,
    payload: <String, Object?>{
      'title': title,
      'startAt': startAt,
      'endAt': endAt,
      if (note != null) 'note': note,
    },
  );
}

/// 对内存实现与 Drift 实现跑同一组契约断言。
void _runContract(
  String name, {
  required Future<_Harness> Function(_MutableClock clock) create,
}) {
  group(name, () {
    late _MutableClock clock;
    late _Harness harness;
    late AIPlanRepository repository;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
    });

    tearDown(() => harness.dispose());

    test('save 新建补齐同步字段，getPending 返回 awaitingConfirmation', () async {
      final plan = await repository.save(
        _plan(id: '', changes: <AIPlanChange>[_createTaskChange('写周报')]),
      );

      expect(plan.id, isNotEmpty);
      expect(plan.userId, 'user-1');
      expect(plan.deviceId, 'device-1');
      expect(plan.version, 1);
      expect(plan.status, AIPlanStatus.awaitingConfirmation);

      final pending = await repository.getPending();
      expect(pending.single.id, plan.id);
      expect(pending.single.changes.single.payload['title'], '写周报');
    });

    test('save 更新已有计划：version 递增，createdAt 保留', () async {
      final created = await repository.save(_plan(id: 'p1'));
      clock.current = clock.current.add(const Duration(minutes: 1));

      final updated = await repository.save(created.copyWith(aiModel: 'gpt-4o'));

      expect(updated.version, 2);
      expect(updated.createdAt, created.createdAt);
      expect(updated.updatedAt, clock.current);
      expect((await repository.getPending()).single.aiModel, 'gpt-4o');
    });

    test('watchPending 订阅时推送当前待确认快照', () async {
      final plan = await repository.save(_plan(id: 'p1'));

      final future = expectLater(
        repository.watchPending(),
        emitsThrough(
          predicate<List<AIPlan>>(
            (list) => list.length == 1 && list.single.id == plan.id,
          ),
        ),
      );
      await future;
    });

    test('getPending 只含 awaitingConfirmation 且按 createdAt 正序', () async {
      final first = await repository.save(_plan(id: 'p1'));
      clock.current = clock.current.add(const Duration(minutes: 1));
      final second = await repository.save(_plan(id: 'p2'));
      clock.current = clock.current.add(const Duration(minutes: 1));
      final rejected = await repository.save(_plan(id: 'p3'));
      await repository.reject(rejected.id);

      final pending = await repository.getPending();
      expect(
        pending.map((plan) => plan.id).toList(),
        <String>[first.id, second.id],
      );
    });

    test('confirm 物化 createTask 任务并置 applied（带时间戳）', () async {
      final plan = await repository.save(
        _plan(
          id: '',
          changes: <AIPlanChange>[
            _createTaskChange(
              '写周报',
              description: '总结进展',
              priority: 'high',
              dueAt: '2026-01-02T09:00:00+08:00',
            ),
            _createTaskChange('开会'),
          ],
        ),
      );
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.confirm(plan.id);

      final tasks = await harness.taskRepository.getTasks(const TaskQuery());
      expect(tasks.length, 2);
      expect(
        tasks.map((task) => task.title).toSet(),
        <String>{'写周报', '开会'},
      );
      final report = tasks.firstWhere((task) => task.title == '写周报');
      expect(report.status, TaskStatus.inbox);
      expect(report.priority, TaskPriority.high);
      expect(report.description, '总结进展');
      expect(report.sourceMessageId, 'm1');
      expect(report.userId, 'user-1');
      expect(report.deviceId, 'device-1');
      expect(report.dueAt, isNotNull);

      final stored = await harness.readPlan(plan.id);
      expect(stored!.status, AIPlanStatus.applied);
      expect(stored.confirmedAt, clock.current);
      expect(stored.appliedAt, clock.current);
      expect(stored.version, plan.version + 1);
      expect(await repository.getPending(), isEmpty);
    });

    test('confirm 遇非 createTask 变更整体回滚：计划与任务均不变', () async {
      final plan = await repository.save(
        _plan(
          id: '',
          changes: <AIPlanChange>[
            _createTaskChange('应回滚'),
            const AIPlanChange(type: AIPlanChangeType.updateTask, taskId: 'x'),
          ],
        ),
      );

      await expectLater(
        repository.confirm(plan.id),
        throwsA(isA<ConflictException>()),
      );

      expect(await harness.taskRepository.getTasks(const TaskQuery()), isEmpty);
      final stored = await harness.readPlan(plan.id);
      expect(stored!.status, AIPlanStatus.awaitingConfirmation);
      expect(stored.confirmedAt, isNull);
      expect((await repository.getPending()).length, 1);
    });

    test('confirm 非 awaitingConfirmation（已 applied）抛 ConflictException', () async {
      final plan = await repository.save(
        _plan(id: '', changes: <AIPlanChange>[_createTaskChange('x')]),
      );
      await repository.confirm(plan.id);

      await expectLater(
        repository.confirm(plan.id),
        throwsA(isA<ConflictException>()),
      );
      // 未重复写入任务。
      expect(
        (await harness.taskRepository.getTasks(const TaskQuery())).length,
        1,
      );
    });

    test('confirm 不存在的计划抛 ConflictException', () async {
      await expectLater(
        repository.confirm('missing'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('confirm 后 watchPending 不再包含该计划', () async {
      final plan = await repository.save(
        _plan(id: '', changes: <AIPlanChange>[_createTaskChange('x')]),
      );

      final future = expectLater(
        repository.watchPending(),
        emitsThrough(
          predicate<List<AIPlan>>((list) => list.isEmpty),
        ),
      );
      await repository.confirm(plan.id);
      await future;
    });

    test('reject 置 rejected + rejectedAt 且不写入任务', () async {
      final plan = await repository.save(
        _plan(id: '', changes: <AIPlanChange>[_createTaskChange('x')]),
      );
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.reject(plan.id);

      final stored = await harness.readPlan(plan.id);
      expect(stored!.status, AIPlanStatus.rejected);
      expect(stored.rejectedAt, clock.current);
      expect(stored.version, plan.version + 1);
      expect(await harness.taskRepository.getTasks(const TaskQuery()), isEmpty);
      expect(await repository.getPending(), isEmpty);
    });

    test('reject 非 awaitingConfirmation 抛 ConflictException', () async {
      final plan = await repository.save(_plan(id: ''));
      await repository.reject(plan.id);

      await expectLater(
        repository.reject(plan.id),
        throwsA(isA<ConflictException>()),
      );
    });

    test('changes 经 JSON 列往返：dueAt 与 priority 保持', () async {
      final plan = await repository.save(
        _plan(
          id: 'p1',
          changes: <AIPlanChange>[
            _createTaskChange(
              '带时间',
              priority: 'urgent',
              dueAt: '2026-03-05T10:30:00+08:00',
            ),
          ],
        ),
      );

      final stored = await harness.readPlan(plan.id);
      final change = stored!.changes.single;
      expect(change.type, AIPlanChangeType.createTask);
      expect(change.payload['title'], '带时间');
      expect(change.payload['priority'], 'urgent');
      expect(change.payload['dueAt'], '2026-03-05T10:30:00+08:00');
    });

    test('save 入队 ai_plan create；reject 入队 ai_plan update', () async {
      final plan = await repository.save(_plan(id: 'p1'));

      var ops = await harness.syncOperationRepository.getPending();
      expect(ops.length, 1);
      expect(ops.single.entityType, 'ai_plan');
      expect(ops.single.entityId, plan.id);
      expect(ops.single.kind, SyncOperationKind.create);
      expect(ops.single.payload['id'], plan.id);
      expect(
        ops.single.payload['status'],
        AIPlanStatus.awaitingConfirmation.name,
      );

      await repository.reject(plan.id);

      ops = await harness.syncOperationRepository.getPending();
      expect(ops.length, 2);
      final update =
          ops.where((op) => op.kind == SyncOperationKind.update).single;
      expect(update.entityType, 'ai_plan');
      expect(update.entityId, plan.id);
      expect(update.payload['status'], AIPlanStatus.rejected.name);
    });

    test('confirm 物化 scheduleTask：写日历条目并入队三类操作', () async {
      final plan = await repository.save(
        _plan(
          id: '',
          changes: <AIPlanChange>[
            _createTaskChange('写周报'),
            _scheduleChange(
              '评审会',
              startAt: '2026-05-01T09:00:00',
              endAt: '2026-05-01T10:00:00',
              note: '会议室A',
            ),
          ],
        ),
      );
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.confirm(plan.id);

      final entries = await harness.calendarRepository.getInRange(
        DateTime(2026, 5, 1),
        DateTime(2026, 5, 2),
      );
      expect(entries.length, 1);
      final entry = entries.single;
      expect(entry.title, '评审会');
      expect(entry.allDay, isFalse);
      expect(entry.taskIds, isEmpty);
      expect(entry.note, '会议室A');
      expect(entry.userId, 'user-1');
      expect(entry.deviceId, 'device-1');
      expect(entry.startAt, DateTime(2026, 5, 1, 9));
      expect(entry.endAt, DateTime(2026, 5, 1, 10));

      // 逐类计数断言「恰好一条」：若 confirm 与日历仓储重复入队，calendar_entry:create 会变 2。
      // 含 save(plan) 产生的 ai_plan:create。
      final ops = await harness.syncOperationRepository.getPending();
      final counts = <String, int>{};
      for (final op in ops) {
        final key = '${op.entityType}:${op.kind.name}';
        counts[key] = (counts[key] ?? 0) + 1;
      }
      expect(counts, <String, int>{
        'ai_plan:create': 1,
        'task:create': 1,
        'calendar_entry:create': 1,
        'ai_plan:update': 1,
      });
      expect(await repository.getPending(), isEmpty);
    });

    test('confirm 中途失败无孤儿：任务/日历/队列均无残留，计划保持待确认', () async {
      final plan = await repository.save(
        _plan(
          id: '',
          changes: <AIPlanChange>[
            _createTaskChange('应回滚'),
            _scheduleChange(
              '应回滚日程',
              startAt: '2026-05-01T09:00:00',
              endAt: '2026-05-01T10:00:00',
            ),
            const AIPlanChange(type: AIPlanChangeType.updateTask, taskId: 'x'),
          ],
        ),
      );
      final queueBefore = await harness.syncOperationRepository.getPending();

      await expectLater(
        repository.confirm(plan.id),
        throwsA(isA<ConflictException>()),
      );

      expect(await harness.taskRepository.getTasks(const TaskQuery()), isEmpty);
      expect(
        await harness.calendarRepository.getInRange(
          DateTime(2026, 4, 30),
          DateTime(2026, 5, 3),
        ),
        isEmpty,
      );
      final stored = await harness.readPlan(plan.id);
      expect(stored!.status, AIPlanStatus.awaitingConfirmation);
      expect(stored.appliedAt, isNull);
      expect(
        (await harness.syncOperationRepository.getPending()).length,
        queueBefore.length,
      );
    });
  });
}

void main() {
  _runContract(
    'MemoryAIPlanRepository',
    create: (clock) async {
      final store = MemoryStore();
      final syncOps = MemorySyncOperationRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
        store: store,
      );
      final tasks = MemoryTaskRepository(
        syncOperationRepository: syncOps,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
        store: store,
      );
      final calendar = MemoryCalendarEntryRepository(
        syncOperationRepository: syncOps,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
        store: store,
      );
      final repository = MemoryAIPlanRepository(
        tasks,
        syncOperationRepository: syncOps,
        calendarEntryRepository: calendar,
        memoryStore: store,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(
        repository: repository,
        taskRepository: tasks,
        calendarRepository: calendar,
        syncOperationRepository: syncOps,
        readPlan: repository.planById,
        dispose: () async {
          repository.dispose();
          tasks.dispose();
          calendar.dispose();
          syncOps.dispose();
        },
      );
    },
  );

  _runContract(
    'AIPlanRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final syncOps = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final tasks = TaskRepositoryImpl(
        database,
        clock,
        syncOperationRepository: syncOps,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final calendar = CalendarEntryRepositoryImpl(
        database,
        clock,
        syncOperationRepository: syncOps,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = AIPlanRepositoryImpl(
        database,
        tasks,
        clock,
        syncOperationRepository: syncOps,
        calendarEntryRepository: calendar,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(
        repository: repository,
        taskRepository: tasks,
        calendarRepository: calendar,
        syncOperationRepository: syncOps,
        readPlan: repository.planById,
        dispose: () => database.close(),
      );
    },
  );
}
