import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/config/app_config.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/memory/memory_ai_plan_repository.dart';
import 'package:chatwithalice/data/memory/memory_calendar_entry_repository.dart';
import 'package:chatwithalice/data/memory/memory_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/features/tasks/application/confirm_task_plan.dart';
import 'package:chatwithalice/features/tasks/application/expire_pending_plans.dart';
import 'package:flutter_test/flutter_test.dart';

class _MutableClock implements Clock {
  _MutableClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;
}

class _Fixture {
  _Fixture(this.clock) {
    final store = MemoryStore();
    syncOps = MemorySyncOperationRepository(
      clock: clock,
      userId: 'user-1',
      deviceId: 'device-1',
      store: store,
    );
    tasks = MemoryTaskRepository(
      syncOperationRepository: syncOps,
      clock: clock,
      userId: 'user-1',
      deviceId: 'device-1',
      store: store,
    );
    calendar = MemoryCalendarEntryRepository(
      syncOperationRepository: syncOps,
      clock: clock,
      userId: 'user-1',
      deviceId: 'device-1',
      store: store,
    );
    repo = MemoryAIPlanRepository(
      tasks,
      syncOperationRepository: syncOps,
      calendarEntryRepository: calendar,
      memoryStore: store,
      clock: clock,
      userId: 'user-1',
      deviceId: 'device-1',
    );
  }

  late MemoryAIPlanRepository repo;
  late MemoryTaskRepository tasks;
  late MemoryCalendarEntryRepository calendar;
  late MemorySyncOperationRepository syncOps;
  final Clock clock;
}

AIPlan _awaiting({
  String id = 'p1',
  DateTime? createdAt,
}) {
  return AIPlan(
    id: id,
    userId: '',
    createdAt: createdAt ?? DateTime(2026, 1, 1, 9),
    updatedAt: createdAt ?? DateTime(2026, 1, 1, 9),
    version: 1,
    deviceId: '',
    conversationId: 'c1',
    sourceMessageId: 'm1',
    status: AIPlanStatus.awaitingConfirmation,
    aiModel: 'gpt-3.5-turbo',
    promptVersion: 'm2a-plan-v1',
    changes: const <AIPlanChange>[],
  );
}

void main() {
  group('ExpirePendingPlans', () {
    test('47h59m 不过期', () async {
      // 仓储在新建时以时钟 now 作为 createdAt，故先在建库时刻保存、再推进时钟。
      final clock = _MutableClock(DateTime(2026, 1, 1, 9));
      final f = _Fixture(clock);
      await f.repo.save(_awaiting());
      clock.current = DateTime(2026, 1, 3, 8, 59);

      await ExpirePendingPlans(
        aiPlanRepository: f.repo,
        clock: clock,
        expireAfter: aiPlanExpireAfter,
      ).expire();

      final stored = await f.repo.planById('p1');
      expect(stored!.status, AIPlanStatus.awaitingConfirmation);
      expect(stored.expiredAt, isNull);
      final ops = await f.syncOps.getPending();
      expect(ops.where((op) => op.kind == SyncOperationKind.update), isEmpty);
    });

    test('48h01m 过期；markExpired 入队 ai_plan update', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1, 9));
      final f = _Fixture(clock);
      await f.repo.save(_awaiting());
      clock.current = DateTime(2026, 1, 3, 9, 1);

      await ExpirePendingPlans(
        aiPlanRepository: f.repo,
        clock: clock,
        expireAfter: aiPlanExpireAfter,
      ).expire();

      final stored = await f.repo.planById('p1');
      expect(stored!.status, AIPlanStatus.expired);
      expect(stored.expiredAt, isNotNull);
      final ops = await f.syncOps.getPending();
      final updates = ops.where((op) => op.entityType == 'ai_plan' && op.kind == SyncOperationKind.update);
      expect(updates.isNotEmpty, isTrue);
      expect(updates.last.payload['status'], AIPlanStatus.expired.name);
      expect(updates.last.payload.containsKey('expiredAt'), isTrue);
    });

    test('已 applied/rejected 不动', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1, 9));
      final f = _Fixture(clock);
      final applied = await f.repo.save(_awaiting(id: 'a'));
      await f.repo.confirm(applied.id);
      await f.repo.save(_awaiting(id: 'r'));
      await f.repo.reject('r');
      clock.current = DateTime(2026, 1, 3, 10);

      await ExpirePendingPlans(
        aiPlanRepository: f.repo,
        clock: clock,
        expireAfter: aiPlanExpireAfter,
      ).expire();

      expect((await f.repo.planById('a'))!.status, AIPlanStatus.applied);
      expect((await f.repo.planById('r'))!.status, AIPlanStatus.rejected);
    });

    test('确认过期计划抛 ConflictException', () async {
      final clock = _MutableClock(DateTime(2026, 1, 1, 9));
      final f = _Fixture(clock);
      await f.repo.save(_awaiting());
      clock.current = DateTime(2026, 1, 3, 9, 5);
      await ExpirePendingPlans(
        aiPlanRepository: f.repo,
        clock: clock,
        expireAfter: aiPlanExpireAfter,
      ).expire();

      final confirm = ConfirmTaskPlan(aiPlanRepository: f.repo);
      await expectLater(confirm.confirm('p1'), throwsA(isA<ConflictException>()));
    });
  });
}
