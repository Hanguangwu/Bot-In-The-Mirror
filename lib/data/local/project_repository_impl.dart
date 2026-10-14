import 'package:drift/drift.dart';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/project_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'app_database.dart';

/// 基于 Drift 的项目仓储实现。
///
/// 写入时由实现统一补齐/覆盖 `userId`、`deviceId`、`createdAt`、`updatedAt`、
/// `version`（与 M1 任务/会话仓储同规则）；查询一律过滤 `deletedAt IS NULL`。
/// `save`/`delete` 在单事务内原子「实体写入 + 入队」（§5.3/§7.1）。
class ProjectRepositoryImpl implements ProjectRepository {
  /// 创建仓储；[userId]/[deviceId] 在本实例内固定。
  ///
  /// [syncOperationRepository] 必须与本仓储共享同一 [AppDatabase] 单例，
  /// 使入队复用外层事务（§7.1）。
  ProjectRepositoryImpl(
    this._db,
    this._clock, {
    required SyncOperationRepository syncOperationRepository,
    String? userId,
    String? deviceId,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _syncOperationRepository = syncOperationRepository;

  final AppDatabase _db;
  final Clock _clock;
  final String _userId;
  final String _deviceId;
  final SyncOperationRepository _syncOperationRepository;

  @override
  Future<List<Project>> getProjects() async {
    final rows = await _activeQuery().get();
    return rows.map(_toProject).toList(growable: false);
  }

  @override
  Stream<List<Project>> watchProjects() => _activeQuery()
      .watch()
      .map((rows) => rows.map(_toProject).toList(growable: false));

  @override
  Future<Project?> get(String id) async {
    final row = await _findRow(id);
    if (row == null || row.deletedAt != null) {
      return null;
    }
    return _toProject(row);
  }

  @override
  Future<Project> save(Project project) async {
    // §5.3/§7.1：实体写入与入队同一事务；回滚不留孤儿操作。
    return _db.transaction(() async {
      final now = _clock.now();
      final existing = await _findRow(project.id);
      if (existing == null) {
        final stored = project.copyWith(
          id: project.id.isEmpty ? generateId() : project.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        await _db.into(_db.projects).insert(_toCompanion(stored));
        await _enqueue(stored, SyncOperationKind.create, now);
        return stored;
      }
      final updated = project.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _db
          .into(_db.projects)
          .insertOnConflictUpdate(_toCompanion(updated));
      await _enqueue(updated, SyncOperationKind.update, now);
      return updated;
    });
  }

  @override
  Future<void> delete(String id) async {
    // §5.3/§7.1/§8：墓碑写入与入队同一事务；快照取墓碑化后的实体（含 deletedAt）。
    await _db.transaction(() async {
      final existing = await _findRow(id);
      if (existing == null || existing.deletedAt != null) {
        return;
      }
      final now = _clock.now();
      await (_db.update(_db.projects)..where((t) => t.id.equals(id))).write(
        ProjectsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
      final tombstone = _toProject(existing).copyWith(
        deletedAt: now,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _enqueue(tombstone, SyncOperationKind.delete, now);
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

  SimpleSelectStatement<$ProjectsTable, ProjectRow> _activeQuery() {
    return _db.select(_db.projects)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt),
        (t) => OrderingTerm(expression: t.id),
      ]);
  }

  Future<ProjectRow?> _findRow(String id) async {
    if (id.isEmpty) {
      return null;
    }
    return (_db.select(_db.projects)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Project _toProject(ProjectRow row) => Project(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        name: row.name,
        goal: row.goal,
        isArchived: row.isArchived,
      );

  ProjectsCompanion _toCompanion(Project project) => ProjectsCompanion(
        id: Value(project.id),
        userId: Value(project.userId),
        createdAt: Value(project.createdAt),
        updatedAt: Value(project.updatedAt),
        deletedAt: Value(project.deletedAt),
        version: Value(project.version),
        deviceId: Value(project.deviceId),
        name: Value(project.name),
        goal: Value(project.goal),
        isArchived: Value(project.isArchived),
      );
}
