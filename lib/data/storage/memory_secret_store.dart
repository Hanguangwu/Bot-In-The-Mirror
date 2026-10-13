import 'secret_store.dart';

/// 内存安全存储：测试与无平台通道场景使用。
///
/// 行为与 [SecureStorageSecretStore] 一致，但不触碰任何平台 API。
class MemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
