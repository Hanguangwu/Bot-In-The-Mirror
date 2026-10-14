import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/sync.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/ai_plan_repository.dart';
import '../../domain/repositories/calendar_entry_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../../domain/repositories/task_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'app_database.dart';

// TEXT 枚举：以枚举 `.name` 序列化，增删枚举值不错位历史数据（与 M0 会话仓储一致）。
AIPlanStatus _statusFromDrift(String name) => AIPlanStatus.values.byName(name);
String _statusToDrift(AIPlanStatus status) => status.name;

/// 解析 `changes` 列的 JSON 字符串；结构非法一律抛 [PlanValidationException]。
///
/// 与 Conversation metadata 的「宽容默认」不同：AI 计划是业务数据，数据完整性
/// 优先，故此处不吞掉格式错误（§4.5）。
List<AIPlanChange> _decodeChanges(String source) {
  try {
    return decodeChanges(jsonDecode(source));
  } on FormatException {
    throw const PlanValidationException('AI 返回的任务计划格式无效');
  }
}

/// 基于 Drift 的 AI 计划仓储实现；写路径在单事务内原子「实体写入 + 入队」，
/// [confirm] 在单事务内原子物化任务与日历条目并置 applied（§7.3/§10）。
class AIPlanRepositoryImpl implements AIPlanRepository {
  /// 创建仓储；[taskRepository]/[calendarEntryRepository] 必须与本仓储共享同一
  /// [AppDatabase] 单例，否则 Drift 嵌套事务无法复用外层，confirm 原子性不成立。
  ///
  /// [syncOperationRepository] 与日历条目写入同属 confirm 的同一事务；
  /// [calendarEntryRepository] 用于物化 `scheduleTask` 变更（§10）。
  AIPlanRepositoryImpl(
    this._db,
    this._taskRepository,
    this._clock, {
    required SyncOperationRepository syncOperationRepository,
    required CalendarEntryRepository calendarEntryRepository,
    String? userId,
    String? deviceId,
  })  : _syncOperationRepository = syncOperationRepository,
        _calendarEntryRepository = calendarEntryRepository,
        _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId();

  final AppDatabase _db;
  final TaskRepository _taskRepository;
  final CalendarEntryRepository _calendarEntryRepository;
  final SyncOperationRepository _syncOperationRepository;
  final Clock _clock;
  final String _userId;
  final String _deviceId;

  @override
  Stream<List<AIPlan>> watchPending() => _pendingQuery()
      .watch()
      .map((rows) => rows.map(_toPlan).toList(growable: false));

  @override
  Future<List<AIPlan>> getPending() async {
    final rows = await _pendingQuery().get();
    return rows.map(_toPlan).toList(growable: false);
  }

  /// 按 id 读取计划（含已处理/已删除），不存在返回 null；供用例/测试读取状态。
  Future<AIPlan?> planById(String id) async {
    final row = await _findRow(id);
    return row == null ? null : _toPlan(row);
  }

