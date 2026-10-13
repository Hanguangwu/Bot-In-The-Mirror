import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/task_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/domain/entities/task.dart';
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

/// 被测实现与资源释放器的组合。
class _Harness {
  _Harness(this.repository, this._dispose);

  final TaskRepository repository;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 构造任务实体（id/userId/deviceId/时间由仓储在写入时维护）。
Task _task({
  required String id,
  String title = '任务',
  String? description,
  TaskStatus status = TaskStatus.inbox,
  TaskPriority priority = TaskPriority.medium,
  DateTime? dueAt,
  String? projectId,
}) {
  return Task(
    id: id,
    userId: '',
    createdAt: DateTime(2000),
    updatedAt: DateTime(2000),
    version: 1,
    deviceId: '',
    projectId: projectId,
    title: title,
    description: description,
    status: status,
    priority: priority,
    dueAt: dueAt,
  );
}

/// 对内存实现与 Drift 实现跑同一组契约断言，保证两种实现行为一致。
void _runContract(
  String name, {
  required Future<_Harness> Function(_MutableClock clock) create,
}) {
  group(name, () {
    late _MutableClock clock;
    late _Harness harness;
    late TaskRepository repository;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
    });

    tearDown(() => harness.dispose());

    test('save 新建补齐 id/userId/deviceId/version', () async {
      final stored = await repository.save(_task(id: '', title: '新任务'));

      expect(stored.id, isNotEmpty);
      expect(stored.userId, 'user-1');
      expect(stored.deviceId, 'device-1');
      expect(stored.version, 1);
      expect(stored.createdAt, clock.current);

      final loaded = await repository.getTasks(const TaskQuery());
      expect(loaded.single.id, stored.id);
      expect(loaded.single.title, '新任务');
    });

    test('save 更新已有任务：version 递增，createdAt 保留，updatedAt 刷新', () async {
      final created = await repository.save(_task(id: 't1', title: '原始'));
      clock.current = clock.current.add(const Duration(minutes: 5));

      final updated = await repository.save(created.copyWith(title: '修改后'));

      expect(updated.id, 't1');
      expect(updated.version, 2);
      expect(updated.createdAt, created.createdAt);
      expect(updated.updatedAt, clock.current);
      expect((await repository.getTasks(const TaskQuery())).single.title, '修改后');
    });

    test('save 往返保留描述、优先级与状态枚举（TEXT 列）', () async {
      await repository.save(
        _task(
          id: 't1',
          title: '带描述',
          description: '详细说明',
          status: TaskStatus.doing,
          priority: TaskPriority.high,
        ),
      );

      final loaded = (await repository.getTasks(const TaskQuery())).single;
      expect(loaded.description, '详细说明');
      expect(loaded.status, TaskStatus.doing);
      expect(loaded.priority, TaskPriority.high);
    });

    test('getTasks 只返回未软删任务；软删后不再出现', () async {
      await repository.save(_task(id: 't1'));
      await repository.save(_task(id: 't2'));
      expect((await repository.getTasks(const TaskQuery())).length, 2);

      await repository.applyChanges(<TaskChange>[const TaskDeleted('t1')]);

      final remaining = await repository.getTasks(const TaskQuery());
      expect(remaining.map((task) => task.id).toList(), <String>['t2']);
    });

    test('getTasks 单值 status 过滤（不下推集合）', () async {
      await repository.save(_task(id: 'a', status: TaskStatus.inbox));
      await repository.save(_task(id: 'b', status: TaskStatus.done));
      await repository.save(_task(id: 'c', status: TaskStatus.cancelled));

      final inbox =
          await repository.getTasks(const TaskQuery(status: TaskStatus.inbox));
      expect(inbox.map((task) => task.id).toList(), <String>['a']);
      final done =
          await repository.getTasks(const TaskQuery(status: TaskStatus.done));
      expect(done.map((task) => task.id).toList(), <String>['b']);
    });

    test('getTasks projectId 过滤', () async {
      await repository.save(_task(id: 'p1', projectId: 'proj'));
      await repository.save(_task(id: 'p2'));

      final filtered =
          await repository.getTasks(const TaskQuery(projectId: 'proj'));
      expect(filtered.map((task) => task.id).toList(), <String>['p1']);
    });

    test('getTasks due 区间过滤（含端点，无 dueAt 不计入）', () async {
      await repository.save(_task(id: 'd1', dueAt: DateTime(2024, 1, 1)));
      await repository.save(_task(id: 'd2', dueAt: DateTime(2024, 1, 2)));
      await repository.save(_task(id: 'd3', dueAt: DateTime(2024, 1, 3)));
      await repository.save(_task(id: 'd4'));

      final range = await repository.getTasks(
        TaskQuery(dueFrom: DateTime(2024, 1, 2), dueTo: DateTime(2024, 1, 3)),
      );
      expect(range.map((task) => task.id).toSet(), <String>{'d2', 'd3'});
    });

    test('getTasks 文本 LIKE 匹配标题与描述，ASCII 大小写不敏感', () async {
      await repository.save(
        _task(id: 'l1', title: '写周报', description: '总结进展'),
      );
      await repository.save(_task(id: 'l2', title: '标题Hello'));

      final byTitle =
          await repository.getTasks(const TaskQuery(text: '周报'));
      expect(byTitle.map((task) => task.id).toList(), <String>['l1']);
      final byDescription =
          await repository.getTasks(const TaskQuery(text: '进展'));
      expect(byDescription.map((task) => task.id).toList(), <String>['l1']);
      final byLowercase =
          await repository.getTasks(const TaskQuery(text: 'hello'));
      expect(byLowercase.map((task) => task.id).toList(), <String>['l2']);
      expect(
        await repository.getTasks(const TaskQuery(text: '不存在的词')),
        isEmpty,
      );
    });

    test('getTasks 按 createdAt 倒序', () async {
      await repository.save(_task(id: 's1'));
      clock.current = clock.current.add(const Duration(minutes: 1));
      await repository.save(_task(id: 's2'));
      clock.current = clock.current.add(const Duration(minutes: 1));
      await repository.save(_task(id: 's3'));

      final list = await repository.getTasks(const TaskQuery());
      expect(list.map((task) => task.id).toList(), <String>['s3', 's2', 's1']);
    });

    test('watchTasks 订阅时推送当前快照并随写入更新', () async {
      final future = expectLater(
        repository.watchTasks(const TaskQuery()),
        emitsThrough(
          predicate<List<Task>>(
            (tasks) => tasks.length == 1 && tasks.single.title == '监听',
          ),
        ),
      );

      await repository.save(_task(id: 'w1', title: '监听'));
      await future;
    });

    test('applyChanges 依次处理 insert/update/delete 三事件', () async {
      await repository.save(_task(id: 't1', title: '旧'));
      await repository.save(_task(id: 't3', title: '待删'));
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.applyChanges(<TaskChange>[
        TaskInserted(_task(id: 't2', title: '新')),
        TaskUpdated(_task(id: 't1', title: '更新')),
        const TaskDeleted('t3'),
      ]);

      final tasks = await repository.getTasks(const TaskQuery());
      expect(tasks.map((task) => task.id).toSet(), <String>{'t1', 't2'});
      final updated = tasks.firstWhere((task) => task.id == 't1');
      expect(updated.title, '更新');
      expect(updated.version, 2);
      expect(updated.updatedAt, clock.current);
      expect(tasks.firstWhere((task) => task.id == 't2').version, 1);
    });

    test('applyChanges 校验失败整体回滚：插入不落库', () async {
      await expectLater(
        repository.applyChanges(<TaskChange>[
          TaskInserted(_task(id: 'ghost')),
          const TaskDeleted('missing'),
        ]),
        throwsA(isA<ConflictException>()),
      );

      expect(await repository.getTasks(const TaskQuery()), isEmpty);
    });

    test('applyChanges 更新不存在的目标抛 ConflictException 且无副作用', () async {
      await expectLater(
        repository.applyChanges(<TaskChange>[
          TaskUpdated(_task(id: 'missing')),
        ]),
        throwsA(isA<ConflictException>()),
      );

      expect(await repository.getTasks(const TaskQuery()), isEmpty);
    });
  });
}

void main() {
  _runContract(
    'MemoryTaskRepository',
    create: (clock) async {
      final repository = MemoryTaskRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, () async => repository.dispose());
    },
  );

  _runContract(
    'TaskRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final repository = TaskRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, () async => database.close());
    },
  );
}
