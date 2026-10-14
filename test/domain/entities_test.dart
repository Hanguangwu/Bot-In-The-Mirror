import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/domain/entities/achievements.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/ai_provider.dart';
import 'package:chatwithalice/domain/entities/calendar.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/domain/entities/health.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/entities/syncable_entity.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/entities/user.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造测试用基础时间。
final DateTime _t0 = DateTime(2024, 1, 1, 8, 0, 0);
final DateTime _t1 = DateTime(2024, 1, 2, 9, 30, 0);

/// 构造一个最小会话。
Conversation _conversation({String title = 'AI助手'}) {
  return Conversation(
    id: 'conv-1',
    userId: 'user-1',
    createdAt: _t0,
    updatedAt: _t0,
    version: 1,
    deviceId: 'device-1',
    title: title,
  );
}

void main() {
  group('SyncableEntity 与实体构造/copyWith', () {
    test('Conversation 默认值正确', () {
      final conversation = _conversation();
      expect(conversation.title, 'AI助手');
      expect(conversation.isArchived, isFalse);
      expect(conversation.lastMessagePreview, isNull);
      expect(conversation.lastMessageAt, isNull);
      expect(conversation.deletedAt, isNull);
      expect(conversation.version, 1);
      expect(conversation.deviceId, 'device-1');
    });

    test('Conversation.copyWith 覆盖字段且保留其余字段', () {
      final conversation = _conversation();
      final updated = conversation.copyWith(
        title: '工作',
        isArchived: true,
        lastMessagePreview: '你好',
        lastMessageAt: _t1,
        version: 2,
        updatedAt: _t1,
      );
      expect(updated.title, '工作');
      expect(updated.isArchived, isTrue);
      expect(updated.lastMessagePreview, '你好');
      expect(updated.lastMessageAt, _t1);
      expect(updated.version, 2);
      expect(updated.updatedAt, _t1);
      // 未覆盖的字段保持不变。
      expect(updated.id, conversation.id);
      expect(updated.userId, conversation.userId);
      expect(updated.createdAt, conversation.createdAt);
      expect(updated.deviceId, conversation.deviceId);
    });

    test('Message 构造与 copyWith', () {
      final message = Message(
        id: 'msg-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        type: MessageType.text,
        content: '你好',
        status: MessageStatus.sent,
      );
      expect(message.metadata, isEmpty);
      expect(message.aiModel, isNull);

      final failed = message.copyWith(status: MessageStatus.failed);
      expect(failed.status, MessageStatus.failed);
      expect(failed.content, '你好');
      expect(failed.role, MessageRole.user);
    });

    test('User（userId==id）与 Workspace 构造', () {
      final user = User(
        id: 'user-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        name: '小明',
      );
      expect(user.id, user.userId);
      expect(user.copyWith(name: '小红').name, '小红');

      final workspace = Workspace(
        id: 'ws-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        name: '我的空间',
      );
      expect(workspace.name, '我的空间');
    });

    test('Task 默认状态与优先级', () {
      final task = Task(
        id: 'task-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        title: '写方案',
      );
      expect(task.status, TaskStatus.inbox);
      expect(task.priority, TaskPriority.medium);
      expect(task.sortOrder, 0);

      final done = task.copyWith(
        status: TaskStatus.done,
        priority: TaskPriority.high,
      );
      expect(done.status, TaskStatus.done);
      expect(done.priority, TaskPriority.high);
      expect(done.title, '写方案');
    });

    test('CalendarEntry 默认值', () {
      final entry = CalendarEntry(
        id: 'cal-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        title: '会议',
        startAt: _t0,
        endAt: _t1,
      );
      expect(entry.allDay, isFalse);
      expect(entry.taskIds, isEmpty);
      expect(entry.note, isNull);
    });

    test('HealthRecord 与 UserAchievement 构造', () {
      final record = HealthRecord(
        id: 'health-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        type: HealthRecordType.meal,
        title: '午餐',
        occurredAt: _t0,
        source: 'manual',
      );
      expect(record.value, isEmpty);
      expect(record.confidence, isNull);

      final unlocked = UserAchievement(
        id: 'ua-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        achievementId: 'task_completed',
        eventKey: 'task-1',
        unlockedAt: _t0,
      );
      expect(unlocked.achievementId, 'task_completed');
      expect(
        const Achievement(
          code: 'task_completed',
          title: '首个任务',
          ruleVersion: 1,
        ).ruleVersion,
        1,
      );
    });

    test('AIProviderProfile 是值对象（不继承 SyncableEntity）', () {
      const profile = AIProviderProfile(
        name: '默认',
        baseUrl: 'https://example.com/v1',
        model: 'gpt-3.5-turbo',
        temperature: 0.7,
        maxTokens: 2000,
      );
      expect(profile.streamEnabled, isFalse);
      expect(profile.capabilities, contains(AICapability.text));
      expect(profile is SyncableEntity, isFalse);

      final streamed = profile.copyWith(streamEnabled: true);
      expect(streamed.streamEnabled, isTrue);
      expect(streamed.model, 'gpt-3.5-turbo');
    });
  });

  group('枚举取值', () {
    test('MessageRole / MessageType / MessageStatus', () {
      expect(MessageRole.values, <MessageRole>[
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.system,
      ]);
      expect(MessageType.values, <MessageType>[
        MessageType.text,
        MessageType.voiceTranscription,
        MessageType.imageReference,
        MessageType.systemEvent,
      ]);
      expect(MessageStatus.values, <MessageStatus>[
        MessageStatus.sending,
        MessageStatus.sent,
        MessageStatus.failed,
      ]);
    });

    test('TaskStatus 生命周期顺序常量', () {
      expect(TaskStatus.values, <TaskStatus>[
        TaskStatus.inbox,
        TaskStatus.planned,
        TaskStatus.doing,
        TaskStatus.done,
        TaskStatus.cancelled,
      ]);
      expect(TaskStatus.values.indexOf(TaskStatus.inbox), 0);
      expect(TaskStatus.values.indexOf(TaskStatus.planned), 1);
      expect(TaskStatus.values.indexOf(TaskStatus.doing), 2);
      expect(TaskStatus.values.indexOf(TaskStatus.done), 3);
    });

    test('TaskPriority / HealthRecordType / AICapability / SyncState', () {
      expect(TaskPriority.values.length, 4);
      expect(HealthRecordType.values, contains(HealthRecordType.calorie));
      expect(AICapability.values, <AICapability>[
        AICapability.text,
        AICapability.vision,
        AICapability.tools,
      ]);
      expect(SyncState.values, <SyncState>[
        SyncState.idle,
        SyncState.syncing,
        SyncState.offline,
        SyncState.failed,
      ]);
    });
  });

  group('AIPlan 状态机', () {
    AIPlan planWith(AIPlanStatus status) {
      return AIPlan(
        id: 'plan-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        conversationId: 'conv-1',
        sourceMessageId: 'msg-1',
        status: status,
        aiModel: 'gpt-3.5-turbo',
        promptVersion: 'v1',
      );
    }

    test('状态取值与顺序', () {
      expect(AIPlanStatus.values, <AIPlanStatus>[
        AIPlanStatus.draft,
        AIPlanStatus.awaitingConfirmation,
        AIPlanStatus.applied,
        AIPlanStatus.rejected,
        AIPlanStatus.expired,
      ]);
    });

    test('draft → awaitingConfirmation → applied 合法流转', () {
      final draft = planWith(AIPlanStatus.draft);
      final awaiting = draft.copyWith(
        status: AIPlanStatus.awaitingConfirmation,
        confirmedAt: _t1,
      );
      final applied = awaiting.copyWith(
        status: AIPlanStatus.applied,
        appliedAt: _t1,
      );
      expect(applied.status, AIPlanStatus.applied);
      expect(applied.appliedAt, _t1);
      expect(applied.confirmedAt, _t1);
      expect(applied.changes, isEmpty);
    });

    test('terminals：rejected 与 expired 亦可达', () {
      final draft = planWith(AIPlanStatus.draft);
      expect(
        draft.copyWith(status: AIPlanStatus.rejected).status,
        AIPlanStatus.rejected,
      );
      expect(
        draft.copyWith(status: AIPlanStatus.expired).status,
        AIPlanStatus.expired,
      );
    });

    test('AIPlanChange 与枚举', () {
      expect(AIPlanChangeType.values, <AIPlanChangeType>[
        AIPlanChangeType.createTask,
        AIPlanChangeType.updateTask,
        AIPlanChangeType.scheduleTask,
        AIPlanChangeType.deleteTask,
      ]);
      const change = AIPlanChange(type: AIPlanChangeType.createTask);
      expect(change.payload, isEmpty);
      expect(change.taskId, isNull);
      expect(change.copyWith(taskId: 'task-2').taskId, 'task-2');
    });
  });

  group('Task copyWith clearX', () {
    test('clearDueAt/clearDescription 置 null 且不影响其它字段', () {
      final due = DateTime(2024, 1, 5);
      final task = Task(
        id: 'task-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        title: '写方案',
        description: '初稿',
        dueAt: due,
      );
      final cleared = task.copyWith(clearDueAt: true, clearDescription: true);
      expect(cleared.dueAt, isNull);
      expect(cleared.description, isNull);
      expect(cleared.title, '写方案');
      expect(cleared.status, TaskStatus.inbox);

      final updated = task.copyWith(dueAt: _t1, description: '修改版');
      expect(updated.dueAt, _t1);
      expect(updated.description, '修改版');

      final partial = task.copyWith(clearDueAt: true, description: '保留');
      expect(partial.dueAt, isNull);
      expect(partial.description, '保留');
    });
  });

  group('AIPlan 编解码与物化', () {
    final plan = AIPlan(
      id: 'plan-1',
      userId: 'user-1',
      createdAt: _t0,
      updatedAt: _t0,
      version: 1,
      deviceId: 'device-1',
      conversationId: 'conv-1',
      sourceMessageId: 'msg-1',
      status: AIPlanStatus.awaitingConfirmation,
      aiModel: 'gpt-4o',
      promptVersion: 'm1-plan-v1',
      changes: const <AIPlanChange>[],
    );

    test('encodeChanges/decodeChanges 往返', () {
      final change = AIPlanChange(
        type: AIPlanChangeType.createTask,
        payload: const <String, Object?>{
          'title': '买东西',
          'description': '牛奶',
          'priority': 'high',
          'dueAt': '2024-01-10T10:00:00.000',
        },
      );
      final encoded = encodeChanges([change]);
      final decoded = decodeChanges(encoded);
      expect(decoded.length, 1);
      expect(decoded.first.type, AIPlanChangeType.createTask);
      expect(decoded.first.payload['title'], '买东西');
    });

    test('decodeChanges 非法输入抛 PlanValidationException', () {
      expect(() => decodeChanges(null), throwsA(isA<PlanValidationException>()));
      expect(() => decodeChanges(<String, dynamic>{}), throwsA(isA<PlanValidationException>()));
      expect(() => decodeChanges(<Object?>[]), throwsA(isA<PlanValidationException>()));
      expect(
        () => decodeChanges(<Object?>[
          <String, Object?>{'payload': <String, Object?>{}}
        ]),
        throwsA(isA<PlanValidationException>()),
      );
      expect(
        () => decodeChanges(<Object?>[
          <String, Object?>{'type': 'unknown'}
        ]),
        throwsA(isA<PlanValidationException>()),
      );
    });

    test('taskFromPlanChange 物化（含 dueAt ISO→DateTime toLocal）', () {
      final change = AIPlanChange(
        type: AIPlanChangeType.createTask,
        payload: const <String, Object?>{
          'title': '写报告',
          'description': '周报',
          'priority': 'medium',
          'dueAt': '2024-01-03T02:00:00.000Z',
        },
      );
      final now = DateTime(2024, 1, 2, 12, 0, 0);
      final task = taskFromPlanChange(
        change,
        plan,
        userId: 'user-1',
        deviceId: 'device-1',
        now: now,
      );
      expect(task.title, '写报告');
      expect(task.description, '周报');
      expect(task.priority, TaskPriority.medium);
      expect(task.sourceMessageId, 'msg-1');
      expect(task.status, TaskStatus.inbox);
      expect(task.version, 1);
      expect(task.sortOrder, 0);
      expect(task.dueAt, isNotNull);
    });

    test('taskFromPlanChange priority 缺失默认 medium', () {
      final change = AIPlanChange(
        type: AIPlanChangeType.createTask,
        payload: const <String, Object?>{
          'title': '任务A',
        },
      );
      final task = taskFromPlanChange(
        change,
        plan,
        userId: 'user-1',
        deviceId: 'device-1',
        now: _t0,
      );
      expect(task.priority, TaskPriority.medium);
    });

    test('taskFromPlanChange 非 createTask → ConflictException', () {
      final change = AIPlanChange(
        type: AIPlanChangeType.updateTask,
        payload: const <String, Object?>{},
      );
      expect(
        () => taskFromPlanChange(
          change,
          plan,
          userId: 'user-1',
          deviceId: 'device-1',
          now: _t0,
        ),
        throwsA(isA<ConflictException>()),
      );
    });
  });


  group('TaskChange sealed', () {
    test('三种变更事件可构造', () {
      final task = Task(
        id: 'task-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        title: '写方案',
      );
      expect(TaskInserted(task).task, same(task));
      expect(TaskUpdated(task).task, same(task));
      expect(TaskDeleted('task-1').id, 'task-1');
    });

    test('TaskQuery 值对象', () {
      const query = TaskQuery(status: TaskStatus.inbox);
      expect(query.status, TaskStatus.inbox);
      expect(query.projectId, isNull);
      expect(query.copyWith(text: '方案').text, '方案');
    });
  });

  group('metadata JSON 编解码', () {
    test('encode/decode 往返', () {
      const metadata = <String, Object?>{'k': 'v', 'n': 1, 'b': true};
      final encoded = encodeMetadata(metadata);
      expect(decodeMetadata(encoded), metadata);
    });

    test('空值与非法输入返回空 Map', () {
      expect(decodeMetadata(null), isEmpty);
      expect(decodeMetadata(''), isEmpty);
      expect(decodeMetadata('not-json'), isEmpty);
      expect(decodeMetadata('[1,2,3]'), isEmpty);
    });
  });

  group('同步模型', () {
    test('SyncOperation 默认值与 copyWith', () {
      final op = SyncOperation(
        id: 'op-1',
        userId: 'user-1',
        createdAt: _t0,
        updatedAt: _t0,
        version: 1,
        deviceId: 'device-1',
        entityType: 'conversation',
        entityId: 'conv-1',
        kind: SyncOperationKind.create,
      );
      expect(op.status, SyncOperationStatus.pending);
      expect(op.retryCount, 0);
      expect(op.payload, isEmpty);

      final retried = op.copyWith(retryCount: 1, lastError: '超时');
      expect(retried.retryCount, 1);
      expect(retried.lastError, '超时');
      expect(retried.kind, SyncOperationKind.create);
    });

    test('SyncReport 值对象', () {
      final report = SyncReport(pushed: 2, pulled: 3, failed: 0, at: _t1);
      expect(report.pushed, 2);
      expect(report.cursor, isNull);
      expect(report.copyWith(cursor: 7).cursor, 7);
    });
  });
}
