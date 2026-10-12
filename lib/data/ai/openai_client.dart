import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/app_exception.dart';
import '../../domain/ai/ai_client.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/ai_provider.dart';

/// `AIClient` 的 OpenAI 兼容实现。
///
/// 密钥通过 [apiKeyProvider] 延迟获取（来自内存 SettingsStore）；日志与异常
/// 绝不打印密钥或完整响应体。
class OpenAIClient implements AIClient {
  /// 创建 OpenAI 兼容客户端。
  OpenAIClient({
    required String Function() apiKeyProvider,
    http.Client? httpClient,
  })  : _apiKeyProvider = apiKeyProvider,
        _httpClient = httpClient ?? http.Client();

  final String Function() _apiKeyProvider;
  final http.Client _httpClient;

  @override
  Future<AIResult> complete(AIRequest request) async {
    final profile = request.profile;
    final uri = Uri.parse(
      '${_normalizeBaseUrl(profile.baseUrl)}/chat/completions',
    );
    final payload = jsonEncode(<String, Object?>{
      'model': profile.model,
      'messages': request.messages
          .map(
            (message) => <String, String>{
              'role': _roleName(message.role),
              'content': message.content,
            },
          )
          .toList(),
      'temperature': profile.temperature,
      'max_tokens': profile.maxTokens,
      // M0 不处理流式响应，显式关闭。
      'stream': false,
    });

    final http.Response response;
    try {
      response = await _httpClient.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_apiKeyProvider()}',
        },
        body: payload,
      );
    } catch (error) {
      throw NetworkException('网络连接失败，请检查网络后重试', cause: error);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AIProviderException(
        'AI 服务返回错误（${response.statusCode}）',
        statusCode: response.statusCode,
        body: response.body,
      );
    }

    return _parseResult(response.body, profile.model);
  }

  @override
  Future<AIResult> testConnection(AIProviderProfile profile) {
    return complete(
      AIRequest(
        messages: const <AIChatMessage>[
          AIChatMessage(role: AIChatRole.user, content: 'ping'),
        ],
        profile: profile,
      ),
    );
  }

  @override
  Future<AIPlan> proposePlan(PlanRequest request) async {
    throw const UnsupportedException('任务拆解将在下一阶段（M1）提供');
  }

  /// 解析 OpenAI 兼容响应；结构异常时抛 [AIProviderException]。
  AIResult _parseResult(String raw, String fallbackModel) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>?;
      final first = choices != null && choices.isNotEmpty
          ? choices.first as Map<String, dynamic>
          : null;
      final message = first?['message'] as Map<String, dynamic>?;
      final content = (message?['content'] as String? ?? '').trim();
      return AIResult(
        content: content,
        model: (decoded['model'] as String?) ?? fallbackModel,
        finishReason: first?['finish_reason'] as String?,
      );
    } catch (error) {
      throw AIProviderException('AI 返回内容无法解析', cause: error);
    }
  }

  String _roleName(AIChatRole role) {
    switch (role) {
      case AIChatRole.system:
        return 'system';
      case AIChatRole.user:
        return 'user';
      case AIChatRole.assistant:
        return 'assistant';
    }
  }

  String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
