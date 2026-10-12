import 'dart:async';

import '../../core/config/app_config.dart';
import '../../domain/entities/ai_provider.dart';
import '../../domain/repositories/settings_store.dart';

/// 内存设置存储。
///
/// M0 阶段明文 API Key 仅保存在内存（存于 [AIProviderProfile.apiKeyRef]），
/// 不写入数据库；后续版本改为平台安全存储引用。
class MemorySettingsStore implements SettingsStore {
  /// 创建内存设置存储，可选注入初始配置。
  MemorySettingsStore({AIProviderProfile? initialProfile})
      : _profile = initialProfile ?? _defaultProfile();

  static AIProviderProfile _defaultProfile() => const AIProviderProfile(
        name: '默认',
        baseUrl: AppConfig.defaultBaseUrl,
        model: AppConfig.defaultModel,
        temperature: AppConfig.defaultTemperature,
        maxTokens: AppConfig.defaultMaxTokens,
      );

  final StreamController<AIProviderProfile> _controller =
      StreamController<AIProviderProfile>.broadcast();
  AIProviderProfile _profile;

  @override
  AIProviderProfile get currentProfile => _profile;

  /// 运行时明文 API Key，供 `AIClient` 读取；绝不落库。
  @override
  String get apiKey => _profile.apiKeyRef ?? '';

  @override
  Stream<AIProviderProfile> watchProfile() => _controller.stream;

  @override
  Future<void> saveProfile(AIProviderProfile profile) async {
    _profile = profile;
    if (!_controller.isClosed) {
      _controller.add(profile);
    }
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _controller.close();
  }
}
