import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/sync/sync_cursor_store.dart';

/// 基于 shared_preferences 的游标与上次同步时间持久化（§9.2）。
class SyncCursorStoreImpl implements SyncCursorStore {
  SyncCursorStoreImpl({SharedPreferences? preferences})
      : _preferences = preferences;

  static const String _cursorKey = 'sync_cursor';
  static const String _lastSyncAtKey = 'sync_last_at';

  SharedPreferences? _preferences;

  Future<SharedPreferences> _getPrefs() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  @override
  Future<int> read() async {
    final prefs = await _getPrefs();
    return prefs.getInt(_cursorKey) ?? 0;
  }

  @override
  Future<void> write(int cursor) async {
    final prefs = await _getPrefs();
    await prefs.setInt(_cursorKey, cursor);
  }

  @override
  Future<DateTime?> readLastSyncAt() async {
    final prefs = await _getPrefs();
    final iso = prefs.getString(_lastSyncAtKey);
    if (iso == null || iso.isEmpty) {
      return null;
    }
    try {
      return DateTime.tryParse(iso)?.toLocal();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeLastSyncAt(DateTime at) async {
    final prefs = await _getPrefs();
    await prefs.setString(_lastSyncAtKey, at.toUtc().toIso8601String());
  }
}
