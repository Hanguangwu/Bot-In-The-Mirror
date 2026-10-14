import '../../domain/sync/sync_credential_store.dart';

/// 内存版凭证存储（测试用）。
class MemorySyncCredentialStore implements SyncCredentialStore {
  String? _token;
  String? _workspaceId;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveToken(String token) async {
    _token = token;
  }

  @override
  Future<String?> readWorkspaceId() async => _workspaceId;

  @override
  Future<void> saveWorkspaceId(String workspaceId) async {
    _workspaceId = workspaceId;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _workspaceId = null;
  }

  void reset() {
    _token = null;
    _workspaceId = null;
  }
}
