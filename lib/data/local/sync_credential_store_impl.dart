import 'package:shared_preferences/shared_preferences.dart';

import '../storage/secret_store.dart';
import '../../domain/sync/sync_credential_store.dart';

/// 同步凭证持久化：token → 安全存储，workspaceId → shared_preferences（§9.1）。
class SyncCredentialStoreImpl implements SyncCredentialStore {
  SyncCredentialStoreImpl({
    required SecretStore secretStore,
    SharedPreferences? preferences,
  })  : _secretStore = secretStore,
        _preferences = preferences;

  static const String _tokenKey = 'sync_token';
  static const String _workspaceIdKey = 'sync_workspace_id';

  final SecretStore _secretStore;
  SharedPreferences? _preferences;

  Future<SharedPreferences> _getPrefs() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  @override
  Future<String?> readToken() async {
    return _secretStore.read(_tokenKey);
  }

  @override
  Future<void> saveToken(String token) async {
    await _secretStore.write(_tokenKey, token);
  }

  @override
  Future<String?> readWorkspaceId() async {
    final prefs = await _getPrefs();
    return prefs.getString(_workspaceIdKey);
  }

  @override
  Future<void> saveWorkspaceId(String workspaceId) async {
    final prefs = await _getPrefs();
    await prefs.setString(_workspaceIdKey, workspaceId);
  }

  @override
  Future<void> clear() async {
    await _secretStore.delete(_tokenKey);
    final prefs = await _getPrefs();
    await prefs.remove(_workspaceIdKey);
  }
}
