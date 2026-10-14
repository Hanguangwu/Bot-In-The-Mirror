import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../../domain/repositories/task_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'memory_store.dart';

/// 内存任务仓储：行为与 Drift 实现一致，供测试与预览使用。
///
/// 写路径经 [MemoryStore.runAtomic] 包裹，事务中途异常时任务/队列一并还原
/// （§7.2）。装配时若提供 [store] 则注册自身参与全或无回滚。
class MemoryTaskRepository implements TaskRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  MemoryTaskRepository({
    required SyncOperationRepository syncOperationRepository,
    String? userId,
    String? deviceId,
    Clock? clock,
    MemoryStore? store,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock(),
        _syncOperationRepository = syncOperationRepository,
        _memoryStore = store {
    store?.register(this);
  }

  final String _userId;
  final String _deviceId;
  final Clock _clock;
  final SyncOperationRepository _syncOperationRepository;
  final MemoryStore? _memoryStore;
  final List<Task> _tasks = <Task>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<List<Task>> watchTasks(TaskQuery query) {
    late StreamController<List<Task>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<Task>>(
      onListen: () {
        controller.add(_query(query));
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_query(query));
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
  Future<List<Task>> getTasks(TaskQuery query) async => _query(query);

  @override
  Future<Task> save(Task task) {
    return _atomic(() async {
      final now = _clock.now();
      final index = _indexOf(task.id);
      if (index < 0) {
        final stored = task.copyWith(
          id: task.id.isEmpty ? generateId() : task.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        _tasks.add(stored);
        await _syncOperationRepository.enqueue(
          buildSyncOperation(
            entity: stored,
            entityType: 'task',
            kind: SyncOperationKind.create,
            userId: _userId,
            deviceId: _deviceId,
            now: now,
          ),
        );
        _notify();
        return stored;
      }
      final existing = _tasks[index];
      final updated = task.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      _tasks[index] = updated;
      await _syncOperationRepository.enqueue(
        buildSyncOperation(
          entity: updated,
          entityType: 'task',
          kind: SyncOperationKind.update,
          userId: _userId,
          deviceId: _deviceId,
          now: now,
        ),
      );
      _notify();
      return updated;
    });
  }

  @override
  Future<void> applyChanges(List<TaskChange> changes) {
    return _atomic(() async {
      // 先全量校验（含目标存在性），再一次性提交，保证全或无（S2）。
      for (final change in changes) {
        switch (change) {
          case TaskInserted():
            break;
          case TaskUpdated(:final task):
            if (_indexOf(task.id) < 0) {
              throw const ConflictException('任务不存在，无法更新');
            }
          case TaskDeleted(:final id):
            if (_indexOf(id) < 0) {
              throw const ConflictException('任务不存在，无法删除');
            }
        }
      }

      final now = _clock.now();
      for (final change in changes) {
        switch (change) {
          case TaskInserted(:final task):
            final stored = task.copyWith(
              id: task.id.isEmpty ? generateId() : task.id,
              userId: _userId,
              deviceId: _deviceId,
            );
            _tasks.add(stored);
            await _syncOperationRepository.enqueue(
              buildSyncOperation(
                entity: stored,
                entityType: 'task',
                kind: SyncOperationKind.create,
                userId: _userId,
                deviceId: _deviceId,
                now: now,
              ),
            );
          case TaskUpdated(:final task):
            final index = _indexOf(task.id);
            final existing = _tasks[index];
            final updated = task.copyWith(
              id: existing.id,
              userId: _userId,
              deviceId: _deviceId,
              createdAt: existing.createdAt,
              updatedAt: now,
              version: existing.version + 1,
            );
            _tasks[index] = updated;
            await _syncOperationRepository.enqueue(
              buildSyncOperation(
                entity: updated,
                entityType: 'task',
                kind: SyncOperationKind.update,
                userId: _userId,
                deviceId: _deviceId,
                now: now,
              ),
            );
          case TaskDeleted(:final id):
            final index = _indexOf(id);
            final existing = _tasks[index];
            final tombstone = existing.copyWith(
              deletedAt: now,
              updatedAt: now,
              version: existing.version + 1,
            );
            _tasks[index] = tombstone;
            await _syncOperationRepository.enqueue(
              buildSyncOperation(
                entity: tombstone,
                entityType: 'task',
                kind: SyncOperationKind.delete,
                userId: _userId,
                deviceId: _deviceId,
                now: now,
              ),
            );
        }
      }
      _notify();
    });
  }

  /// 数据层内部「原始写入」接缝（Lane-B §6.3）：以远端快照覆盖本地任务，
  /// **不入同步队列**；写入后广播变更流（UI 刷新）。按 id 覆盖或新增。
  void applyRemoteSnapshot(Task task) {
    final index = _indexOf(task.id);
    if (index < 0) {
      _tasks.add(task);
    } else {
      _tasks[index] = task;
    }
    _notify();
  }

  /// 读取任务当前版本/更新时间；不存在返回 null（供 LWW）。
  ({int version, DateTime updatedAt})? localVersionOf(String id) {
    final index = _indexOf(id);
    if (index < 0) {
      return null;
    }
    final task = _tasks[index];
    return (version: task.version, updatedAt: task.updatedAt);
  }

  @override
  Object? snapshot() => List<Task>.of(_tasks);

  @override
  void restore(Object? snapshot) {
    _tasks
      ..clear()
      ..addAll(snapshot! as List<Task>);
    _notify();
  }

  /// 在 [MemoryStore] 全或无接缝内执行 [action]（无 store 时直接执行）。
  Future<T> _atomic<T>(Future<T> Function() action) {
    final store = _memoryStore;
    return store == null ? action() : store.runAtomic(action);
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _changes.close();
  }

  int _indexOf(String id) {
    if (id.isEmpty) {
      return -1;
    }
    return _tasks.indexWhere((task) => task.id == id);
  }

  List<Task> _query(TaskQuery query) {
    final result = _tasks.where((task) => _matches(task, query)).toList();
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List<Task>.unmodifiable(result);
  }

  bool _matches(Task task, TaskQuery query) {
    if (task.deletedAt != null) {
      return false;
    }
    if (query.status != null && task.status != query.status) {
      return false;
    }
    if (query.projectId != null && task.projectId != query.projectId) {
      return false;
    }
    final dueFrom = query.dueFrom;
    if (dueFrom != null) {
      final dueAt = task.dueAt;
      if (dueAt == null || dueAt.isBefore(dueFrom)) {
        return false;
      }
    }
    final dueTo = query.dueTo;
    if (dueTo != null) {
      final dueAt = task.dueAt;
      if (dueAt == null || dueAt.isAfter(dueTo)) {
        return false;
      }
    }
    final text = query.text;
    if (text != null && text.isNotEmpty) {
      // 与 SQLite LIKE 一致：ASCII 大小写不敏感。
      final needle = text.toLowerCase();
      final inTitle = task.title.toLowerCase().contains(needle);
      final inDescription =
          task.description?.toLowerCase().contains(needle) ?? false;
      if (!inTitle && !inDescription) {
        return false;
      }
    }
    return true;
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
