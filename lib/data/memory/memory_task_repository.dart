import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/task_repository.dart';

/// 内存任务仓储：行为与 Drift 实现一致，供测试与预览使用。
class MemoryTaskRepository implements TaskRepository {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  MemoryTaskRepository({
    String? userId,
    String? deviceId,
    Clock? clock,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock();

  final String _userId;
  final String _deviceId;
  final Clock _clock;
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
  Future<Task> save(Task task) async {
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
    _notify();
    return updated;
  }

  @override
  Future<void> applyChanges(List<TaskChange> changes) async {
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
        case TaskUpdated(:final task):
          final index = _indexOf(task.id);
          final existing = _tasks[index];
          _tasks[index] = task.copyWith(
            id: existing.id,
            userId: _userId,
            deviceId: _deviceId,
            createdAt: existing.createdAt,
            updatedAt: now,
            version: existing.version + 1,
          );
        case TaskDeleted(:final id):
          final index = _indexOf(id);
          final existing = _tasks[index];
          _tasks[index] = existing.copyWith(
            deletedAt: now,
            updatedAt: now,
            version: existing.version + 1,
          );
      }
    }
    _notify();
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
