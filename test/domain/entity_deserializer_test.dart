import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/calendar.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/sync/entity_serializer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定时间样例（UTC），便于往返/样例断言（时区无关）。
final DateTime _t = DateTime(2026, 1, 2, 3, 4, 5).toUtc();
final DateTime _t2 = DateTime(2026, 1, 3, 6, 7, 8).toUtc();

void main() {
  group('entity_serializer fromSyncJson 往返', () {
    test('Conversation 往返（派生字段不在快照）', () {
      final entity = Conversation(
        id: 'c1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        version: 2,
        deviceId: 'd1',
        title: '测试',
        isArchived: true,
      );
      final json = entity.toSyncJson();
      final restored = ConversationSync.fromSyncJson(json);
      expect(restored.toSyncJson(), json);
      expect(restored.lastMessagePreview, isNull);
      expect(restored.lastMessageAt, isNull);
    });

    test('Message 往返（枚举/元数据/可空 aiModel）', () {
      final entity = Message(
        id: 'm1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        version: 3,
        deviceId: 'd1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        type: MessageType.voiceTranscription,
        content: '你好',
        status: MessageStatus.sent,
        aiModel: 'gpt-test',
        metadata: const <String, Object?>{'k': 1, 'nested': <Object?>[true, null]},
      );
      final json = entity.toSyncJson();
      final restored = MessageSync.fromSyncJson(json);
      expect(restored.toSyncJson(), json);
      expect(restored.role, MessageRole.assistant);
      expect(restored.type, MessageType.voiceTranscription);
      expect(restored.status, MessageStatus.sent);
      expect(restored.aiModel, 'gpt-test');
      expect(restored.metadata['k'], 1);
    });

    test('Task 往返（全部可空字段 + dueAt UTC）', () {
      final entity = Task(
        id: 't1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        deletedAt: _t2,
        version: 4,
        deviceId: 'd1',
        projectId: 'p1',
        title: '写周报',
        description: '详细',
        status: TaskStatus.doing,
        priority: TaskPriority.urgent,
        dueAt: _t2,
        parentTaskId: 't0',
        repeatRule: 'FREQ=DAILY',
        sourceMessageId: 'm1',
        sortOrder: 7,
      );
      final json = entity.toSyncJson();
      final restored = TaskSync.fromSyncJson(json);
      expect(restored.toSyncJson(), json);
      expect(restored.deletedAt, isNotNull);
      expect(restored.dueAt!.toUtc(), _t2);
    });

    test('Project 往返（goal 可空）', () {
      final entity = Project(
        id: 'p1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        version: 1,
        deviceId: 'd1',
        name: '工作',
        goal: '目标',
        isArchived: true,
      );
      final json = entity.toSyncJson();
      expect(ProjectSync.fromSyncJson(json).toSyncJson(), json);
    });

    test('AIPlan 往返（changes + 各时间字段）', () {
      final entity = AIPlan(
        id: 'ap1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        version: 5,
        deviceId: 'd1',
        conversationId: 'c1',
        sourceMessageId: 'm1',
        status: AIPlanStatus.applied,
        aiModel: 'gpt-test',
        aiModelVersion: 'v2',
        promptVersion: 'm2a-plan-v1',
        changes: <AIPlanChange>[
          const AIPlanChange(
            type: AIPlanChangeType.createTask,
            taskId: 't1',
            payload: <String, Object?>{'title': 'x'},
          ),
          const AIPlanChange(
            type: AIPlanChangeType.scheduleTask,
            calendarEntryId: 'ce1',
            payload: <String, Object?>{'title': 'y'},
          ),
        ],
        confirmedAt: _t,
        appliedAt: _t2,
        rejectedAt: _t,
        expiredAt: _t2,
      );
      final json = entity.toSyncJson();
      final restored = AIPlanSync.fromSyncJson(json);
      expect(restored.toSyncJson(), json);
      expect(restored.changes.length, 2);
      expect(restored.changes.first.type, AIPlanChangeType.createTask);
      expect(restored.changes.first.taskId, 't1');
    });

    test('CalendarEntry 往返（taskIds 数组 + note）', () {
      final entity = CalendarEntry(
        id: 'ce1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t2,
        version: 1,
        deviceId: 'd1',
        title: '评审',
        startAt: _t,
        endAt: _t2,
        allDay: true,
        taskIds: const <String>['t1', 't2'],
        note: '备注',
      );
      final json = entity.toSyncJson();
      final restored = CalendarEntrySync.fromSyncJson(json);
      expect(restored.toSyncJson(), json);
      expect(restored.taskIds, <String>['t1', 't2']);
      expect(restored.note, '备注');
    });
  });

  group('entity_serializer fromSyncJson 固定样例', () {
    test('Task 固定样例还原（含 UTC 时间、枚举、可空缺键为 null）', () {
      final map = <String, Object?>{
        'id': 't1',
        'userId': 'u1',
        'createdAt': _t.toIso8601String(),
        'updatedAt': _t2.toIso8601String(),
        'version': 9,
        'deviceId': 'd1',
        'title': '任务',
        'status': 'planned',
        'priority': 'low',
        'sortOrder': 0,
      };
      final task = TaskSync.fromSyncJson(map);
      expect(task.id, 't1');
      expect(task.createdAt.toUtc(), _t);
      expect(task.updatedAt.toUtc(), _t2);
      expect(task.version, 9);
      expect(task.status, TaskStatus.planned);
      expect(task.priority, TaskPriority.low);
      expect(task.deletedAt, isNull);
      expect(task.projectId, isNull);
      expect(task.dueAt, isNull);
      expect(task.description, isNull);
    });

    test('缺少 deletedAt 键 → null；delete 快照含 deletedAt → 非空', () {
      final base = Conversation(
        id: 'c1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t,
        version: 1,
        deviceId: 'd1',
        title: '对话',
      ).toSyncJson();
      expect(ConversationSync.fromSyncJson(base).deletedAt, isNull);

      final deleted = <String, Object?>{
        ...base,
        'deletedAt': _t2.toIso8601String(),
      };
      expect(ConversationSync.fromSyncJson(deleted).deletedAt!.toUtc(), _t2);
    });
  });

  group('entity_serializer fromSyncJson 非法输入抛 SyncDecodeException', () {
    Map<String, Object?> validTask() => Task(
          id: 't1',
          userId: 'u1',
          createdAt: _t,
          updatedAt: _t,
          version: 1,
          deviceId: 'd1',
          title: '任务',
        ).toSyncJson();

    test('未知枚举抛 SyncDecodeException', () {
      final map = <String, Object?>{...validTask(), 'status': 'bogus'};
      expect(
        () => TaskSync.fromSyncJson(map),
        throwsA(isA<SyncDecodeException>()),
      );
    });

    test('类型非法（version 非 int）抛 SyncDecodeException', () {
      final map = <String, Object?>{...validTask(), 'version': '1'};
      expect(
        () => TaskSync.fromSyncJson(map),
        throwsA(isA<SyncDecodeException>()),
      );
    });

    test('缺失必填键抛 SyncDecodeException', () {
      final map = <String, Object?>{...validTask()}..remove('title');
      expect(
        () => TaskSync.fromSyncJson(map),
        throwsA(isA<SyncDecodeException>()),
      );
    });

    test('AIPlan.changes 非法由 SyncDecodeException 包装 PlanValidationException', () {
      final base = AIPlan(
        id: 'ap1',
        userId: 'u1',
        createdAt: _t,
        updatedAt: _t,
        version: 1,
        deviceId: 'd1',
        conversationId: 'c1',
        sourceMessageId: 'm1',
        status: AIPlanStatus.awaitingConfirmation,
        aiModel: 'gpt',
        promptVersion: 'm2a-plan-v1',
        changes: const <AIPlanChange>[],
      ).toSyncJson();
      final map = <String, Object?>{...base, 'changes': 'not-a-list'};
      expect(
        () => AIPlanSync.fromSyncJson(map),
        throwsA(
          isA<SyncDecodeException>().having(
            (error) => error.cause,
            'cause',
            isA<PlanValidationException>(),
          ),
        ),
      );
    });
  });
}
