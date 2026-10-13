import 'dart:convert';

import 'package:chatwithalice/core/config/app_config.dart';
import 'package:chatwithalice/data/local/persistent_settings_store.dart';
import 'package:chatwithalice/data/storage/memory_secret_store.dart';
import 'package:chatwithalice/domain/entities/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // 必须在 getInstance 之前注入 mock 初值（shared_preferences 会缓存静态实例）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('load 无持久化数据时使用默认配置且 key 为空串', () async {
    final store = PersistentSettingsStore(secretStore: MemorySecretStore());
    await store.load();

    expect(store.apiKey, '');
    expect(store.currentProfile.model, AppConfig.defaultModel);
    expect(store.currentProfile.baseUrl, AppConfig.defaultBaseUrl);
    expect(store.currentProfile.temperature, AppConfig.defaultTemperature);
    expect(store.currentProfile.maxTokens, AppConfig.defaultMaxTokens);
    expect(store.currentProfile.capabilities, <AICapability>{AICapability.text});
    store.dispose();
  });

  test('saveProfile 往返持久化全部非敏感字段（含 capabilities）', () async {
    final secret = MemorySecretStore();
    final store = PersistentSettingsStore(secretStore: secret);
    await store.load();

    const profile = AIProviderProfile(
      name: '本地模型',
      baseUrl: 'https://local.example.com/v1',
      model: 'local-model',
      temperature: 0.25,
      maxTokens: 1234,
      streamEnabled: true,
      capabilities: <AICapability>{
        AICapability.text,
        AICapability.vision,
        AICapability.tools,
      },
    );
    await store.saveProfile(profile);

    // 新实例从 shared_preferences 读回，验证确实持久化（而非仅内存缓存）。
    final reloaded = PersistentSettingsStore(secretStore: secret);
    await reloaded.load();
    final loaded = reloaded.currentProfile;
    expect(loaded.name, '本地模型');
    expect(loaded.baseUrl, 'https://local.example.com/v1');
    expect(loaded.model, 'local-model');
    expect(loaded.temperature, 0.25);
    expect(loaded.maxTokens, 1234);
    expect(loaded.streamEnabled, isTrue);
    expect(loaded.capabilities, <AICapability>{
      AICapability.text,
      AICapability.vision,
      AICapability.tools,
    });

    store.dispose();
    reloaded.dispose();
  });

  test('saveProfile 通过 watchProfile 广播新配置', () async {
    final store = PersistentSettingsStore(secretStore: MemorySecretStore());
    await store.load();

    final emitted = <AIProviderProfile>[];
    final subscription = store.watchProfile().listen(emitted.add);

    const profile = AIProviderProfile(
      name: '新配置',
      baseUrl: 'https://x.example.com/v1',
      model: 'new-model',
      temperature: 0.5,
      maxTokens: 800,
    );
    await store.saveProfile(profile);
    await Future<void>.delayed(Duration.zero);

    expect(emitted.single.model, 'new-model');
    await subscription.cancel();
    store.dispose();
  });

  test('saveApiKey 写入 SecretStore，apiKey 即时读回并可被新实例 load', () async {
    final secret = MemorySecretStore();
    final store = PersistentSettingsStore(secretStore: secret);
    await store.load();
    expect(store.apiKey, '');

    await store.saveApiKey('sk-secret-value');
    expect(store.apiKey, 'sk-secret-value');
    // 明文确实落在注入的 SecretStore 中（建议 key 名稳定）。
    expect(
      await secret.read(PersistentSettingsStore.apiKeyKey),
      'sk-secret-value',
    );

    final reloaded = PersistentSettingsStore(secretStore: secret);
    await reloaded.load();
    expect(reloaded.apiKey, 'sk-secret-value');

    store.dispose();
    reloaded.dispose();
  });

  test('saveProfile 不清空已保存的 API Key（回填守卫，B2）', () async {
    final secret = MemorySecretStore();
    final store = PersistentSettingsStore(secretStore: secret);
    await store.load();

    await store.saveApiKey('keep-me');
    await store.saveProfile(
      const AIProviderProfile(
        name: '默认',
        baseUrl: 'https://x.example.com/v1',
        model: 'm',
        temperature: 0.7,
        maxTokens: 100,
      ),
    );

    expect(store.apiKey, 'keep-me');
    store.dispose();
  });

  test('capabilities 缺失或未知时解码兜底为 text', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersistentSettingsStore.profileKey: jsonEncode(<String, Object?>{
        'name': 'x',
        'baseUrl': 'https://x.example.com/v1',
        'model': 'm',
        'temperature': 0.5,
        'maxTokens': 100,
        'streamEnabled': false,
        'capabilities': <String>['unknown'],
      }),
    });

    final store = PersistentSettingsStore(secretStore: MemorySecretStore());
    await store.load();

    expect(store.currentProfile.capabilities, <AICapability>{AICapability.text});
    store.dispose();
  });

  test('profile JSON 非法时保留默认配置', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PersistentSettingsStore.profileKey: 'not-json',
    });

    final store = PersistentSettingsStore(secretStore: MemorySecretStore());
    await store.load();

    expect(store.currentProfile.model, AppConfig.defaultModel);
    store.dispose();
  });
}
