import 'package:drift/drift.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../../domain/repositories/task_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'app_database.dart';

// TEXT 枚举：以枚举 `.name` 序列化，增删枚举值不错位历史数据（与 M0 会话仓储一致）。
TaskStatus _statusFromDrift(String name) => TaskStatus.values.byName(name);
String _statusToDrift(TaskStatus status) => status.name;
TaskPriority _priorityFromDrift(String name) => TaskPriority.values.byName(name);
String _priorityToDrift(TaskPriority priority) => priority.name;

/// 基于 Drift 的任务仓储实现。
///
/// 写入时由实现统一补齐/覆盖 `userId`、`deviceId`、`createdAt`、`updatedAt`、
/// `version`，保证同步字段一致（与 M0 会话仓储同规则）。
class TaskRepositoryImpl implements TaskRepository {
  /// 创建仓储；[userId]/[deviceId] 在本实例内固定。
  TaskRepositoryImpl(
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
  Stream<List<Task>> watchTasks(TaskQuery query) => _buildQuery(query)
      .watch()
      .map((rows) => rows.map(_toTask).toList(growable: false));

  @override
  Future<List<Task>> getTasks(TaskQuery query) async {
    final rows = await _buildQuery(query).get();
    return rows.map(_toTask).toList(growable: false);
  }

  @override
  Future<Task> save(Task task) async {
    // §7.1：实体写入与入队同一事务；回滚不留孤儿操作。
    return _db.transaction(() async {
      final now = _clock.now();
      final existing = await _findRow(task.id);
      if (existing == null) {
        final stored = task.copyWith(
          id: task.id.isEmpty ? generateId() : task.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        await _db.into(_db.tasks).insert(_toCompanion(stored));
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
        return stored;
      }
      final updated = task.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _db.into(_db.tasks).insertOnConflictUpdate(_toCompanion(updated));
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
      return updated;
    });
  }

  @override
  Future<void> applyChanges(List<TaskChange> changes) async {
    await _db.transaction(() async {
      // 先全量校验：update/delete 的目标必须存在，否则整体拒绝且不写入任何行。
      for (final change in changes) {
        switch (change) {
          case TaskInserted():
            break;
          case TaskUpdated(:final task):
            if (await _findRow(task.id) == null) {
              throw const ConflictException('任务不存在，无法更新');
            }
          case TaskDeleted(:final id):
            if (await _findRow(id) == null) {
              throw const ConflictException('任务不存在，无法删除');
            }
        }
      }

      // 校验通过后再提交；任一步骤异常都会随事务整体回滚（含入队）。
      final now = _clock.now();
      for (final change in changes) {
        switch (change) {
          case TaskInserted(:final task):
            final stored = task.copyWith(
              id: task.id.isEmpty ? generateId() : task.id,
              userId: _userId,
              deviceId: _deviceId,
            );
            await _db.into(_db.tasks).insert(_toCompanion(stored));
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
            final existing = await _findRow(task.id);
            if (existing == null) {
              throw const ConflictException('任务不存在，无法更新');
            }
            final updated = task.copyWith(
              id: existing.id,
              userId: _userId,
              deviceId: _deviceId,
              createdAt: existing.createdAt,
              updatedAt: now,
              version: existing.version + 1,
            );
            await _db
                .into(_db.tasks)
                .insertOnConflictUpdate(_toCompanion(updated));
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
            final existing = await _findRow(id);
            if (existing == null) {
              throw const ConflictException('任务不存在，无法删除');
            }
            final tombstone = _toTask(existing).copyWith(
              deletedAt: now,
              updatedAt: now,
              version: existing.version + 1,
            );
            await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
              TasksCompanion(
                deletedAt: Value(now),
                updatedAt: Value(now),
                version: Value(existing.version + 1),
              ),
            );
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
    });
  }

  /// 构造下推查询：仅下推 `deletedAt IS NULL` + 单值 status/projectId/due 区间/LIKE。
  ///
  /// 注意（B3）：status 集合过滤不在数据库侧做，由 UI 本地过滤；排序 createdAt DESC。
  SimpleSelectStatement<$TasksTable, TaskRow> _buildQuery(TaskQuery query) {
    final select = _db.select(_db.tasks);
    var predicate = _db.tasks.deletedAt.isNull();
    final status = query.status;
    if (status != null) {
      predicate = predicate & _db.tasks.status.equals(_statusToDrift(status));
    }
    final projectId = query.projectId;
    if (projectId != null) {
      predicate = predicate & _db.tasks.projectId.equals(projectId);
    }
    final dueFrom = query.dueFrom;
    if (dueFrom != null) {
      predicate = predicate & _db.tasks.dueAt.isBiggerOrEqualValue(dueFrom);
    }
    final dueTo = query.dueTo;
    if (dueTo != null) {
      predicate = predicate & _db.tasks.dueAt.isSmallerOrEqualValue(dueTo);
    }
    final text = query.text;
    if (text != null && text.isNotEmpty) {
      final pattern = '%$text%';
      predicate = predicate &
          (_db.tasks.title.like(pattern) | _db.tasks.description.like(pattern));
    }
    select.where((_) => predicate);
    select.orderBy([
      (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
    ]);
    return select;
  }

  Future<TaskRow?> _findRow(String id) async {
    if (id.isEmpty) {
      return null;
    }
    return (_db.select(_db.tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Task _toTask(TaskRow row) => Task(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        projectId: row.projectId,
        title: row.title,
        description: row.description,
        status: _statusFromDrift(row.status),
        priority: _priorityFromDrift(row.priority),
        dueAt: row.dueAt,
        parentTaskId: row.parentTaskId,
        repeatRule: row.repeatRule,
        sourceMessageId: row.sourceMessageId,
        sortOrder: row.sortOrder,
      );

  TasksCompanion _toCompanion(Task task) => TasksCompanion(
        id: Value(task.id),
        userId: Value(task.userId),
        createdAt: Value(task.createdAt),
        updatedAt: Value(task.updatedAt),
        deletedAt: Value(task.deletedAt),
        version: Value(task.version),
        deviceId: Value(task.deviceId),
        projectId: Value(task.projectId),
        title: Value(task.title),
        description: Value(task.description),
        status: Value(_statusToDrift(task.status)),
        priority: Value(_priorityToDrift(task.priority)),
        dueAt: Value(task.dueAt),
        parentTaskId: Value(task.parentTaskId),
        repeatRule: Value(task.repeatRule),
        sourceMessageId: Value(task.sourceMessageId),
        sortOrder: Value(task.sortOrder),
      );
}
