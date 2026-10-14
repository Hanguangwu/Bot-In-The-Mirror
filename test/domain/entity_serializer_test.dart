import 'dart:convert';

import 'package:chatwithalice/domain/entities/ai_plan.dart';
import 'package:chatwithalice/domain/entities/calendar.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/sync/entity_serializer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定时间样例，便于快照断言（UTC/时区无关）。
final DateTime _t = DateTime(2026, 1, 2, 3, 4, 5).toUtc();
final DateTime _t2 = DateTime(2026, 1, 3, 6, 7, 8).toUtc();

void main() {
  group('entity_serializer toSyncJson', () {
    test('Conversation：排除派生字段，包含公共字段，UTC 时间', () {
      final entity = Conversation(
        id: 'c1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t2.toLocal(),
        version: 2,
        deviceId: 'd1',
        title: '测试',
        isArchived: true,
        lastMessagePreview: '最新消息',
        lastMessageAt: _t2.toLocal(),
      );
      final json = entity.toSyncJson();
      expect(json['id'], 'c1');
      expect(json['userId'], 'u1');
      expect(json['createdAt'], _t.toIso8601String());
      expect(json['updatedAt'], _t2.toIso8601String());
      expect(json['version'], 2);
      expect(json['deviceId'], 'd1');
      expect(json['title'], '测试');
      expect(json['isArchived'], isTrue);
      expect(json.containsKey('deletedAt'), isFalse);
      expect(json.containsKey('lastMessagePreview'), isFalse);
      expect(json.containsKey('lastMessageAt'), isFalse);
    });

    test('Message：枚举 .name、metadata 原样、aiModel 可空省略', () {
      final entity = Message(
        id: 'm1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        conversationId: 'c1',
        role: MessageRole.user,
        type: MessageType.text,
        content: '你好',
        status: MessageStatus.sent,
        metadata: const {'k': 1},
      );
      final json = entity.toSyncJson();
      expect(json['conversationId'], 'c1');
      expect(json['role'], 'user');
      expect(json['type'], 'text');
      expect(json['content'], '你好');
      expect(json['status'], 'sent');
      expect(json['metadata'], {'k': 1});
      expect(json.containsKey('aiModel'), isFalse);

      final withModel = entity.copyWith(role: MessageRole.assistant, aiModel: 'gpt-test');
      expect(withModel.toSyncJson()['aiModel'], 'gpt-test');
    });

    test('Task：枚举 .name、可空字段省略、dueAt UTC', () {
      final entity = Task(
        id: 't1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        title: '写周报',
        status: TaskStatus.inbox,
        priority: TaskPriority.high,
        sortOrder: 5,
        dueAt: _t2.toLocal(),
      );
      final json = entity.toSyncJson();
      expect(json['title'], '写周报');
      expect(json['status'], 'inbox');
      expect(json['priority'], 'high');
      expect(json['sortOrder'], 5);
      expect(json['dueAt'], _t2.toIso8601String());
      expect(json.containsKey('projectId'), isFalse);
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('parentTaskId'), isFalse);
      expect(json.containsKey('repeatRule'), isFalse);
      expect(json.containsKey('sourceMessageId'), isFalse);
    });

    test('Project：isArchived bool、goal 可空省略', () {
      final entity = Project(
        id: 'p1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        name: '工作',
        isArchived: false,
      );
      expect(entity.toSyncJson(), {
        'id': 'p1',
        'userId': 'u1',
        'createdAt': _t.toIso8601String(),
        'updatedAt': _t.toIso8601String(),
        'version': 1,
        'deviceId': 'd1',
        'name': '工作',
        'isArchived': false,
      });

      final withGoal = entity.copyWith(goal: '目标');
      expect(withGoal.toSyncJson()['goal'], '目标');
    });

    test('AIPlan：changes 复用列表、时间 UTC、省略空值；delete 含 deletedAt', () {
      final change = AIPlanChange(
        type: AIPlanChangeType.createTask,
        payload: {'title': 'x', 'priority': 'medium'},
      );
      final entity = AIPlan(
        id: 'ap1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        conversationId: 'c1',
        sourceMessageId: 'm1',
        status: AIPlanStatus.awaitingConfirmation,
        aiModel: 'gpt-test',
        promptVersion: 'm2a-plan-v1',
        changes: [change],
        confirmedAt: _t2.toLocal(),
      );
      final json = entity.toSyncJson();
      expect(json['conversationId'], 'c1');
      expect(json['sourceMessageId'], 'm1');
      expect(json['status'], 'awaitingConfirmation');
      expect(json['aiModel'], 'gpt-test');
      expect(json['promptVersion'], 'm2a-plan-v1');
      expect(json['changes'] is List, isTrue);
      expect((json['changes'] as List).first['type'], 'createTask');
      expect(json['confirmedAt'], _t2.toIso8601String());
      expect(json.containsKey('deletedAt'), isFalse);
      expect(json.containsKey('aiModelVersion'), isFalse);
      expect(json.containsKey('appliedAt'), isFalse);
      expect(json.containsKey('rejectedAt'), isFalse);
      expect(json.containsKey('expiredAt'), isFalse);

      final deleted = entity.copyWith(deletedAt: _t2.toLocal());
      expect(deleted.toSyncJson()['deletedAt'], _t2.toIso8601String());
    });

    test('CalendarEntry：startAt/endAt UTC、allDay bool、taskIds 数组', () {
      final entity = CalendarEntry(
        id: 'ce1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        title: '评审',
        startAt: DateTime(2026, 5, 1, 9).toLocal(),
        endAt: DateTime(2026, 5, 1, 10).toLocal(),
        allDay: false,
        taskIds: const ['t1'],
        note: '备注',
      );
      final json = entity.toSyncJson();
      expect(json['title'], '评审');
      expect(json['startAt'], DateTime(2026, 5, 1, 9).toUtc().toIso8601String());
      expect(json['endAt'], DateTime(2026, 5, 1, 10).toUtc().toIso8601String());
      expect(json['allDay'], isFalse);
      expect(json['taskIds'], ['t1']);
      expect(json['note'], '备注');
      expect(json.containsKey('deletedAt'), isFalse);
    });

    test('六实体 toSyncJson 快照字段一致性（固定样例）', () {
      final conv = Conversation(
        id: 'c1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        title: '对话',
      );
      final msg = Message(
        id: 'm1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        type: MessageType.text,
        content: 'hi',
        status: MessageStatus.sent,
      );
      final task = Task(
        id: 't1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        title: '任务',
        status: TaskStatus.inbox,
        priority: TaskPriority.medium,
        sortOrder: 0,
      );
      final proj = Project(
        id: 'pr1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        name: '项目',
      );
      final plan = AIPlan(
        id: 'ap1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        conversationId: 'c1',
        sourceMessageId: 'm1',
        status: AIPlanStatus.awaitingConfirmation,
        aiModel: 'gpt',
        promptVersion: 'm2a-plan-v1',
        changes: const [],
      );
      final cal = CalendarEntry(
        id: 'ce1',
        userId: 'u1',
        createdAt: _t.toLocal(),
        updatedAt: _t.toLocal(),
        version: 1,
        deviceId: 'd1',
        title: '日程',
        startAt: _t.toLocal(),
        endAt: _t2.toLocal(),
        allDay: false,
        taskIds: const [],
      );

      expect(conv.toSyncJson()['lastMessagePreview'], isNull);
      expect(msg.toSyncJson()['aiModel'], isNull);
      expect(jsonEncode(task.toSyncJson()), isA<String>());
      expect(proj.toSyncJson().containsKey('goal'), isFalse);
      expect(plan.toSyncJson()['changes'], isA<List>());
      expect(cal.toSyncJson()['taskIds'], isA<List>());
    });
  });
}
