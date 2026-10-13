import '../../../domain/repositories/ai_plan_repository.dart';

/// 拒绝任务计划用例：把计划标记为 rejected。
class RejectTaskPlan {
  /// 注入计划仓储（构造器注入，便于测试替换）。
  RejectTaskPlan({required AIPlanRepository aiPlanRepository})
      : _aiPlanRepository = aiPlanRepository;

  final AIPlanRepository _aiPlanRepository;

  /// 拒绝 [planId] 对应的计划。
  Future<void> reject(String planId) => _aiPlanRepository.reject(planId);
}
