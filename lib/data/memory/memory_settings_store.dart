import 'dart:async';

import '../../core/config/app_config.dart';
import '../../domain/entities/ai_provider.dart';
import '../../domain/repositories/settings_store.dart';

/// 内存设置存储。
///
/// 明文 API Key 独立存放于内存，不再从 [AIProviderProfile.apiKeyRef] 读取。
/// 兼容过渡：若初始 profile 携带 apiKeyRef，则同步至独立字段。
class MemorySettingsStore implements SettingsStore {
  /// 创建内存设置存储，可选注入初始配置。
  MemorySettingsStore({AIProviderProfile? initialProfile})
      : _profile = initialProfile ?? _defaultProfile(),
        _apiKey = initialProfile?.apiKeyRef ?? '';

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
  String _apiKey;
  String _syncBaseUrl = AppConfig.defaultSyncBaseUrl;

  @override
  AIProviderProfile get currentProfile => _profile;

  /// 运行时明文 API Key，供 `AIClient` 读取；绝不落库。
  @override
  String get apiKey => _apiKey;

  @override
  Stream<AIProviderProfile> watchProfile() => _controller.stream;

  @override
  Future<void> saveProfile(AIProviderProfile profile) async {
    _profile = profile;
    if (profile.apiKeyRef != null && profile.apiKeyRef!.isNotEmpty) {
      // 兼容 M0 设置页把 key 写进 apiKeyRef 的写法；
      // Lane-C 起设置页改走 saveApiKey，profile.apiKeyRef 恒 null。
      _apiKey = profile.apiKeyRef!;
    }
    if (!_controller.isClosed) {
      _controller.add(profile);
    }
  }

  @override
  Future<void> saveApiKey(String apiKey) async {
    _apiKey = apiKey;
  }

  /// 同步服务基址；空串表示未配置（§9.3）。
  @override
  String get syncBaseUrl => _syncBaseUrl;

  @override
  Future<void> saveSyncBaseUrl(String url) async {
    _syncBaseUrl = url;
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _controller.close();
  }
}
