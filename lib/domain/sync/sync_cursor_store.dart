/// 拉取游标与上次同步时间的持久化接缝（§9.2）。
///
/// 生产实现走 shared_preferences（键 `sync_cursor`/`sync_last_at`）；
/// 测试用内存实现。`lastSyncAt` 持久化用于冷启动后状态页展示「上次同步时间」。
abstract interface class SyncCursorStore {
  /// 读取当前拉取游标；首次为 0。
  Future<int> read();

  /// 写入拉取游标。
  Future<void> write(int cursor);

  /// 读取上次同步完成时间；从未同步返回 null。
  Future<DateTime?> readLastSyncAt();

  /// 写入上次同步完成时间。
  Future<void> writeLastSyncAt(DateTime at);
}
