import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/project_repository_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_project_repository.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/repositories/project_repository.dart';
import 'package:chatwithalice/domain/repositories/sync_operation_repository.dart';
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
  _Harness(this.repository, this.queue, this._dispose);

  final ProjectRepository repository;
  final SyncOperationRepository queue;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 构造项目实体（id/userId/deviceId/时间由仓储在写入时维护）。
Project _project({
  required String id,
  String name = '项目',
  String? goal,
  bool isArchived = false,
}) {
  return Project(
    id: id,
    userId: '',
    createdAt: DateTime(2000),
    updatedAt: DateTime(2000),
    version: 1,
    deviceId: '',
    name: name,
    goal: goal,
    isArchived: isArchived,
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
    late ProjectRepository repository;
    late SyncOperationRepository queue;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
      queue = harness.queue;
    });

    tearDown(() => harness.dispose());

    test('save 新建补齐 id/userId/deviceId/version/createdAt', () async {
      final stored = await repository.save(_project(id: '', name: '年度计划'));

      expect(stored.id, isNotEmpty);
      expect(stored.userId, 'user-1');
      expect(stored.deviceId, 'device-1');
      expect(stored.version, 1);
      expect(stored.createdAt, clock.current);

      final loaded = await repository.get(stored.id);
      expect(loaded!.name, '年度计划');
    });

    test('save 更新已有：version 递增，createdAt 保留，updatedAt 刷新', () async {
      final created = await repository.save(_project(id: 'p1', name: '原始'));
      clock.current = clock.current.add(const Duration(minutes: 5));

      final updated = await repository.save(
        created.copyWith(name: '修改后', isArchived: true),
      );

      expect(updated.id, 'p1');
      expect(updated.version, 2);
      expect(updated.createdAt, created.createdAt);
      expect(updated.updatedAt, clock.current);
      expect(updated.isArchived, isTrue);
      expect((await repository.get('p1'))!.name, '修改后');
    });

    test('save 往返保留 goal', () async {
      await repository.save(
        _project(id: 'p1', name: '带目标', goal: '每周复盘'),
      );

      expect((await repository.get('p1'))!.goal, '每周复盘');
    });

    test('getProjects 只返回未软删项目；软删后消失', () async {
      await repository.save(_project(id: 'p1'));
      await repository.save(_project(id: 'p2'));
      expect((await repository.getProjects()).length, 2);

      await repository.delete('p1');

      final remaining = await repository.getProjects();
      expect(remaining.map((project) => project.id).toList(), <String>['p2']);
      expect(await repository.get('p1'), isNull);
    });

    test('watchProjects 订阅时推送当前快照并随写入更新', () async {
      final future = expectLater(
        repository.watchProjects(),
        emitsThrough(
          predicate<List<Project>>(
            (list) => list.length == 1 && list.single.name == '监听',
          ),
        ),
      );

      await repository.save(_project(id: 'p1', name: '监听'));
      await future;
    });

    test('save 新建入队 project create（payload 为实体快照）', () async {
      await repository.save(_project(id: 'p1', name: '年度计划'));

      final ops = await queue.getPending();
      expect(ops, hasLength(1));
      expect(ops.single.entityType, 'project');
      expect(ops.single.entityId, 'p1');
      expect(ops.single.kind, SyncOperationKind.create);
      expect(ops.single.payload['name'], '年度计划');
    });

    test('save 更新入队 update（同一实体按序 create→update）', () async {
      final created = await repository.save(_project(id: 'p1', name: '原始'));
      clock.current = clock.current.add(const Duration(minutes: 5));
      await repository.save(created.copyWith(name: '修改后'));

      final ops = await queue.getPending();
      expect(
        ops.map((op) => op.kind).toList(),
        <SyncOperationKind>[SyncOperationKind.create, SyncOperationKind.update],
      );
    });

    test('delete 入队 delete 且快照含 deletedAt', () async {
      await repository.save(_project(id: 'p1'));
      await repository.delete('p1');

      final ops = await queue.getPending();
      // 不与 create 依赖排序：二者 createdAt 相同，id 兜底顺序随机。
      final deleted =
          ops.singleWhere((op) => op.kind == SyncOperationKind.delete);
      expect(deleted.entityType, 'project');
      expect(deleted.entityId, 'p1');
      expect(deleted.payload['deletedAt'], isNotNull);
    });
  });
}

void main() {
  _runContract(
    'MemoryProjectRepository',
    create: (clock) async {
      final queue = MemorySyncOperationRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = MemoryProjectRepository(
        syncOperationRepository: queue,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, queue, () async => repository.dispose());
    },
  );

  _runContract(
    'ProjectRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final queue = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = ProjectRepositoryImpl(
        database,
        clock,
        syncOperationRepository: queue,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, queue, () async => database.close());
    },
  );
}
