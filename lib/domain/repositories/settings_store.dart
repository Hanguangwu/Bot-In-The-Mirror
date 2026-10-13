import '../entities/ai_provider.dart';

/// AI 提供商配置存储。
///
/// M0 为内存实现；运行时明文 API Key 只在此内存中持有，不落库。
/// M1 起：apiKeyRef 语义为安全存储引用，明文 key 仅存在于 store 独立字段。
abstract interface class SettingsStore {
  /// 当前配置（同步读取，供 UI 构建时使用）。
  AIProviderProfile get currentProfile;

  /// 运行时明文 API Key；
  /// 仅保存在内存/安全存储，绝不落库、不写日志（F8）。
  String get apiKey;

  /// 监听配置变化。
  Stream<AIProviderProfile> watchProfile();

  /// 保存配置（仅非敏感字段）。
  Future<void> saveProfile(AIProviderProfile profile);

  /// 保存 API Key（明文 key 走 SecretStore）。
  Future<void> saveApiKey(String apiKey);
}
