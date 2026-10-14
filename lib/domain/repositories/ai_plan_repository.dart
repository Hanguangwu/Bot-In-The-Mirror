import '../entities/ai_plan.dart';

/// AI 计划仓储。M1 实现；确认/拒绝与应用变更保持原子。
abstract interface class AIPlanRepository {
  /// 监听「待确认」（awaitingConfirmation）计划，按 createdAt 正序。
  Stream<List<AIPlan>> watchPending();

  /// 一次性获取待确认计划。
  Future<List<AIPlan>> getPending();

  /// 保存计划（草稿/待确认）。
  Future<AIPlan> save(AIPlan plan);

  /// 确认：把计划内变更应用到任务表并把计划置为 applied（同事务）。
  Future<void> confirm(String planId);

  /// 拒绝：标记 rejected + rejectedAt。
  Future<void> reject(String planId);

  /// 惰性过期：仅当计划存在且处于 awaitingConfirmation 时置 expired + expiredAt，
  /// 同事务入队 `ai_plan` update；异常冒泡整体回滚（§9/§14）。
  Future<void> markExpired(List<String> ids);
}
