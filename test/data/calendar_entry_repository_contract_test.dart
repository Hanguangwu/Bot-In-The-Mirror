import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/calendar_entry_repository_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_calendar_entry_repository.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/domain/entities/calendar.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/repositories/calendar_entry_repository.dart';
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

  final CalendarEntryRepository repository;
  final SyncOperationRepository queue;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 构造日历条目（id/userId/deviceId/时间由仓储在写入时维护）。
CalendarEntry _entry({
  required String id,
  String title = '日程',
  DateTime? startAt,
  DateTime? endAt,
  bool allDay = false,
  List<String> taskIds = const <String>[],
  String? note,
}) {
  final start = startAt ?? DateTime(2024, 1, 1, 9);
  return CalendarEntry(
    id: id,
    userId: '',
    createdAt: DateTime(2000),
    updatedAt: DateTime(2000),
    version: 1,
    deviceId: '',
    title: title,
    startAt: start,
    endAt: endAt ?? start.add(const Duration(hours: 1)),
    allDay: allDay,
    taskIds: taskIds,
    note: note,
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
    late CalendarEntryRepository repository;
    late SyncOperationRepository queue;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
      queue = harness.queue;
    });

    tearDown(() => harness.dispose());

    test('save 新建补齐 id/userId/deviceId/version/createdAt', () async {
      final stored = await repository.save(_entry(id: '', title: '晨会'));

      expect(stored.id, isNotEmpty);
      expect(stored.userId, 'user-1');
      expect(stored.deviceId, 'device-1');
      expect(stored.version, 1);
      expect(stored.createdAt, clock.current);

      final loaded = await repository.get(stored.id);
      expect(loaded!.title, '晨会');
    });

    test('save 更新已有：version 递增，createdAt 保留，updatedAt 刷新', () async {
      final created = await repository.save(_entry(id: 'c1', title: '原始'));
      clock.current = clock.current.add(const Duration(minutes: 5));

      final updated =
          await repository.save(created.copyWith(title: '修改后'));

      expect(updated.id, 'c1');
      expect(updated.version, 2);
      expect(updated.createdAt, created.createdAt);
      expect(updated.updatedAt, clock.current);
      expect((await repository.get('c1'))!.title, '修改后');
    });

    test('save 往返保留 allDay/taskIds/note', () async {
      final start = DateTime(2024, 3, 1, 10);
      await repository.save(
        _entry(
          id: 'c1',
          title: '带备注',
          startAt: start,
          endAt: start.add(const Duration(hours: 2)),
          allDay: true,
          taskIds: const <String>['t1', 't2'],
          note: '提前准备',
        ),
      );

      final loaded = (await repository.get('c1'))!;
      expect(loaded.allDay, isTrue);
      expect(loaded.taskIds, <String>['t1', 't2']);
      expect(loaded.note, '提前准备');
    });

    test('getInRange 半开区间 [start,end) 按 startAt 命中', () async {
      await repository.save(_entry(id: 'd1', startAt: DateTime(2024, 1, 1)));
      await repository.save(_entry(id: 'd2', startAt: DateTime(2024, 1, 2)));
      await repository.save(_entry(id: 'd3', startAt: DateTime(2024, 1, 3)));

      final range = await repository.getInRange(
        DateTime(2024, 1, 2),
        DateTime(2024, 1, 3),
      );
      // d2 命中；d3 恰在 end（半开不含）。
      expect(range.map((entry) => entry.id).toList(), <String>['d2']);
    });

    test('getInRange 稳定排序 (startAt, id)', () async {
      final same = DateTime(2024, 1, 5, 12);
      await repository.save(_entry(id: 'b', startAt: same));
      await repository.save(_entry(id: 'a', startAt: same));
      await repository.save(_entry(id: 'c', startAt: DateTime(2024, 1, 4)));

      final range = await repository.getInRange(
        DateTime(2024, 1, 1),
        DateTime(2024, 1, 10),
      );
      expect(
        range.map((entry) => entry.id).toList(),
        <String>['c', 'a', 'b'],
      );
    });

    test('get 不存在或已删返回 null；软删后区间不含', () async {
      await repository.save(_entry(id: 'c1', startAt: DateTime(2024, 1, 2)));
      expect(await repository.get('missing'), isNull);

      await repository.delete('c1');

      expect(await repository.get('c1'), isNull);
      expect(
        await repository.getInRange(
          DateTime(2024, 1, 1),
          DateTime(2024, 1, 10),
        ),
        isEmpty,
      );
    });

    test('watchInRange 订阅时推送当前快照并随写入更新', () async {
      final future = expectLater(
        repository.watchInRange(DateTime(2024, 1, 1), DateTime(2024, 1, 10)),
        emitsThrough(
          predicate<List<CalendarEntry>>(
            (list) => list.length == 1 && list.single.title == '监听',
          ),
        ),
      );

      await repository.save(
        _entry(id: 'w1', title: '监听', startAt: DateTime(2024, 1, 3)),
      );
      await future;
    });

    test('save 新建入队 calendar_entry create（payload 为实体快照）', () async {
      await repository.save(_entry(id: 'c1', title: '晨会'));

      final ops = await queue.getPending();
      expect(ops, hasLength(1));
      expect(ops.single.entityType, 'calendar_entry');
      expect(ops.single.entityId, 'c1');
      expect(ops.single.kind, SyncOperationKind.create);
      expect(ops.single.payload['title'], '晨会');
    });

    test('save 更新入队 update（同一实体按序 create→update）', () async {
      final created = await repository.save(_entry(id: 'c1', title: '原始'));
      clock.current = clock.current.add(const Duration(minutes: 5));
      await repository.save(created.copyWith(title: '修改后'));

      final ops = await queue.getPending();
      expect(
        ops.map((op) => op.kind).toList(),
        <SyncOperationKind>[SyncOperationKind.create, SyncOperationKind.update],
      );
    });

    test('delete 入队 delete 且快照含 deletedAt', () async {
      await repository.save(_entry(id: 'c1'));
      await repository.delete('c1');

      final ops = await queue.getPending();
      // 不与 create 依赖排序：二者 createdAt 相同，id 兜底顺序随机。
      final deleted =
          ops.singleWhere((op) => op.kind == SyncOperationKind.delete);
      expect(deleted.entityType, 'calendar_entry');
      expect(deleted.entityId, 'c1');
      expect(deleted.payload['deletedAt'], isNotNull);
    });
  });
}

void main() {
  _runContract(
    'MemoryCalendarEntryRepository',
    create: (clock) async {
      final queue = MemorySyncOperationRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = MemoryCalendarEntryRepository(
        syncOperationRepository: queue,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, queue, () async => repository.dispose());
    },
  );

  _runContract(
    'CalendarEntryRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final queue = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = CalendarEntryRepositoryImpl(
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
