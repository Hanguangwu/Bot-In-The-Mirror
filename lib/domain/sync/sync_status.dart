import '../entities/sync.dart';

/// 同步引擎对外可观测状态（§6.6，B4）。
///
/// 取代基线 §5 的 `watchState()` 草图：在状态之外携带最近报告/错误/同步时间，
/// 供设置页同步状态页展示。待同步条数仍由
/// `SyncOperationRepository.watchPending` 提供（不在此重复）。
class SyncStatus {
  /// 创建同步状态。
  const SyncStatus({
    required this.state,
    this.lastReport,
    this.lastError,
    this.lastSyncAt,
  });

  /// 当前引擎状态。
  final SyncState state;

  /// 最近一次同步报告；从未同步为 null。
  final SyncReport? lastReport;

  /// 最近一次错误摘要；无错误为 null。
  final String? lastError;

  /// 最近一次成功同步完成时间；从未同步为 null。
  final DateTime? lastSyncAt;
}
