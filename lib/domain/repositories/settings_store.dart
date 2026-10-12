import '../entities/ai_provider.dart';

/// AI 提供商配置存储。
///
/// M0 为内存实现；运行时明文 API Key 只在此内存中持有，不落库。
abstract interface class SettingsStore {
  /// 当前配置（同步读取，供 UI 构建时使用）。
  AIProviderProfile get currentProfile;

  /// 运行时明文 API Key（由 [AIProviderProfile.apiKeyRef] 提供）；
  /// 仅保存在内存/安全存储，绝不落库、不写日志（F8）。
  String get apiKey;

  /// 监听配置变化。
  Stream<AIProviderProfile> watchProfile();

  /// 保存配置。
  Future<void> saveProfile(AIProviderProfile profile);
}
