/// 平台安全存储适配接口。
///
/// UI 与用例不直接依赖本接口；明文密钥不得落普通数据库、不得写入日志（F8）。
/// 生产环境使用 [SecureStorageSecretStore]（Android Keystore / iOS Keychain），
/// 测试与无平台通道场景使用 `MemorySecretStore`。
abstract interface class SecretStore {
  /// 读取指定 key 的明文值；不存在返回 null。
  Future<String?> read(String key);

  /// 写入（或覆盖）指定 key 的明文值。
  Future<void> write(String key, String value);

  /// 删除指定 key。
  Future<void> delete(String key);
}
