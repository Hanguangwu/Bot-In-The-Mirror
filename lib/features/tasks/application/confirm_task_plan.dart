import '../../../domain/repositories/ai_plan_repository.dart';

/// 确认任务计划用例：把计划内变更应用为正式任务（原子）。
class ConfirmTaskPlan {
  /// 注入计划仓储（构造器注入，便于测试替换）。
  ConfirmTaskPlan({required AIPlanRepository aiPlanRepository})
      : _aiPlanRepository = aiPlanRepository;

  final AIPlanRepository _aiPlanRepository;

  /// 确认 [planId] 对应的计划。
  Future<void> confirm(String planId) => _aiPlanRepository.confirm(planId);
}
