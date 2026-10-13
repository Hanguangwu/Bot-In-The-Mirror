import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/ai_plan_repository.dart';
import '../../domain/repositories/task_repository.dart';
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

/// 基于 Drift 的 AI 计划仓储实现；[confirm] 在单事务内原子应用变更。
class AIPlanRepositoryImpl implements AIPlanRepository {
  /// 创建仓储；[taskRepository] 必须与本仓储共享同一 [AppDatabase] 单例，
  /// 否则 Drift 嵌套事务无法复用外层，confirm 原子性不成立。
  AIPlanRepositoryImpl(
    this._db,
    this._taskRepository,
    this._clock, {
    String? userId,
    String? deviceId,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId();

  final AppDatabase _db;
  final TaskRepository _taskRepository;
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
    return updated;
  }

  @override
  Future<void> confirm(String planId) async {
    // 单事务内完成「读计划 → 物化任务 → applyChanges → 计划置 applied」。
    // Drift 2.35.2 嵌套事务复用外层（SAVEPOINT），内层异常冒泡即整体回滚。
    await _db.transaction(() async {
      final row = await _findRow(planId);
      if (row == null || row.status != AIPlanStatus.awaitingConfirmation.name) {
        throw const ConflictException('计划不存在或已处理，无法确认');
      }
      final plan = _toPlan(row);
      final now = _clock.now();
      final changes = <TaskChange>[
        for (final change in plan.changes)
          TaskInserted(
            taskFromPlanChange(
              change,
              plan,
              userId: _userId,
              deviceId: _deviceId,
              now: now,
            ),
          ),
      ];
      // 刻意不 catch：applyChanges 的异常必须冒泡以回滚整个事务（计划不得标记 applied）。
      await _taskRepository.applyChanges(changes);
      await (_db.update(_db.aiPlans)..where((t) => t.id.equals(planId))).write(
        AiPlansCompanion(
          status: Value(AIPlanStatus.applied.name),
          confirmedAt: Value(now),
          appliedAt: Value(now),
          updatedAt: Value(now),
          version: Value(row.version + 1),
        ),
      );
    });
  }

  @override
  Future<void> reject(String planId) async {
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
      );
}
