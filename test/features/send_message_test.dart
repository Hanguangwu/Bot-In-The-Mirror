import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/memory/memory_conversation_repository.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/domain/ai/ai_client.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/ai_provider.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/features/chat/application/send_message.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 AI 客户端，可返回固定结果或抛出指定异常。
class _FakeAIClient implements AIClient {
  _FakeAIClient({this.error});

  final Object? error;
  AIRequest? lastRequest;

  static const AIResult _result = AIResult(content: '你好', model: 'fake-model');

  @override
  Future<AIResult> complete(AIRequest request) async {
    lastRequest = request;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return _result;
  }

  @override
  Future<AIResult> testConnection(AIProviderProfile profile) async => _result;

  @override
  Future<AIPlan> proposePlan(PlanRequest request) async =>
      throw const UnsupportedException('暂未支持');
}

/// 递增时钟，保证同一用例内时间严格递增（避免排序并列）。
class _StepClock implements Clock {
  DateTime _current = DateTime(2024, 1, 1, 8, 0, 0);

  @override
  DateTime now() {
    final value = _current;
    _current = _current.add(const Duration(seconds: 1));
    return value;
  }
}

void main() {
  late MemoryConversationRepository repository;
  late MemorySettingsStore settingsStore;
  late Conversation conversation;

  const profile = AIProviderProfile(
    name: '默认',
    baseUrl: 'https://example.com/v1',
    model: 'fake-model',
    temperature: 0.7,
    maxTokens: 1000,
  );

  setUp(() async {
    repository = MemoryConversationRepository(
      syncOperationRepository: MemorySyncOperationRepository(),
      clock: _StepClock(),
    );
    settingsStore = MemorySettingsStore(initialProfile: profile);
    conversation = await repository.createConversation(title: '测试');
  });

  test('成功时落库用户与助手两条消息，并使用当前 profile.model', () async {
    final client = _FakeAIClient();
    final useCase = SendMessage(
      repository: repository,
      aiClient: client,
      settingsStore: settingsStore,
    );

    await useCase(conversationId: conversation.id, text: '你好呀');

    final messages = await repository.getMessages(conversation.id);
    expect(messages.length, 2);
    expect(messages[0].role, MessageRole.user);
    expect(messages[0].content, '你好呀');
    expect(messages[0].status, MessageStatus.sent);
    expect(messages[1].role, MessageRole.assistant);
    expect(messages[1].content, '你好');
    expect(messages[1].aiModel, 'fake-model');
    expect(client.lastRequest!.profile.model, 'fake-model');
  });

  test('第二轮请求包含此前历史', () async {
    final client = _FakeAIClient();
    final useCase = SendMessage(
      repository: repository,
      aiClient: client,
      settingsStore: settingsStore,
    );

    await useCase(conversationId: conversation.id, text: '第一句');
    await useCase(conversationId: conversation.id, text: '第二句');

    final sent = client.lastRequest!.messages;
    expect(sent.map((message) => message.content).toList(), <String>[
      '第一句',
      '你好',
      '第二句',
    ]);
    expect(sent.last.role, AIChatRole.user);
  });

  test('AI 抛错时不再追加助手消息且异常上抛', () async {
    final client = _FakeAIClient(
      error: const AIProviderException('AI 服务不可用', statusCode: 500),
    );
    final useCase = SendMessage(
      repository: repository,
      aiClient: client,
      settingsStore: settingsStore,
    );

    await expectLater(
      useCase(conversationId: conversation.id, text: '会失败'),
      throwsA(isA<AIProviderException>()),
    );

    final messages = await repository.getMessages(conversation.id);
    expect(messages.length, 1);
    expect(messages.single.role, MessageRole.user);
  });
}
