import 'sync_change.dart';

/// 远端变更的应用接缝（§6.3）。
///
/// **不经仓储写路径、不入同步队列**：实现直接写入实体表/内存仓储，
/// 以 LWW 规则决定是否落地。生产实现 `SyncEntityStoreImpl`（Drift）与
/// `MemorySyncEntityStore`（Lane-B）。
abstract interface class SyncEntityStore {
  /// 以 LWW 应用一条远端变更；返回是否实际写入。
  Future<bool> applyRemote(SyncChange change);

  /// 读本地当前版本（供 LWW 判定）；不存在返回 null。
  Future<({int version, DateTime updatedAt})?> localVersion(
    String entityType,
    String entityId,
  );
}