  @override
  Future<AIPlan> save(AIPlan plan) async {
    // 实体写入与入队同事务（§7.1）；新建 kind=create、更新 kind=update。
    return _db.transaction(() async {
      final now = _clock.now();
      final existing = await _findRow(plan.id);
      if (existing == null) {
        final stored = plan.copyWith(
          id: plan.id.isEmpty ? generateId() : plan.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        await _db.into(_db.aiPlans).insert(_toCompanion(stored));
        await _enqueuePlan(stored, SyncOperationKind.create, now);
        return stored;
      }
      final updated = plan.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _db.into(_db.aiPlans).insertOnConflictUpdate(_toCompanion(updated));
      await _enqueuePlan(updated, SyncOperationKind.update, now);
      return updated;
    });
  }

  @override
  Future<void> confirm(String planId) async {
    // 单事务内完成「读计划 → 物化任务/日历 → 写入 → 入队 → 计划置 applied」。
    // Drift 2.35.2 嵌套事务复用外层（SAVEPOINT），内层异常冒泡即整体回滚。
    await _db.transaction(() async {
      final row = await _findRow(planId);
      if (row == null || row.status != AIPlanStatus.awaitingConfirmation.name) {
        throw const ConflictException('计划不存在或已处理，无法确认');
      }
      final plan = _toPlan(row);
      final now = _clock.now();

      // 先全部物化（含类型校验），任一非法在写入前抛出；避免部分写入。
      final taskChanges = <TaskChange>[];
      final calendarEntries = <CalendarEntry>[];
      for (final change in plan.changes) {
        switch (change.type) {
          case AIPlanChangeType.createTask:
            taskChanges.add(
              TaskInserted(
                taskFromPlanChange(
                  change,
                  plan,
                  userId: _userId,
                  deviceId: _deviceId,
                  now: now,
                ),
              ),
            );
          case AIPlanChangeType.scheduleTask:
            calendarEntries.add(
              calendarEntryFromPlanChange(
                plan,
                change,
                userId: _userId,
                deviceId: _deviceId,
                now: now,
              ),
            );
          case AIPlanChangeType.updateTask:
          case AIPlanChangeType.deleteTask:
            throw const ConflictException('计划包含不支持的变更类型，无法确认');
        }
      }

      // 任务写入（applyChanges 内部同事务入队 task create）；异常冒泡以回滚。
      await _taskRepository.applyChanges(taskChanges);

      // 日历条目写入（save 自身在同事务内入队 calendar_entry create，§7.3/§10；
      // 此处不得重复入队，避免同一实体入队两次）。异常冒泡以回滚。
      for (final entry in calendarEntries) {
        await _calendarEntryRepository.save(entry);
      }

      // 计划置 applied + 入队 ai_plan update（快照为最终落库实体）。
      final applied = plan.copyWith(
        status: AIPlanStatus.applied,
        confirmedAt: now,
        appliedAt: now,
        updatedAt: now,
        version: row.version + 1,
      );
      await (_db.update(_db.aiPlans)..where((t) => t.id.equals(planId))).write(
        AiPlansCompanion(
          status: Value(AIPlanStatus.applied.name),
          confirmedAt: Value(now),
          appliedAt: Value(now),
          updatedAt: Value(now),
          version: Value(row.version + 1),
        ),
      );
      await _enqueuePlan(applied, SyncOperationKind.update, now);
    });
  }

  @override
  Future<void> reject(String planId) async {
    // 事务化：状态更新与入队原子（§7.1）。
    await _db.transaction(() async {
      final row = await _findRow(planId);
      if (row == null || row.status != AIPlanStatus.awaitingConfirmation.name) {
        throw const ConflictException('计划不存在或已处理，无法拒绝');
      }
      final now = _clock.now();
      await (_db.update(_db.aiPlans)..where((t) => t.id.equals(planId))).write(
        AiPlansCompanion(
          status: Value(AIPlanStatus.rejected.name),
          rejectedAt: Value(now),
          updatedAt: Value(now),
          version: Value(row.version + 1),
        ),
      );
      final rejected = _toPlan(row).copyWith(
        status: AIPlanStatus.rejected,
        rejectedAt: now,
        updatedAt: now,
        version: row.version + 1,
      );
      await _enqueuePlan(rejected, SyncOperationKind.update, now);
    });
  }

  @override
  Future<void> markExpired(List<String> ids) async {
    // 单事务内「置过期 + 入队」；仅处理存在且处于 awaitingConfirmation 的计划。
    // 异常冒泡即整体回滚（无孤儿队列行）。
    await _db.transaction(() async {
      final now = _clock.now();
      for (final id in ids) {
        final row = await _findRow(id);
        if (row == null) {
          continue;
        }
        if (row.status != AIPlanStatus.awaitingConfirmation.name) {
          continue;
        }
        await (_db.update(_db.aiPlans)..where((t) => t.id.equals(id))).write(
          AiPlansCompanion(
            status: Value(AIPlanStatus.expired.name),
            expiredAt: Value(now),
            updatedAt: Value(now),
            version: Value(row.version + 1),
          ),
        );
        final plan = _toPlan(row).copyWith(
          status: AIPlanStatus.expired,
          expiredAt: now,
          updatedAt: now,
          version: row.version + 1,
        );
        await _enqueuePlan(plan, SyncOperationKind.update, now);
      }
    });
  }

  /// 构造并入队一条 ai_plan 同步操作；payload 为最终落库实体快照（§6/§7.3）。
  Future<void> _enqueuePlan(
    AIPlan plan,
    SyncOperationKind kind,
    DateTime now,
  ) async {
    await _syncOperationRepository.enqueue(
      buildSyncOperation(
        entity: plan,
        entityType: 'ai_plan',
        kind: kind,
        userId: _userId,
        deviceId: _deviceId,
        now: now,
      ),
    );
  }

  SimpleSelectStatement<$AiPlansTable, AiPlanRow> _pendingQuery() {
    return _db.select(_db.aiPlans)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            t.status.equals(AIPlanStatus.awaitingConfirmation.name),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]);
  }

  Future<AiPlanRow?> _findRow(String id) async {
    if (id.isEmpty) {
      return null;
    }
    return (_db.select(_db.aiPlans)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  AIPlan _toPlan(AiPlanRow row) => AIPlan(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        conversationId: row.conversationId,
        sourceMessageId: row.sourceMessageId,
        status: _statusFromDrift(row.status),
        aiModel: row.aiModel,
        aiModelVersion: row.aiModelVersion,
        promptVersion: row.promptVersion,
        changes: _decodeChanges(row.changes),
        confirmedAt: row.confirmedAt,
        appliedAt: row.appliedAt,
        rejectedAt: row.rejectedAt,
        expiredAt: row.expiredAt,
      );

  AiPlansCompanion _toCompanion(AIPlan plan) => AiPlansCompanion(
        id: Value(plan.id),
        userId: Value(plan.userId),
        createdAt: Value(plan.createdAt),
        updatedAt: Value(plan.updatedAt),
        deletedAt: Value(plan.deletedAt),
        version: Value(plan.version),
        deviceId: Value(plan.deviceId),
        conversationId: Value(plan.conversationId),
        sourceMessageId: Value(plan.sourceMessageId),
        status: Value(_statusToDrift(plan.status)),
        aiModel: Value(plan.aiModel),
        aiModelVersion: Value(plan.aiModelVersion),
        promptVersion: Value(plan.promptVersion),
        changes: Value(jsonEncode(encodeChanges(plan.changes))),
        confirmedAt: Value(plan.confirmedAt),
        appliedAt: Value(plan.appliedAt),
        rejectedAt: Value(plan.rejectedAt),
        expiredAt: Value(plan.expiredAt),
      );
}
