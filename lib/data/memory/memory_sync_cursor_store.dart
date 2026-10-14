import '../../domain/sync/sync_cursor_store.dart';

/// 内存版游标存储（测试用）。
class MemorySyncCursorStore implements SyncCursorStore {
  int _cursor = 0;
  DateTime? _lastSyncAt;

  @override
  Future<int> read() async => _cursor;

  @override
  Future<void> write(int cursor) async {
    _cursor = cursor;
  }

  @override
  Future<DateTime?> readLastSyncAt() async => _lastSyncAt;

  @override
  Future<void> writeLastSyncAt(DateTime at) async {
    _lastSyncAt = at;
  }

  void reset() {
    _cursor = 0;
    _lastSyncAt = null;
  }
}
