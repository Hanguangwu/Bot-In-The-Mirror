import '../entities/ai_plan.dart';
import '../entities/ai_provider.dart';

/// AI 对话角色。
enum AIChatRole {
  /// 系统提示。
  system,

  /// 用户输入。
  user,

  /// 助手回复。
  assistant,
}

/// 发送给模型的单条对话消息。
class AIChatMessage {
  /// 创建对话消息。
  const AIChatMessage({required this.role, required this.content});

  /// 角色。
  final AIChatRole role;

  /// 文本内容。
  final String content;
}

/// 一次补全请求。
class AIRequest {
  /// 创建补全请求。
  const AIRequest({required this.messages, required this.profile});

  /// 对话历史（按时间正序）。
  final List<AIChatMessage> messages;

  /// 使用的提供商配置。
  final AIProviderProfile profile;
}

/// 一次补全结果。
class AIResult {
  /// 创建补全结果。
  const AIResult({required this.content, required this.model, this.finishReason});

  /// 回复文本。
  final String content;

  /// 实际使用的模型名。
  final String model;

  /// 结束原因（如 `stop` / `length`）。
  final String? finishReason;
}

/// AI 计划拆解请求（M1）。
class PlanRequest {
  /// 创建计划请求。
  const PlanRequest({
    required this.conversationId,
    required this.sourceMessageId,
    required this.request,
    required this.profile,
  });

  /// 来源会话 ID。
  final String conversationId;

  /// 触发拆解的消息 ID。
  final String sourceMessageId;

  /// 用户原始请求文本。
  final String request;

  /// 使用的提供商配置（B1：拆解请求自带 profile）。
  final AIProviderProfile profile;
}

/// AI 客户端接口。UI 依赖此接口，不直接依赖 HTTP 或具体模型。
abstract interface class AIClient {
  /// 发送对话并获取补全结果。
  Future<AIResult> complete(AIRequest request);

  /// 测试连接（设置页「测试连接」）。
  Future<AIResult> testConnection(AIProviderProfile profile);

  /// 生成结构化任务计划；M1 实现，M0 抛 `AppException`（暂未支持）。
  Future<AIPlan> proposePlan(PlanRequest request);
}
