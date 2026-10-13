import 'dart:convert';

import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/data/ai/openai_client.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/domain/ai/ai_client.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const AIProviderProfile _profile = AIProviderProfile(
  name: '默认',
  baseUrl: 'https://example.com/v1',
  model: 'gpt-test',
  temperature: 0.7,
  maxTokens: 1000,
);

AIRequest _request() => const AIRequest(
      messages: <AIChatMessage>[
        AIChatMessage(role: AIChatRole.user, content: '你好'),
      ],
      profile: _profile,
    );

String _successBody({String content = '你好'}) => jsonEncode(<String, Object?>{
      'model': 'gpt-test',
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': content},
          'finish_reason': 'stop',
        },
      ],
    });

/// 带 UTF-8 声明头，避免 http.Response 默认按 latin1 编码中文失败。
const Map<String, String> _jsonUtf8Headers = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

PlanRequest _planRequest() => const PlanRequest(
      conversationId: 'conv-1',
      sourceMessageId: 'msg-1',
      request: '帮我安排明天的工作',
      profile: _profile,
    );

/// 把模型返回的计划内容包进 OpenAI 兼容响应信封。
String _planBody(String content, {String model = 'gpt-test'}) =>
    jsonEncode(<String, Object?>{
      'model': model,
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': content},
          'finish_reason': 'stop',
        },
      ],
    });

