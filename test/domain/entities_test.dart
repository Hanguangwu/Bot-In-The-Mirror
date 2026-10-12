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
      expect(report.copyWith(cursor: 'c1').cursor, 'c1');
    });
  });
}
