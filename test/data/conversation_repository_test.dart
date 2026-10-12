import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/conversation_repository_impl.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控时钟，便于构造确定性的时间顺序。
class _MutableClock implements Clock {
  _MutableClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;
}

/// 构造待落库消息（id/时间由仓储维护）。
Message _message(String conversationId, String content) {
  final stamp = DateTime(2000);
  return Message(
    id: '',
    userId: '',
    createdAt: stamp,
    updatedAt: stamp,
    version: 0,
    deviceId: '',
    conversationId: conversationId,
    role: MessageRole.user,
    type: MessageType.text,
    content: content,
    status: MessageStatus.sent,
  );
}

void main() {
  late AppDatabase database;
  late _MutableClock clock;
  late ConversationRepositoryImpl repository;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
    repository = ConversationRepositoryImpl(
      database,
      clock,
      userId: 'user-1',
      deviceId: 'device-1',
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('创建会话并读取，字段由实现补齐', () async {
    final conversation = await repository.createConversation(title: '写作助手');
    expect(conversation.id, isNotEmpty);
    expect(conversation.userId, 'user-1');
    expect(conversation.deviceId, 'device-1');
    expect(conversation.version, 1);

    final loaded = await repository.getConversation(conversation.id);
    expect(loaded, isNotNull);
    expect(loaded!.title, '写作助手');
    expect((await repository.getConversations()).length, 1);
  });

  test('addMessage 更新会话摘要与版本', () async {
    final conversation = await repository.createConversation(title: '测试');
    clock.current = clock.current.add(const Duration(minutes: 1));

    final stored = await repository.addMessage(
      _message(conversation.id, '第一条消息'),
    );
    expect(stored.id, isNotEmpty);
    expect(stored.userId, 'user-1');
    expect(stored.createdAt, clock.current);

    final updated = await repository.getConversation(conversation.id);
    expect(updated!.lastMessagePreview, '第一条消息');
    expect(updated.lastMessageAt, clock.current);
    expect(updated.version, 2);
  });

  test('长消息预览截断到 50 字', () async {
    final conversation = await repository.createConversation(title: '测试');
    final longText = 'a' * 120;
    await repository.addMessage(_message(conversation.id, longText));
    final updated = await repository.getConversation(conversation.id);
    expect(updated!.lastMessagePreview!.length, 50);
  });

  test('watchMessages 按创建时间正序推送', () async {
    final conversation = await repository.createConversation(title: '测试');

    final future = expectLater(
      repository.watchMessages(conversation.id),
      emitsThrough(
        predicate<List<Message>>(
          (messages) =>
              messages.length == 2 &&
              messages[0].content == '你好' &&
              messages[1].content == 'reply',
        ),
      ),
    );

    clock.current = clock.current.add(const Duration(minutes: 1));
    await repository.addMessage(_message(conversation.id, '你好'));
    clock.current = clock.current.add(const Duration(minutes: 1));
    await repository.addMessage(
      _message(conversation.id, 'reply').copyWith(
        role: MessageRole.assistant,
      ),
    );

    await future;
  });

  test('clearMessages 物理删除消息', () async {
    final conversation = await repository.createConversation(title: '测试');
    await repository.addMessage(_message(conversation.id, 'a'));
    clock.current = clock.current.add(const Duration(minutes: 1));
    await repository.addMessage(_message(conversation.id, 'b'));
    expect((await repository.getMessages(conversation.id)).length, 2);

    await repository.clearMessages(conversation.id);
    expect(await repository.getMessages(conversation.id), isEmpty);
  });

  test('deleteConversation 软删除后不再出现在查询与 watch 中', () async {
    final conversation = await repository.createConversation(title: '待删除');

    final future = expectLater(
      repository.watchConversations(),
      emitsThrough(predicate<List<Conversation>>((list) => list.isEmpty)),
    );
    await repository.deleteConversation(conversation.id);
    await future;

    expect(await repository.getConversation(conversation.id), isNull);
    expect(await repository.getConversations(), isEmpty);
  });

  test('getConversations 按 lastMessageAt 倒序，null 排最后', () async {
    final empty = await repository.createConversation(title: '空会话');
    final first = await repository.createConversation(title: 'A');
    clock.current = clock.current.add(const Duration(minutes: 1));
    await repository.addMessage(_message(first.id, 'a'));
    final second = await repository.createConversation(title: 'B');
    clock.current = clock.current.add(const Duration(minutes: 1));
    await repository.addMessage(_message(second.id, 'b'));

    final list = await repository.getConversations();
    expect(list.map((item) => item.id).toList(), <String>[
      second.id,
      first.id,
      empty.id,
    ]);
  });

  test('ensureDefaultConversation 幂等', () async {
    final first = await repository.ensureDefaultConversation();
    final second = await repository.ensureDefaultConversation();
    expect(first.title, 'AI助手');
    expect(first.id, second.id);
    expect((await repository.getConversations()).length, 1);
  });

  test('metadata 经 JSON 列往返一致', () async {
    final conversation = await repository.createConversation(title: '测试');
    await repository.addMessage(
      _message(conversation.id, 'x').copyWith(
        metadata: <String, Object?>{'kind': 'note', 'count': 3},
      ),
    );
    final loaded = await repository.getMessages(conversation.id);
    expect(loaded.single.metadata, <String, Object?>{
      'kind': 'note',
      'count': 3,
    });
  });
}
