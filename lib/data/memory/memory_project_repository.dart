import 'dart:async';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/project_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'memory_store.dart';

/// 内存项目仓储：行为与 Drift 实现等价。写路径经 [MemoryStore.runAtomic] 包裹
/// 并入队（§5.3/§7.1）。装配时若提供 [MemoryStore] 则注册自身。
class MemoryProjectRepository
    implements ProjectRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  ///
  /// [syncOperationRepository] 用于入队；[store] 提供跨仓储全或无接缝。
  MemoryProjectRepository({
    required SyncOperationRepository syncOperationRepository,
    Clock? clock,
    String? userId,
    String? deviceId,
    MemoryStore? store,
  })  : _clock = clock ?? const SystemClock(),
        _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _syncOperationRepository = syncOperationRepository,
        _memoryStore = store {
    store?.register(this);
  }

  final Clock _clock;
  final String _userId;
  final String _deviceId;
  final SyncOperationRepository _syncOperationRepository;
  final MemoryStore? _memoryStore;
  final List<Project> _projects = <Project>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Future<List<Project>> getProjects() async => _active();

  @override
  Stream<List<Project>> watchProjects() {
    late StreamController<List<Project>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<Project>>(
      onListen: () {
        controller.add(_active());
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_active());
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
  Future<Project?> get(String id) async {
    final index = _indexOf(id);
    if (index < 0) {
      return null;
    }
    final project = _projects[index];
    return project.deletedAt == null ? project : null;
  }

  @override
  Future<Project> save(Project project) {
    // §5.3/§7.1：实体写入与入队经同一原子接缝；回滚不留孤儿操作。
    return _atomic(() async {
      final now = _clock.now();
      final index = _indexOf(project.id);
      if (index < 0) {
        final stored = project.copyWith(
          id: project.id.isEmpty ? generateId() : project.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        _projects.add(stored);
        await _enqueue(stored, SyncOperationKind.create, now);
        _notify();
        return stored;
      }
      final existing = _projects[index];
      final updated = project.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      _projects[index] = updated;
      await _enqueue(updated, SyncOperationKind.update, now);
      _notify();
      return updated;
    });
  }

  @override
  Future<void> delete(String id) {
    // §5.3/§7.1/§8：墓碑写入与入队同一原子接缝；快照含 deletedAt。
    return _atomic(() async {
      final index = _indexOf(id);
      if (index < 0) {
        return;
      }
      final project = _projects[index];
      if (project.deletedAt != null) {
        return;
      }
      final now = _clock.now();
      final tombstone = project.copyWith(
        deletedAt: now,
        updatedAt: now,
        version: project.version + 1,
      );
      _projects[index] = tombstone;
      await _enqueue(tombstone, SyncOperationKind.delete, now);
      _notify();
    });
  }

  /// 构造并入队一条 project 同步操作（payload 为最终实体快照，§6/§7.3）。
  Future<void> _enqueue(
    Project project,
    SyncOperationKind kind,
    DateTime now,
  ) async {
    await _syncOperationRepository.enqueue(
      buildSyncOperation(
        entity: project,
        entityType: 'project',
        kind: kind,
        userId: _userId,
        deviceId: _deviceId,
        now: now,
      ),
    );
  }

  /// 数据层内部「原始写入」接缝（Lane-B §6.3）：以远端快照覆盖本地项目，
  /// **不入同步队列**；写入后广播变更流（UI 刷新）。按 id 覆盖或新增。
  void applyRemoteSnapshot(Project project) {
    final index = _indexOf(project.id);
    if (index < 0) {
      _projects.add(project);
    } else {
      _projects[index] = project;
    }
    _notify();
  }

  /// 读取项目当前版本/更新时间；不存在返回 null（供 LWW）。
  ({int version, DateTime updatedAt})? localVersionOf(String id) {
    final index = _indexOf(id);
    if (index < 0) {
      return null;
    }
    final project = _projects[index];
    return (version: project.version, updatedAt: project.updatedAt);
  }

  @override
  Object? snapshot() => List<Project>.of(_projects);

  @override
  void restore(Object? snapshot) {
    _projects
      ..clear()
      ..addAll(snapshot! as List<Project>);
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
    return _projects.indexWhere((project) => project.id == id);
  }

  List<Project> _active() {
    final result =
        _projects.where((project) => project.deletedAt == null).toList();
    result.sort((a, b) {
      final compared = a.createdAt.compareTo(b.createdAt);
      return compared != 0 ? compared : a.id.compareTo(b.id);
    });
    return List<Project>.unmodifiable(result);
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
