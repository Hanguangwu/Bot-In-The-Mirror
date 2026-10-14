import '../entities/sync.dart';

/// 本地同步队列仓储。M2a 只入队与查询（不触网）；M2b 由 SyncEngine 消费。
abstract interface class SyncOperationRepository {
  /// 取待处理操作（status==pending），按 createdAt 正序、同刻按 id 兜底。
  Future<List<SyncOperation>> getPending();

  /// 监听待处理操作（同上排序）。
  Stream<List<SyncOperation>> watchPending();

  /// 追加一条操作；**在调用方事务内执行，内部不另开事务**。
  Future<void> enqueue(SyncOperation operation);

  /// 批量追加（事务内批量插入；供逐条墓碑化等场景）。
  Future<void> enqueueAll(List<SyncOperation> operations);

  /// 更新操作状态/重试/错误（M2b 消费；本期仅测试用）。
  Future<void> mark(SyncOperation operation);

  /// 推送成功后删除 `status==synced` 的操作（§6.5/§7.5）。
  Future<void> deleteSynced();

  /// 拉取收敛后删除 `status==conflicted` 的操作（§6.5/§7.5）。
  Future<void> deleteConflicted();

  /// 手动重试：`status==failed` → `pending`，并清 `lastError`（§6.5/§7.5）。
  Future<void> requeueFailed();
}