void main() {
  test('成功响应解析出内容、模型与结束原因', () async {
    final client = OpenAIClient(
      apiKeyProvider: () => 'secret-key',
      httpClient: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.com/v1/chat/completions',
        );
        expect(request.headers['Authorization'], 'Bearer secret-key');
        return http.Response(
          _successBody(content: ' 你好 '),
          200,
          headers: _jsonUtf8Headers,
        );
      }),
    );

    final result = await client.complete(_request());
    expect(result.content, '你好');
    expect(result.model, 'gpt-test');
    expect(result.finishReason, 'stop');
  });

  test('非 2xx 抛 AIProviderException 并保留状态码', () async {
    final client = OpenAIClient(
      apiKeyProvider: () => 'secret-key',
      httpClient: MockClient(
        (request) async => http.Response('unauthorized', 401),
      ),
    );

    await expectLater(
      client.complete(_request()),
      throwsA(
        isA<AIProviderException>()
            .having((error) => error.statusCode, 'statusCode', 401),
      ),
    );
  });

  test('响应体非法 JSON 抛 AIProviderException', () async {
    final client = OpenAIClient(
      apiKeyProvider: () => 'secret-key',
      httpClient: MockClient((request) async => http.Response('not-json', 200)),
    );

    await expectLater(
      client.complete(_request()),
      throwsA(isA<AIProviderException>()),
    );
  });

  test('网络异常映射为 NetworkException', () async {
    final client = OpenAIClient(
      apiKeyProvider: () => 'secret-key',
      httpClient: MockClient((request) async {
        throw http.ClientException('连接被拒绝');
      }),
    );

    await expectLater(
      client.complete(_request()),
      throwsA(isA<NetworkException>()),
    );
  });

  test('保存新配置后即时使用新 API Key（配置更新时序，F7/F8）', () async {
    final store = MemorySettingsStore();
    final captured = <String?>[];
    final client = OpenAIClient(
      apiKeyProvider: () => store.apiKey,
      httpClient: MockClient((request) async {
        captured.add(request.headers['Authorization']);
        return http.Response(_successBody(), 200, headers: _jsonUtf8Headers);
      }),
    );

    await client.complete(_request());
    expect(captured.single, 'Bearer ');

    await store.saveProfile(_profile.copyWith(apiKeyRef: 'new-key'));
    await client.complete(_request());
    expect(captured.last, 'Bearer new-key');
  });

  group('proposePlan', () {
    test('合法 JSON 返回 awaitingConfirmation 计划并物化变更', () async {
      final captured = <http.Request>[];
      final content = jsonEncode(<String, Object?>{
        'intent': '安排明天工作',
        'tasks': <Object?>[
          <String, Object?>{
            'title': '写周报',
            'description': '总结本周进展',
            'priority': 'High',
            'dueAt': '2026-01-02T09:00:00+08:00',
          },
          <String, Object?>{'title': '预约会议'},
        ],
      });
      final client = OpenAIClient(
        apiKeyProvider: () => 'secret-key',
        httpClient: MockClient((request) async {
          captured.add(request);
          return http.Response(
            _planBody(content),
            200,
            headers: _jsonUtf8Headers,
          );
        }),
      );

      final plan = await client.proposePlan(_planRequest());

      // 请求采用 request.profile 的 model/baseUrl，temperature 固定 0.2。
      final body = jsonDecode(captured.single.body) as Map<String, Object?>;
      expect(
        captured.single.url.toString(),
        'https://example.com/v1/chat/completions',
      );
      expect(body['model'], 'gpt-test');
      expect(body['temperature'], 0.2);
      expect(body['max_tokens'], 1000);
      final messages = body['messages'] as List<Object?>;
      expect((messages.first as Map<String, Object?>)['role'], 'system');
      expect((messages.last as Map<String, Object?>)['role'], 'user');
      expect(
        (messages.last as Map<String, Object?>)['content'],
        '帮我安排明天的工作',
      );

      // 计划元数据。
      expect(plan.status, AIPlanStatus.awaitingConfirmation);
      expect(plan.conversationId, 'conv-1');
      expect(plan.sourceMessageId, 'msg-1');
      expect(plan.aiModel, 'gpt-test');
      expect(plan.promptVersion, OpenAIClient.planPromptVersion);
      expect(plan.version, 1);
      expect(plan.changes.length, 2);

      // 变更物化：priority 归一化、dueAt 转本地 ISO。
      final first = plan.changes[0];
      expect(first.type, AIPlanChangeType.createTask);
      expect(first.payload['title'], '写周报');
      expect(first.payload['description'], '总结本周进展');
      expect(first.payload['priority'], 'high');
      expect(
        first.payload['dueAt'],
        DateTime.parse('2026-01-02T09:00:00+08:00')
            .toLocal()
            .toIso8601String(),
      );

      final second = plan.changes[1];
      expect(second.payload['title'], '预约会议');
      expect(second.payload['priority'], 'medium');
      expect(second.payload['dueAt'], isNull);
      expect(second.payload.containsKey('description'), isFalse);
    });

    test('空 tasks 返回 changes 为空列表', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': '无法拆解',
        'tasks': <Object?>[],
      });
      final client = OpenAIClient(
        apiKeyProvider: () => 'secret-key',
        httpClient: MockClient(
          (request) async =>
              http.Response(_planBody(content), 200, headers: _jsonUtf8Headers),
        ),
      );

      final plan = await client.proposePlan(_planRequest());
      expect(plan.status, AIPlanStatus.awaitingConfirmation);
      expect(plan.changes, isEmpty);
    });

    for (final testCase in <({String name, Object? plan})>[
      (name: '内容非 JSON', plan: null),
      (name: '非对象', plan: <Object?>['not', 'a', 'map']),
      (name: 'intent 缺失', plan: <String, Object?>{'tasks': <Object?>[]}),
      (name: 'tasks 缺失', plan: <String, Object?>{'intent': 'x'}),
      (
        name: '元素缺 title',
        plan: <String, Object?>{
          'intent': 'x',
          'tasks': <Object?>[
            <String, Object?>{'priority': 'low'},
          ],
        },
      ),
      (
        name: '未知 priority',
        plan: <String, Object?>{
          'intent': 'x',
          'tasks': <Object?>[
            <String, Object?>{'title': 't', 'priority': 'huge'},
          ],
        },
      ),
      (
        name: '非法 dueAt',
        plan: <String, Object?>{
          'intent': 'x',
          'tasks': <Object?>[
            <String, Object?>{'title': 't', 'dueAt': 'not-a-date'},
          ],
        },
      ),
    ]) {
      test('非法计划（${testCase.name}）抛 PlanValidationException', () async {
        final content =
            testCase.plan == null ? 'not-json' : jsonEncode(testCase.plan);
        final client = OpenAIClient(
          apiKeyProvider: () => 'secret-key',
          httpClient: MockClient(
            (request) async => http.Response(
              _planBody(content),
              200,
              headers: _jsonUtf8Headers,
            ),
          ),
        );

        await expectLater(
          client.proposePlan(_planRequest()),
          throwsA(isA<PlanValidationException>()),
        );
      });
    }

    test('非 2xx 抛 AIProviderException 并保留状态码', () async {
      final client = OpenAIClient(
        apiKeyProvider: () => 'secret-key',
        httpClient: MockClient(
          (request) async => http.Response('unauthorized', 401),
        ),
      );

      await expectLater(
        client.proposePlan(_planRequest()),
        throwsA(
          isA<AIProviderException>()
              .having((error) => error.statusCode, 'statusCode', 401),
        ),
      );
    });
  });
}
