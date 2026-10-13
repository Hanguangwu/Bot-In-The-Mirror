import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/repositories/ai_plan_repository.dart';
import 'package:chatwithalice/features/tasks/application/confirm_task_plan.dart';
import 'package:chatwithalice/features/tasks/application/reject_task_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假计划仓储：记录 confirm/reject 转发参数。
class _FakeAIPlanRepository implements AIPlanRepository {
  final List<String> confirmed = <String>[];
  final List<String> rejected = <String>[];

  @override
  Future<void> confirm(String planId) async {
    confirmed.add(planId);
  }

  @override
  Future<void> reject(String planId) async {
    rejected.add(planId);
  }

  @override
  Future<AIPlan> save(AIPlan plan) async => plan;

  @override
  Stream<List<AIPlan>> watchPending() => const Stream<List<AIPlan>>.empty();

  @override
  Future<List<AIPlan>> getPending() async => const <AIPlan>[];
}

void main() {
  test('confirm 用例把 planId 转发给仓储', () async {
    final repository = _FakeAIPlanRepository();
    final useCase = ConfirmTaskPlan(aiPlanRepository: repository);

    await useCase.confirm('plan-42');

    expect(repository.confirmed, <String>['plan-42']);
    expect(repository.rejected, isEmpty);
  });

  test('reject 用例把 planId 转发给仓储', () async {
    final repository = _FakeAIPlanRepository();
    final useCase = RejectTaskPlan(aiPlanRepository: repository);

    await useCase.reject('plan-7');

    expect(repository.rejected, <String>['plan-7']);
    expect(repository.confirmed, isEmpty);
  });
}
