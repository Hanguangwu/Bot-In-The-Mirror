import 'dart:async';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import 'memory_store.dart';

/// 内存同步队列仓储：行为与 Drift 实现等价。
///
/// 队列自身写入永不入队（无回环）。装配时若提供 [MemoryStore] 则注册自身，
/// 使调用方可用 `runAtomic` 包裹实体写入与入队，实现全或无（§7.2）。
///
/// 入队项由调用方构造完整字段（§7.3）；本实现仅在 `id`/`userId`/`deviceId`
/// 为空时补齐，故 [clock] 参数当前保留以对齐仓储构造约定、暂不使用。
class MemorySyncOperationRepository
    implements SyncOperationRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[clock] 仅用于对齐构造约定。
  MemorySyncOperationRepository({
    Clock? clock,
    String? userId,
    String? deviceId,
    MemoryStore? store,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId() {
    store?.register(this);
  }

  final String _userId;
  final String _deviceId;
  final List<SyncOperation> _operations = <SyncOperation>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Future<List<SyncOperation>> getPending() async => _pending();

  @override
  Stream<List<SyncOperation>> watchPending() {
    late StreamController<List<SyncOperation>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<SyncOperation>>(
      onListen: () {
        controller.add(_pending());
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_pending());
          }
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> enqueue(SyncOperation operation) async {
    // 未另开事务：原子性由调用方的 MemoryStore.runAtomic 保证（§5.1）。
    _operations.add(_normalize(operation));
    _notify();
  }

  @override
  Future<void> enqueueAll(List<SyncOperation> operations) async {
    if (operations.isEmpty) {
      return;
    }
    for (final operation in operations) {
      _operations.add(_normalize(operation));
    }
    _notify();
  }

  @override
  Future<void> mark(SyncOperation operation) async {
    final index = _indexOf(operation.id);
    if (index < 0) {
      return;
    }
    _operations[index] = operation;
    _notify();
  }

  @override
  Future<void> deleteSynced() async {
    _deleteWhere((operation) => operation.status == SyncOperationStatus.synced);
  }

  @override
  Future<void> deleteConflicted() async {
    _deleteWhere(
      (operation) => operation.status == SyncOperationStatus.conflicted,
    );
  }

  @override
  Future<void> requeueFailed() async {
    var changed = false;
    for (var i = 0; i < _operations.length; i++) {
      if (_operations[i].status == SyncOperationStatus.failed) {
        _operations[i] = _operations[i].copyWith(
          status: SyncOperationStatus.pending,
          clearLastError: true,
        );
        changed = true;
      }
    }
    if (changed) {
      _notify();
    }
  }

  /// 删除满足 [test] 的操作；有删除才广播。
  void _deleteWhere(bool Function(SyncOperation operation) test) {
    final before = _operations.length;
    _operations.removeWhere(test);
    if (_operations.length != before) {
      _notify();
    }
  }

  @override
  Object? snapshot() => List<SyncOperation>.of(_operations);

  @override
  void restore(Object? snapshot) {
    _operations
      ..clear()
      ..addAll(snapshot! as List<SyncOperation>);
    _notify();
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _changes.close();
  }

  /// 补齐空 id（队列行必须有主键）与空身份；其余字段由调用方负责。
  SyncOperation _normalize(SyncOperation operation) {
    var result = operation;
    if (result.id.isEmpty) {
      result = result.copyWith(id: generateId());
    }
    if (result.userId.isEmpty) {
      result = result.copyWith(userId: _userId);
    }
    if (result.deviceId.isEmpty) {
      result = result.copyWith(deviceId: _deviceId);
    }
    return result;
  }

  List<SyncOperation> _pending() {
    final result = _operations
        .where((operation) => operation.status == SyncOperationStatus.pending)
        .toList();
    result.sort((a, b) {
      final compared = a.createdAt.compareTo(b.createdAt);
      return compared != 0 ? compared : a.id.compareTo(b.id);
    });
    return List<SyncOperation>.unmodifiable(result);
  }

  int _indexOf(String id) {
    if (id.isEmpty) {
      return -1;
    }
    return _operations.indexWhere((operation) => operation.id == id);
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
