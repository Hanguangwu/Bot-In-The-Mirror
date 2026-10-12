/// AI 能力标签。
enum AICapability {
  /// 文本对话。
  text,

  /// 视觉识别。
  vision,

  /// 工具调用。
  tools,
}

/// AI 提供商配置（设备本地值对象）。
///
/// 刻意**不继承** `SyncableEntity`：它属于设备本地配置，不参与多设备同步。
/// 运行时明文 API Key 只保存在内存 [SettingsStore] 中；此处仅保留安全存储引用
/// [apiKeyRef]，绝不落库。
class AIProviderProfile {
  /// 创建 AI 提供商配置。
  const AIProviderProfile({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    required this.maxTokens,
    this.streamEnabled = false,
    this.capabilities = const <AICapability>{AICapability.text},
    this.apiKeyRef,
  });

  /// 提供商显示名称。
  final String name;

  /// OpenAI 兼容接口地址。
  final String baseUrl;

  /// 模型名。
  final String model;

  /// 采样温度。
  final double temperature;

  /// 最大输出 token 数。
  final int maxTokens;

  /// 是否启用流式输出。
  final bool streamEnabled;

  /// 声明支持的能力。
  final Set<AICapability> capabilities;

  /// 安全存储中的密钥引用；明文 key 不在此处。
  final String? apiKeyRef;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  AIProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
    bool? streamEnabled,
    Set<AICapability>? capabilities,
    String? apiKeyRef,
  }) {
    return AIProviderProfile(
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      streamEnabled: streamEnabled ?? this.streamEnabled,
      capabilities: capabilities ?? this.capabilities,
      apiKeyRef: apiKeyRef ?? this.apiKeyRef,
    );
  }
}
