/// 同步凭证持久化接缝（§9.1）。
///
/// 生产实现：token → 平台安全存储（`SecretStore`，键 `sync_token`）；
/// `workspaceId` → shared_preferences（键 `sync_workspace_id`）。测试用内存实现。
/// **token 明文不得落库或写入日志。**
abstract interface class SyncCredentialStore {
  /// 读取 token；未注册返回 null。
  Future<String?> readToken();

  /// 保存 token（明文入安全存储）。
  Future<void> saveToken(String token);

  /// 读取匿名工作区 ID；未注册返回 null。
  Future<String?> readWorkspaceId();

  /// 保存匿名工作区 ID。
  Future<void> saveWorkspaceId(String workspaceId);

  /// 清除全部凭证（退出同步/撤销设备）。
  Future<void> clear();
}
