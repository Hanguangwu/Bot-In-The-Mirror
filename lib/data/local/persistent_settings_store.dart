import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../domain/entities/ai_provider.dart';
import '../../domain/repositories/settings_store.dart';
import '../storage/secret_store.dart';

/// 持久化设置存储：非敏感 profile 落 shared_preferences，API Key 落 [SecretStore]。
///
/// 语义保证：`currentProfile`/`apiKey` 仅同步读取内存缓存，**绝不在 build 中
/// 发起异步持久化读**；持久化加载集中在启动时调用一次的 [load]。
class PersistentSettingsStore implements SettingsStore {
  /// 创建存储；[secretStore] 承载明文 API Key，[preferences] 可注入便于测试。
  PersistentSettingsStore({
    required SecretStore secretStore,
    SharedPreferences? preferences,
  })  : _secretStore = secretStore,
        _preferences = preferences;

  /// 非敏感配置的 shared_preferences key。
  static const String profileKey = 'ai_provider_profile';

  /// API Key 在 [SecretStore] 中的 key。
  static const String apiKeyKey = 'ai_api_key';

  /// 同步服务基址的 shared_preferences key。
  static const String syncBaseUrlKey = 'sync_base_url';

  final SecretStore _secretStore;
  SharedPreferences? _preferences;

  final StreamController<AIProviderProfile> _controller =
      StreamController<AIProviderProfile>.broadcast();
  AIProviderProfile _profile = _defaultProfile();
  String _apiKey = '';
  String _syncBaseUrl = AppConfig.defaultSyncBaseUrl;

  /// 默认配置（与 `AppConfig` 及 `MemorySettingsStore` 一致）。
  static AIProviderProfile _defaultProfile() => const AIProviderProfile(
        name: '默认',
        baseUrl: AppConfig.defaultBaseUrl,
        model: AppConfig.defaultModel,
        temperature: AppConfig.defaultTemperature,
        maxTokens: AppConfig.defaultMaxTokens,
      );

  @override
  AIProviderProfile get currentProfile => _profile;

  @override
  String get apiKey => _apiKey;

  @override
  Stream<AIProviderProfile> watchProfile() => _controller.stream;

  /// 启动时加载：读 profile（缺失用默认值）与 API Key（缺失为空串）进内存缓存。
  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final raw = preferences.getString(profileKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = _decodeProfile(raw);
      if (decoded != null) {
        _profile = decoded;
      }
    }
    _apiKey = await _secretStore.read(apiKeyKey) ?? '';
    _syncBaseUrl =
        preferences.getString(syncBaseUrlKey) ?? AppConfig.defaultSyncBaseUrl;
  }

  @override
  Future<void> saveProfile(AIProviderProfile profile) async {
    _profile = profile;
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setString(profileKey, jsonEncode(_encodeProfile(profile)));
    if (!_controller.isClosed) {
      _controller.add(profile);
    }
  }

  @override
  Future<void> saveApiKey(String apiKey) async {
    _apiKey = apiKey;
    await _secretStore.write(apiKeyKey, apiKey);
  }

  @override
  String get syncBaseUrl => _syncBaseUrl;

  @override
  Future<void> saveSyncBaseUrl(String url) async {
    _syncBaseUrl = url;
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setString(syncBaseUrlKey, url);
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _controller.close();
  }

  /// 序列化非敏感字段；`capabilities` 存枚举名列表（S10）。apiKeyRef 不持久化。
  Map<String, Object?> _encodeProfile(AIProviderProfile profile) =>
      <String, Object?>{
        'name': profile.name,
        'baseUrl': profile.baseUrl,
        'model': profile.model,
        'temperature': profile.temperature,
        'maxTokens': profile.maxTokens,
        'streamEnabled': profile.streamEnabled,
        'capabilities':
            profile.capabilities.map((capability) => capability.name).toList(),
      };

  /// 反序列化；结构性错误返回 null（调用方保留默认配置），capabilities 兜底 text。
  AIProviderProfile? _decodeProfile(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final base = _defaultProfile();
    final capabilities = <AICapability>{};
    final rawCapabilities = decoded['capabilities'];
    if (rawCapabilities is List) {
      for (final item in rawCapabilities) {
        if (item is String) {
          final capability = _capabilityFromName(item);
          if (capability != null) {
            capabilities.add(capability);
          }
        }
      }
    }
    // S10：capabilities 解码兜底为 text。
    if (capabilities.isEmpty) {
      capabilities.add(AICapability.text);
    }
    final name = decoded['name'];
    final baseUrl = decoded['baseUrl'];
    final model = decoded['model'];
    final temperature = decoded['temperature'];
    final maxTokens = decoded['maxTokens'];
    final streamEnabled = decoded['streamEnabled'];
    return AIProviderProfile(
      name: name is String && name.isNotEmpty ? name : base.name,
      baseUrl: baseUrl is String && baseUrl.isNotEmpty ? baseUrl : base.baseUrl,
      model: model is String && model.isNotEmpty ? model : base.model,
      temperature: temperature is num ? temperature.toDouble() : base.temperature,
      maxTokens: maxTokens is num ? maxTokens.toInt() : base.maxTokens,
      streamEnabled: streamEnabled is bool ? streamEnabled : base.streamEnabled,
      capabilities: capabilities,
    );
  }

  AICapability? _capabilityFromName(String name) {
    for (final capability in AICapability.values) {
      if (capability.name == name) {
        return capability;
      }
    }
    return null;
  }
}
