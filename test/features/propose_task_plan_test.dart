import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/domain/ai/ai_client.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/ai_provider.dart';
import 'package:chatwithalice/domain/repositories/ai_plan_repository.dart';
import 'package:chatwithalice/features/tasks/application/propose_task_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 AI 客户端：返回预置计划或抛出指定异常，不触网。
class _FakeAIClient implements AIClient {
  _FakeAIClient({this.plan, this.error});

  final AIPlan? plan;
  final Object? error;
  PlanRequest? lastRequest;

  @override
  Future<AIPlan> proposePlan(PlanRequest request) async {
    lastRequest = request;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return plan!;
  }

  @override
  Future<AIResult> complete(AIRequest request) async =>
      const AIResult(content: '', model: 'fake-model');

  @override
  Future<AIResult> testConnection(AIProviderProfile profile) async =>
      AIResult(content: 'pong', model: profile.model);
}

/// 假计划仓储：记录 save/confirm/reject 调用。
class _FakeAIPlanRepository implements AIPlanRepository {
  final List<AIPlan> saved = <AIPlan>[];

  @override
  Future<AIPlan> save(AIPlan plan) async {
    saved.add(plan);
    return plan;
  }

  @override
  Stream<List<AIPlan>> watchPending() => const Stream<List<AIPlan>>.empty();

  @override
  Future<List<AIPlan>> getPending() async => const <AIPlan>[];

  @override
  Future<void> confirm(String planId) async {}

  @override
  Future<void> reject(String planId) async {}
}

AIPlanChange _createTaskChange(String title) => AIPlanChange(
      type: AIPlanChangeType.createTask,
      payload: <String, Object?>{'title': title, 'priority': 'medium'},
    );

AIPlan _planWith(List<AIPlanChange> changes) => AIPlan(
      id: 'plan-1',
      userId: 'user-1',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      version: 1,
      deviceId: 'device-1',
      conversationId: 'conv-1',
      sourceMessageId: 'msg-1',
      status: AIPlanStatus.awaitingConfirmation,
      aiModel: 'fake-model',
      promptVersion: 'm1-plan-v1',
      changes: changes,
    );

const AIProviderProfile _profile = AIProviderProfile(
  name: '默认',
  baseUrl: 'https://example.com/v1',
  model: 'fake-model',
  temperature: 0.7,
  maxTokens: 1000,
);

PlanRequest _planRequest() => const PlanRequest(
      conversationId: 'conv-1',
      sourceMessageId: 'msg-1',
      request: '帮我安排明天的工作',
      profile: _profile,
    );

void main() {
  test('成功时落库一次并返回 awaitingConfirmation 计划', () async {
    final client = _FakeAIClient(plan: _planWith(<AIPlanChange>[
      _createTaskChange('写周报'),
    ]));
    final repository = _FakeAIPlanRepository();
    final useCase = ProposeTaskPlan(
      aiClient: client,
      aiPlanRepository: repository,
    );

    final result = await useCase.propose(_planRequest());

    expect(repository.saved.length, 1);
    expect(repository.saved.single, same(result));
    expect(result!.status, AIPlanStatus.awaitingConfirmation);
    expect(result.changes.length, 1);
    expect(client.lastRequest!.conversationId, 'conv-1');
  });

  test('空 changes 返回 null 且不落库', () async {
    final client = _FakeAIClient(plan: _planWith(const <AIPlanChange>[]));
    final repository = _FakeAIPlanRepository();
    final useCase = ProposeTaskPlan(
      aiClient: client,
      aiPlanRepository: repository,
    );

    final result = await useCase.propose(_planRequest());

    expect(result, isNull);
    expect(repository.saved, isEmpty);
  });

  test('AI 抛异常时透传且不落库', () async {
    final client = _FakeAIClient(
      error: const AIProviderException('AI 服务不可用', statusCode: 500),
    );
    final repository = _FakeAIPlanRepository();
    final useCase = ProposeTaskPlan(
      aiClient: client,
      aiPlanRepository: repository,
    );

    await expectLater(
      useCase.propose(_planRequest()),
      throwsA(isA<AIProviderException>()),
    );
    expect(repository.saved, isEmpty);
  });
}
