import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/ai_plan_repository.dart';
import '../../domain/repositories/task_repository.dart';

/// 内存 AI 计划仓储：行为与 Drift 实现一致，供测试与预览使用。
///
/// [confirm] 依赖注入的同一 [MemoryTaskRepository] 实例：其 `applyChanges`
/// 采用「先全量校验（含目标存在性）再一次性提交」，天然全或无（S2），
/// 因此计划状态只在任务写入成功后才变更。
class MemoryAIPlanRepository implements AIPlanRepository {
  /// 创建内存仓储；[taskRepository] 应为与调用方共享的同一内存任务仓储实例。
  MemoryAIPlanRepository(
    this._taskRepository, {
    String? userId,
    String? deviceId,
    Clock? clock,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock();

  final TaskRepository _taskRepository;
  final String _userId;
  final String _deviceId;
  final Clock _clock;
  final List<AIPlan> _plans = <AIPlan>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<List<AIPlan>> watchPending() {
    late StreamController<List<AIPlan>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<AIPlan>>(
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
  Future<List<AIPlan>> getPending() async => _pending();

  /// 按 id 读取计划（含已处理/已删除），不存在返回 null；供用例/测试读取状态。
  Future<AIPlan?> planById(String id) async {
    final index = _indexOf(id);
    return index < 0 ? null : _plans[index];
  }

  @override
  Future<AIPlan> save(AIPlan plan) async {
    final now = _clock.now();
    final index = _indexOf(plan.id);
    if (index < 0) {
      final stored = plan.copyWith(
        id: plan.id.isEmpty ? generateId() : plan.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: now,
        updatedAt: now,
        version: 1,
      );
      _plans.add(stored);
      _notify();
      return stored;
    }
    final existing = _plans[index];
    final updated = plan.copyWith(
      id: existing.id,
      userId: _userId,
      deviceId: _deviceId,
      createdAt: existing.createdAt,
      updatedAt: now,
      version: existing.version + 1,
    );
    _plans[index] = updated;
    _notify();
    return updated;
  }

  @override
  Future<void> confirm(String planId) async {
    final index = _indexOf(planId);
    if (index < 0 ||
        _plans[index].status != AIPlanStatus.awaitingConfirmation) {
      throw const ConflictException('计划不存在或已处理，无法确认');
    }
    final plan = _plans[index];
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
    // applyChanges 先校验后提交；失败会抛异常且不写入，计划状态保持不变，
    // 因此天然原子（S2）。
    await _taskRepository.applyChanges(changes);
    _plans[index] = plan.copyWith(
      status: AIPlanStatus.applied,
      confirmedAt: now,
      appliedAt: now,
      updatedAt: now,
      version: plan.version + 1,
    );
    _notify();
  }

  @override
  Future<void> reject(String planId) async {
    final index = _indexOf(planId);
    if (index < 0 ||
        _plans[index].status != AIPlanStatus.awaitingConfirmation) {
      throw const ConflictException('计划不存在或已处理，无法拒绝');
    }
    final now = _clock.now();
    final plan = _plans[index];
    _plans[index] = plan.copyWith(
      status: AIPlanStatus.rejected,
      rejectedAt: now,
      updatedAt: now,
      version: plan.version + 1,
    );
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
    return _plans.indexWhere((plan) => plan.id == id);
  }

  List<AIPlan> _pending() {
    final result = _plans
        .where(
          (plan) =>
              plan.deletedAt == null &&
              plan.status == AIPlanStatus.awaitingConfirmation,
        )
        .toList();
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List<AIPlan>.unmodifiable(result);
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
