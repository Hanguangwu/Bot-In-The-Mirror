import '../../../core/config/app_config.dart';
import '../../../core/time/clock.dart';
import '../../../domain/repositories/ai_plan_repository.dart';

/// AI 待确认计划自动过期用例（M2a §9）。
///
/// 读取时惰性扫描：找出 `status==awaitingConfirmation` 且 `createdAt` 距今超过
/// [expireAfter]（默认 [aiPlanExpireAfter]）的计划，一次性调用
/// `markExpired` 置过期并入队。**不启动定时器**——由 UI 在合适的读取时机触发。
class ExpirePendingPlans {
  /// 注入计划仓储；[clock] 与 [expireAfter] 便于测试注入可控时间与短时长。
  ExpirePendingPlans({
    required AIPlanRepository aiPlanRepository,
    Clock? clock,
    Duration expireAfter = aiPlanExpireAfter,
  })  : _aiPlanRepository = aiPlanRepository,
        _clock = clock ?? const SystemClock(),
        _expireAfter = expireAfter;

  final AIPlanRepository _aiPlanRepository;
  final Clock _clock;
  final Duration _expireAfter;

  /// 执行一次惰性过期扫描；无超期计划时不调用 `markExpired`。
  Future<void> expire() async {
    final pending = await _aiPlanRepository.getPending();
    final now = _clock.now();
    final ids = <String>[
      for (final plan in pending)
        if (now.difference(plan.createdAt) > _expireAfter) plan.id,
    ];
    if (ids.isEmpty) {
      return;
    }
    await _aiPlanRepository.markExpired(ids);
  }
}
