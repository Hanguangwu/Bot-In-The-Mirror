import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
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

  /// 任务拆解系统提示版本；落库用于回溯（§6.1/§10）。
  static const String planPromptVersion = 'm2a-plan-v1';

  /// 任务拆解系统提示（§10 原文，中文，要求只输出 JSON）。
  ///
  /// M2a 起支持 `scheduleTask`：额外输出 `schedules` 数组（`title` 必填、
  /// `startAt`/`endAt` 为 ISO8601、`note` 可选）；`tasks` 语义不变。
  static const String planSystemPrompt = '你是「Alice」的个人执行助手。请把用户最近的需求拆解为任务清单与可选日程，只返回 JSON：\n'
      '{"intent":"一句话概括意图","tasks":[{"title":"任务标题","description":"可选说明","priority":"low|medium|high|urgent","dueAt":"可选，ISO8601 日期或 null"}],"schedules":[{"title":"日程标题","startAt":"ISO8601 开始时间","endAt":"ISO8601 结束时间","note":"可选备注"}]}\n'
      '规则：1) 只输出 JSON，不要任何额外文字；2) 无法拆解时返回空 tasks 与空 schedules，并用 intent 说明原因；\n'
      '3) 不要编造用户未提出的截止时间；4) 仅在用户明确要求安排时间时才输出 schedules，且 endAt 必须晚于 startAt；\n'
      '5) 不需要日程时可省略 schedules 或返回空数组。';

  /// 合法优先级枚举（小写）。
  static const Set<String> _planPriorities = <String>{
    'low',
    'medium',
    'high',
    'urgent',
  };

  final String Function() _apiKeyProvider;
  final http.Client _httpClient;

  @override
  Future<AIResult> complete(AIRequest request) async {
    final profile = request.profile;
    final body = await _postChatCompletion(
      profile: profile,
      messages: request.messages,
      temperature: profile.temperature,
    );
    return _parseResult(body, profile.model);
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
    final profile = request.profile;
    final body = await _postChatCompletion(
      profile: profile,
      messages: <AIChatMessage>[
        const AIChatMessage(
          role: AIChatRole.system,
          content: planSystemPrompt,
        ),
        AIChatMessage(role: AIChatRole.user, content: request.request),
      ],
      // 拆解固定低温度，降低输出发散（§6.1）。
      temperature: 0.2,
    );

    final parsed = _parsePlan(body, profile.model);
    final now = DateTime.now();
    return AIPlan(
      id: generateId(),
      userId: newUserId(),
      createdAt: now,
      updatedAt: now,
      version: 1,
      deviceId: newDeviceId(),
      conversationId: request.conversationId,
      sourceMessageId: request.sourceMessageId,
      status: AIPlanStatus.awaitingConfirmation,
      aiModel: parsed.model,
      promptVersion: planPromptVersion,
      changes: parsed.changes,
    );
  }

  /// 发送一次 `/chat/completions` 请求，返回原始响应体。
  ///
  /// 网络异常抛 [NetworkException]；非 2xx 抛 [AIProviderException]。
  /// 绝不打印密钥或响应体。
  Future<String> _postChatCompletion({
    required AIProviderProfile profile,
    required List<AIChatMessage> messages,
    required double temperature,
  }) async {
    final uri = Uri.parse(
      '${_normalizeBaseUrl(profile.baseUrl)}/chat/completions',
    );
    final payload = jsonEncode(<String, Object?>{
      'model': profile.model,
      'messages': messages
          .map(
            (message) => <String, String>{
              'role': _roleName(message.role),
              'content': message.content,
            },
          )
          .toList(),
      'temperature': temperature,
      'max_tokens': profile.maxTokens,
      // 不处理流式响应，显式关闭。
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

    return response.body;
  }

  /// 从响应信封中取出模型名与 message 内容，再解析为计划变更。
  ///
  /// 信封或内容 JSON 非法、schema 不符合 §6.2 时一律抛
  /// [PlanValidationException]；空 `tasks` 返回空变更列表（由用例层做 null 语义）。
  ({String model, List<AIPlanChange> changes}) _parsePlan(
    String raw,
    String fallbackModel,
  ) {
    final Object? envelope;
    try {
      envelope = jsonDecode(raw);
    } catch (error) {
      throw PlanValidationException('AI 返回的任务计划格式无效', cause: error);
    }
    var model = fallbackModel;
    var content = '';
    if (envelope is Map<String, dynamic>) {
      model = (envelope['model'] as String?) ?? fallbackModel;
      final choices = envelope['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, dynamic>) {
          final message = first['message'];
          if (message is Map<String, dynamic>) {
            content = (message['content'] as String? ?? '').trim();
          }
        }
      }
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (error) {
      throw PlanValidationException('AI 返回的任务计划格式无效', cause: error);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }

    // 规则 2：intent 必须为非空字符串（不落库，仅用于校验）。
    final intent = decoded['intent'];
    if (intent is! String) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }

    // 规则 3：tasks 必须为数组。
    final rawTasks = decoded['tasks'];
    if (rawTasks is! List) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }

    final changes = <AIPlanChange>[];
    for (final item in rawTasks) {
      if (item is! Map<String, dynamic>) {
        throw const PlanValidationException('AI 返回的任务计划格式无效');
      }
      final title = item['title'];
      if (title is! String || title.isEmpty) {
        throw const PlanValidationException('AI 返回的任务计划格式无效');
      }

      // 规则 4：priority 缺失默认 medium；非缺失先归一化再校验。
      final priorityRaw = item['priority'];
      final String priority;
      if (priorityRaw == null) {
        priority = 'medium';
      } else if (priorityRaw is String &&
          _planPriorities.contains(priorityRaw.toLowerCase())) {
        priority = priorityRaw.toLowerCase();
      } else {
        throw const PlanValidationException('AI 返回的任务计划格式无效');
      }

      // 规则 5：dueAt 缺失/null 合法；非空须为可解析 ISO8601，解析后 toLocal。
      final dueAtRaw = item['dueAt'];
      final String? dueAt;
      if (dueAtRaw == null) {
        dueAt = null;
      } else if (dueAtRaw is String) {
        final parsedDueAt = DateTime.tryParse(dueAtRaw);
        if (parsedDueAt == null) {
          throw const PlanValidationException('AI 返回的任务计划格式无效');
        }
        dueAt = parsedDueAt.toLocal().toIso8601String();
      } else {
        throw const PlanValidationException('AI 返回的任务计划格式无效');
      }

      final payload = <String, Object?>{
        'title': title,
        'priority': priority,
        'dueAt': dueAt,
      };
      final description = item['description'];
      if (description is String) {
        payload['description'] = description;
      }
      changes.add(
        AIPlanChange(type: AIPlanChangeType.createTask, payload: payload),
      );
    }

    // 规则 6（§10）：schedules 可选；缺省视为空。每项校验 title 非空、
    // startAt/endAt 可解析且 endAt > startAt（解析后比较），否则判非法。
    final rawSchedules = decoded['schedules'];
    if (rawSchedules != null) {
      if (rawSchedules is! List) {
        throw const PlanValidationException('AI 返回的任务计划格式无效');
      }
      for (final item in rawSchedules) {
        if (item is! Map<String, dynamic>) {
          throw const PlanValidationException('AI 返回的任务计划格式无效');
        }
        final title = item['title'];
        if (title is! String || title.isEmpty) {
          throw const PlanValidationException('AI 返回的任务计划格式无效');
        }
        final startAt = _parsePlanDateTime(item['startAt']);
        final endAt = _parsePlanDateTime(item['endAt']);
        if (startAt == null || endAt == null || !endAt.isAfter(startAt)) {
          throw const PlanValidationException('AI 返回的任务计划格式无效');
        }
        final payload = <String, Object?>{
          'title': title,
          'startAt': startAt.toLocal().toIso8601String(),
          'endAt': endAt.toLocal().toIso8601String(),
        };
        final note = item['note'];
        if (note is String) {
          payload['note'] = note;
        }
        changes.add(
          AIPlanChange(type: AIPlanChangeType.scheduleTask, payload: payload),
        );
      }
    }

    return (model: model, changes: changes);
  }

  /// 解析计划中的 ISO8601 时间字符串；缺失、非字符串或不可解析返回 null。
  DateTime? _parsePlanDateTime(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value);
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
