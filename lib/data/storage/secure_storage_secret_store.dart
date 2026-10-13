import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/errors/app_exception.dart';
import 'secret_store.dart';

/// 基于平台安全存储（Android Keystore / iOS Keychain）的 [SecretStore]。
///
/// key 统一加前缀 [prefix]，避免与其他应用的条目冲突。平台读写失败时向上抛
/// [StorageException]（设置页据此展示「安全存储不可用」，不泄露底层细节）。
///
/// 注意：构造本类不会读取平台通道；平台访问只发生在 [read]/[write]/[delete]。
class SecureStorageSecretStore implements SecretStore {
  /// 创建安全存储适配；可注入 [storage] 便于测试。
  SecureStorageSecretStore({
    FlutterSecureStorage? storage,
    this.prefix = 'chatwithalice.',
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 统一的 key 前缀。
  final String prefix;

  String _key(String key) => '$prefix$key';

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: _key(key));
    } catch (error) {
      throw StorageException('安全存储不可用', cause: error);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: _key(key), value: value);
    } catch (error) {
      throw StorageException('安全存储不可用', cause: error);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: _key(key));
    } catch (error) {
      throw StorageException('安全存储不可用', cause: error);
    }
  }
}
