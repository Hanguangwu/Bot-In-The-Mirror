/// 应用级默认配置常量。
///
/// 这些值用于首次启动或未配置时的兜底；用户可在设置页覆盖（M1 起持久化）。
abstract final class AppConfig {
  /// 默认的 OpenAI 兼容接口地址。
  static const String defaultBaseUrl = 'https://api.chatanywhere.tech/v1';

  /// 默认模型名。
  static const String defaultModel = 'gpt-3.5-turbo';

  /// 默认采样温度。
  static const double defaultTemperature = 0.7;

  /// 默认最大输出 token 数。
  static const int defaultMaxTokens = 2000;

  /// 应用名称。
  static const String appName = 'Chat with Alice';

  /// 应用版本（与 `pubspec.yaml` 保持一致）。
  static const String appVersion = '1.0.0';

  /// 常见模型候选列表（静态兜底，动态获取是 M1）。
  static const List<String> commonModels = <String>[
    'gpt-3.5-turbo',
    'gpt-4',
    'gpt-4o-mini',
    'gpt-4o',
  ];

  /// 默认同步服务地址；空串 = 未启用（同步引擎内部空转，不触网）。
  static const String defaultSyncBaseUrl = '';

  /// 单批推送操作上限（§5.2/§6.1）。
  static const int syncPushBatchSize = 100;

  /// 单次拉取条数上限（§5.3/§6.1）。
  static const int syncPullLimit = 200;

  /// 单次同步的推送循环最大轮数（§6.1，A2）。
  static const int maxPushPasses = 5;

  /// 单次同步的拉取分页最大轮数（§6.1）。
  static const int maxPullPages = 10;

  /// 自动同步退避基数（§6.1/§9.3）。
  static const Duration syncBackoffBase = Duration(seconds: 30);

  /// 自动同步退避上限（§6.1/§9.3）。
  static const Duration syncBackoffMax = Duration(minutes: 10);
}

/// AI 待确认计划的自动过期时长（M2a §9，默认 48 小时）。
///
/// 读取时惰性判断：`createdAt` 距今超过该时长即标记 expired。
const Duration aiPlanExpireAfter = Duration(hours: 48);
