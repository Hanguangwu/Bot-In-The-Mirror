import 'dart:async';

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
import 'memory_store.dart';

/// 内存 AI 计划仓储：行为与 Drift 实现一致，供测试与预览使用。
///
/// [confirm]/[save]/[reject] 经 [MemoryStore.runAtomic] 包裹，与注入的同一
/// [MemoryTaskRepository]/[CalendarEntryRepository]/[MemorySyncOperationRepository]
/// 实例共享全或无接缝：跨任务/日历/计划/队列的任一异常都会整体还原（§7.2）。
class MemoryAIPlanRepository implements AIPlanRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[taskRepository]/[calendarEntryRepository] 应为与调用方
  /// 共享的同一内存仓储实例（保证内存 confirm 的全或无语义）。
  ///
  /// [syncOperationRepository] 用于入队；[memoryStore] 提供跨仓储全或无接缝。
  MemoryAIPlanRepository(
    this._taskRepository, {
    required SyncOperationRepository syncOperationRepository,
    required CalendarEntryRepository calendarEntryRepository,
    MemoryStore? memoryStore,
    String? userId,
    String? deviceId,
    Clock? clock,
  })  : _syncOperationRepository = syncOperationRepository,
        _calendarEntryRepository = calendarEntryRepository,
        _memoryStore = memoryStore,
        _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock() {
    memoryStore?.register(this);
  }

  final TaskRepository _taskRepository;
  final CalendarEntryRepository _calendarEntryRepository;
  final SyncOperationRepository _syncOperationRepository;
  final MemoryStore? _memoryStore;
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
    return _atomic(() async {
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
        await _enqueuePlan(stored, SyncOperationKind.create, now);
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
      await _enqueuePlan(updated, SyncOperationKind.update, now);
      _notify();
      return updated;
    });
  }

  @override
  Future<void> confirm(String planId) async {
    return _atomic(() async {
      final index = _indexOf(planId);
      if (index < 0 ||
          _plans[index].status != AIPlanStatus.awaitingConfirmation) {
        throw const ConflictException('计划不存在或已处理，无法确认');
      }
      final plan = _plans[index];
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

      // applyChanges 先校验后提交并同事务入队 task create；失败会抛异常且不写入。
      await _taskRepository.applyChanges(taskChanges);

      // 日历条目写入（save 自身在同原子接缝内入队 calendar_entry create，
      // §7.3/§10；此处不得重复入队，避免同一实体入队两次）。
      for (final entry in calendarEntries) {
        await _calendarEntryRepository.save(entry);
      }

      final applied = plan.copyWith(
        status: AIPlanStatus.applied,
        confirmedAt: now,
        appliedAt: now,
        updatedAt: now,
        version: plan.version + 1,
      );
      _plans[index] = applied;
      await _enqueuePlan(applied, SyncOperationKind.update, now);
      _notify();
    });
  }

  @override
  Future<void> reject(String planId) async {
    return _atomic(() async {
      final index = _indexOf(planId);
      if (index < 0 ||
          _plans[index].status != AIPlanStatus.awaitingConfirmation) {
        throw const ConflictException('计划不存在或已处理，无法拒绝');
      }
      final now = _clock.now();
      final plan = _plans[index];
      final updated = plan.copyWith(
        status: AIPlanStatus.rejected,
        rejectedAt: now,
        updatedAt: now,
        version: plan.version + 1,
      );
      _plans[index] = updated;
      await _enqueuePlan(updated, SyncOperationKind.update, now);
      _notify();
    });
  }

  @override
  Future<void> markExpired(List<String> ids) async {
    return _atomic(() async {
      final now = _clock.now();
      for (final id in ids) {
        final index = _indexOf(id);
        if (index < 0) {
          continue;
        }
        final plan = _plans[index];
        if (plan.status != AIPlanStatus.awaitingConfirmation) {
          continue;
        }
        final updated = plan.copyWith(
          status: AIPlanStatus.expired,
          expiredAt: now,
          updatedAt: now,
          version: plan.version + 1,
        );
        _plans[index] = updated;
        await _enqueuePlan(updated, SyncOperationKind.update, now);
      }
      _notify();
    });
  }

  @override
  Object? snapshot() => List<AIPlan>.of(_plans);

  @override
  void restore(Object? snapshot) {
    _plans
      ..clear()
      ..addAll(snapshot! as List<AIPlan>);
    _notify();
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
