import '../../../domain/ai/ai_client.dart';
import '../../../domain/entities/ai_plan.dart';
import '../../../domain/repositories/ai_plan_repository.dart';

/// 生成任务计划用例。
///
/// 调用 AI 拆解 [PlanRequest]；非空变更落库为待确认计划并返回，空变更
/// （未能拆解，§6.2 规则 7）不落库并返回 `null`，由 UI 提示用户。
class ProposeTaskPlan {
  /// 注入 AI 客户端与计划仓储（构造器注入，便于测试替换）。
  ProposeTaskPlan({
    required AIClient aiClient,
    required AIPlanRepository aiPlanRepository,
  })  : _aiClient = aiClient,
        _aiPlanRepository = aiPlanRepository;

  final AIClient _aiClient;
  final AIPlanRepository _aiPlanRepository;

  /// 执行拆解；返回已落库的待确认计划，未能拆解时返回 `null`。
  Future<AIPlan?> propose(PlanRequest request) async {
    final plan = await _aiClient.proposePlan(request);
    if (plan.changes.isEmpty) {
      return null;
    }
    return _aiPlanRepository.save(plan);
  }
}
