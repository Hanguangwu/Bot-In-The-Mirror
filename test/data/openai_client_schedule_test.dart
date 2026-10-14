import 'dart:convert';

import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/data/ai/openai_client.dart';
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

PlanRequest _planRequest() => const PlanRequest(
      conversationId: 'conv-1',
      sourceMessageId: 'msg-1',
      request: '帮我安排明天的工作',
      profile: _profile,
    );

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

const Map<String, String> _jsonUtf8Headers = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

void main() {
  group('proposePlan scheduleTask', () {
    test('解析合法 scheduleTask：endAt>startAt，note 可选', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': '安排评审',
        'tasks': <Object?>[],
        'schedules': <Object?>[
          <String, Object?>{
            'title': '评审会',
            'startAt': '2026-05-01T09:00:00+08:00',
            'endAt': '2026-05-01T10:00:00+08:00',
            'note': '会议室A',
          },
        ],
      });
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

      final plan = await client.proposePlan(_planRequest());
      expect(plan.promptVersion, OpenAIClient.planPromptVersion);
      expect(plan.changes.length, 1);
      final change = plan.changes.single;
      expect(change.type, AIPlanChangeType.scheduleTask);
      expect(change.payload['title'], '评审会');
      expect(change.payload['note'], '会议室A');
      expect(change.payload.containsKey('startAt'), isTrue);
      expect(change.payload.containsKey('endAt'), isTrue);
    });

    test('scheduleTask 缺 title 判非法', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': 'x',
        'tasks': <Object?>[],
        'schedules': <Object?>[
          <String, Object?>{
            'startAt': '2026-05-01T09:00:00Z',
            'endAt': '2026-05-01T10:00:00Z',
          },
        ],
      });
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
      await expectLater(client.proposePlan(_planRequest()), throwsA(isA<PlanValidationException>()));
    });

    test('scheduleTask endAt <= startAt 判非法', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': 'x',
        'tasks': <Object?>[],
        'schedules': <Object?>[
          <String, Object?>{
            'title': 't',
            'startAt': '2026-05-01T10:00:00Z',
            'endAt': '2026-05-01T10:00:00Z',
          },
        ],
      });
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
      await expectLater(client.proposePlan(_planRequest()), throwsA(isA<PlanValidationException>()));
    });

    test('scheduleTask 缺 startAt/endAt 判非法', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': 'x',
        'tasks': <Object?>[],
        'schedules': <Object?>[
          <String, Object?>{
            'title': 't',
            'endAt': '2026-05-01T10:00:00Z',
          },
        ],
      });
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
      await expectLater(client.proposePlan(_planRequest()), throwsA(isA<PlanValidationException>()));
    });

    test('schedules 非数组判非法', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': 'x',
        'tasks': <Object?>[],
        'schedules': <String, Object?>{},
      });
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
      await expectLater(client.proposePlan(_planRequest()), throwsA(isA<PlanValidationException>()));
    });

    test('planPromptVersion 更新为 m2a-plan-v1', () async {
      final content = jsonEncode(<String, Object?>{
        'intent': 'ok',
        'tasks': <Object?>[],
      });
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
      final plan = await client.proposePlan(_planRequest());
      expect(plan.promptVersion, 'm2a-plan-v1');
      expect(OpenAIClient.planPromptVersion, 'm2a-plan-v1');
    });
  });
}
