import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
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
  _Harness(this.repository, this._dispose);

  final SyncOperationRepository repository;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 构造同步操作（空 id/userId/deviceId 由仓储写入时补齐）。
SyncOperation _op({
  String id = '',
  String entityType = 'task',
  String entityId = 'e1',
  SyncOperationKind kind = SyncOperationKind.create,
  SyncOperationStatus status = SyncOperationStatus.pending,
  DateTime? createdAt,
  Map<String, Object?> payload = const <String, Object?>{'title': '写周报'},
  int retryCount = 0,
  String? lastError,
}) {
  final at = createdAt ?? DateTime(2024, 1, 1);
  return SyncOperation(
    id: id,
    userId: '',
    createdAt: at,
    updatedAt: at,
    version: 1,
    deviceId: '',
    entityType: entityType,
    entityId: entityId,
    kind: kind,
    payload: payload,
    status: status,
    retryCount: retryCount,
    lastError: lastError,
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
    late SyncOperationRepository repository;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
    });

    tearDown(() => harness.dispose());

    test('enqueue 补齐 id/身份，getPending 返回且 payload 往返', () async {
      await repository.enqueue(
        _op(
          id: '',
          entityType: 'message',
          entityId: 'm9',
          kind: SyncOperationKind.delete,
          payload: <String, Object?>{'title': '写周报', 'n': 3, 'flag': true},
        ),
      );

      final pending = await repository.getPending();
      expect(pending.length, 1);
      final op = pending.single;
      expect(op.id, isNotEmpty);
      expect(op.userId, 'user-1');
      expect(op.deviceId, 'device-1');
      expect(op.entityType, 'message');
      expect(op.entityId, 'm9');
      expect(op.kind, SyncOperationKind.delete);
      expect(op.status, SyncOperationStatus.pending);
      expect(op.payload['title'], '写周报');
      expect(op.payload['n'], 3);
      expect(op.payload['flag'], true);
    });

    test('getPending 仅含 pending，按 createdAt 正序、同刻按 id 兜底', () async {
      final same = DateTime(2024, 1, 1, 9, 0, 0);
      await repository.enqueue(_op(id: 'b', entityId: 'b', createdAt: same));
      await repository.enqueue(_op(id: 'a', entityId: 'a', createdAt: same));
      await repository.enqueue(
        _op(id: 'c', entityId: 'c', createdAt: DateTime(2024, 1, 1, 8, 30)),
      );
      await repository.enqueue(
        _op(
          id: 'synced',
          entityId: 'synced',
          createdAt: DateTime(2024, 1, 1, 8, 0),
          status: SyncOperationStatus.synced,
        ),
      );

      final pending = await repository.getPending();
      expect(
        pending.map((op) => op.id).toList(),
        <String>['c', 'a', 'b'],
      );
    });

    test('enqueueAll 批量追加', () async {
      await repository.enqueueAll(<SyncOperation>[
        _op(id: 'a'),
        _op(id: 'b'),
        _op(id: 'c'),
      ]);

      expect((await repository.getPending()).length, 3);
    });

    test('mark 更新状态/重试/错误并移出 pending', () async {
      await repository.enqueue(_op(id: 's1'));
      final op = (await repository.getPending()).single;

      await repository.mark(
        op.copyWith(
          status: SyncOperationStatus.failed,
          retryCount: 2,
          lastError: '网络超时',
        ),
      );

      expect(await repository.getPending(), isEmpty);
    });

    test('watchPending 订阅时推送当前快照并随写入更新', () async {
      final future = expectLater(
        repository.watchPending(),
        emitsThrough(
          predicate<List<SyncOperation>>(
            (list) => list.length == 1 && list.single.entityId == 'e9',
          ),
        ),
      );

      await repository.enqueue(_op(id: 's1', entityId: 'e9'));
      await future;
    });
  });
}

void main() {
  _runContract(
    'MemorySyncOperationRepository',
    create: (clock) async {
      final repository = MemorySyncOperationRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, () async => repository.dispose());
    },
  );

  _runContract(
    'SyncOperationRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final repository = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, () async => database.close());
    },
  );
}
