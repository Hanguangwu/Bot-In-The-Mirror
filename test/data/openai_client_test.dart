import 'dart:convert';

import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/data/ai/openai_client.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/domain/ai/ai_client.dart';
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
}
