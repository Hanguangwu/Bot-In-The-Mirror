import 'package:characters/characters.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/app_database.dart';
import 'package:chatwithalice/data/local/conversation_repository_impl.dart';
import 'package:chatwithalice/data/local/sync_operation_repository_impl.dart';
import 'package:chatwithalice/data/memory/memory_conversation_repository.dart';
import 'package:chatwithalice/data/memory/memory_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/domain/entities/conversation.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/repositories/conversation_repository.dart';
import 'package:chatwithalice/domain/repositories/sync_operation_repository.dart';
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

/// 从队列中筛出指定类型与操作类别。
List<SyncOperation> _opsOf(
  List<SyncOperation> all,
  String entityType,
  SyncOperationKind kind,
) =>
    all
        .where((op) => op.entityType == entityType && op.kind == kind)
        .toList(growable: false);

/// 被测实现、共享队列与资源释放器的组合。
class _Harness {
  _Harness(this.repository, this.syncOperationRepository, this._dispose);

  final ConversationRepository repository;
  final SyncOperationRepository syncOperationRepository;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// 对内存实现与 Drift 实现跑同一组契约断言，保证两种实现行为一致（F7）。
void _runContract(
  String name, {
  required Future<_Harness> Function(Clock clock) create,
}) {
  group(name, () {
    late _MutableClock clock;
    late _Harness harness;
    late ConversationRepository repository;

    setUp(() async {
      clock = _MutableClock(DateTime(2024, 1, 1, 8, 0, 0));
      harness = await create(clock);
      repository = harness.repository;
    });

    tearDown(() => harness.dispose());

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

    test('createConversation 入队 conversation create，身份与 payload 正确', () async {
      final conversation = await repository.createConversation(title: '写作助手');

      final creates = _opsOf(
        await harness.syncOperationRepository.getPending(),
        'conversation',
        SyncOperationKind.create,
      );
      expect(creates, hasLength(1));
      final op = creates.single;
      expect(op.entityId, conversation.id);
      expect(op.userId, 'user-1');
      expect(op.deviceId, 'device-1');
      expect(op.version, 1);
      expect(op.status, SyncOperationStatus.pending);
      expect(op.payload['id'], conversation.id);
      expect(op.payload['title'], '写作助手');
    });

    test('updateConversation 入队 conversation update（快照=最终实体）', () async {
      final conversation = await repository.createConversation(title: '旧标题');
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.updateConversation(conversation.copyWith(title: '新标题'));

      final updates = _opsOf(
        await harness.syncOperationRepository.getPending(),
        'conversation',
        SyncOperationKind.update,
      );
      expect(updates, hasLength(1));
      expect(updates.single.entityId, conversation.id);
      expect(updates.single.payload['title'], '新标题');
    });

    test('deleteConversation 入队 conversation delete（快照含 deletedAt）', () async {
      final conversation = await repository.createConversation(title: '待删');
      clock.current = clock.current.add(const Duration(minutes: 1));

      await repository.deleteConversation(conversation.id);

      final deletes = _opsOf(
        await harness.syncOperationRepository.getPending(),
        'conversation',
        SyncOperationKind.delete,
      );
      expect(deletes, hasLength(1));
      expect(deletes.single.entityId, conversation.id);
      expect(deletes.single.payload['deletedAt'], isNotNull);
    });

    test('addMessage 更新摘要但不 bump 会话 version/updatedAt，仅入队 message create（§7.4）',
        () async {
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
      // §7.4：派生摘要不 bump version、不改 updatedAt。
      expect(updated.version, conversation.version);
      expect(updated.updatedAt, conversation.updatedAt);

      final pending = await harness.syncOperationRepository.getPending();
      expect(_opsOf(pending, 'message', SyncOperationKind.create), hasLength(1));
      expect(_opsOf(pending, 'conversation', SyncOperationKind.update), isEmpty);
    });

    test('摘要按字素截断，不切断 emoji（F11）', () async {
      final conversation = await repository.createConversation(title: '测试');
      final text = '👨‍👩‍👧‍👦' * 60;
      expect(text.characters.length, 60);

      await repository.addMessage(_message(conversation.id, text));

      final updated = await repository.getConversation(conversation.id);
      final preview = updated!.lastMessagePreview!;
      expect(preview.characters.length, 50);
      // 与按字素截断的结果完全一致；按码元 substring 会切出不同（且破损）的字符串。
      expect(preview, text.characters.take(50).toString());
    });

    test('同一秒内不同毫秒的消息按时间正序（F1 亚秒精度回归）', () async {
      final conversation = await repository.createConversation(title: '测试');
      clock.current = DateTime(2024, 1, 1, 8, 0, 0, 100);
      await repository.addMessage(_message(conversation.id, '早'));
      clock.current = DateTime(2024, 1, 1, 8, 0, 0, 900);
      await repository.addMessage(_message(conversation.id, '晚'));

      final messages = await repository.getMessages(conversation.id);
      expect(messages.map((item) => item.content).toList(), <String>['早', '晚']);
      // 整秒时间存储会把两者截断到同一时刻（毫秒归零），文本存储保留亚秒精度。
      expect(messages[0].createdAt.millisecond, 100);
      expect(messages[1].createdAt.millisecond, 900);
      expect(messages[1].createdAt.isAfter(messages[0].createdAt), isTrue);
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
                messages[1].content == '回复',
          ),
        ),
      );

      clock.current = clock.current.add(const Duration(seconds: 1));
      await repository.addMessage(_message(conversation.id, '你好'));
      clock.current = clock.current.add(const Duration(seconds: 1));
      await repository.addMessage(
        _message(conversation.id, '回复').copyWith(role: MessageRole.assistant),
      );

      await future;
    });

    test('clearMessages 墓碑化消息：列表不含已删、逐条入队 delete、摘要重置但不 bump 会话版本（§8/§7.4）',
        () async {
      final conversation = await repository.createConversation(title: '测试');
      clock.current = clock.current.add(const Duration(minutes: 1));
      await repository.addMessage(_message(conversation.id, '你好'));
      clock.current = clock.current.add(const Duration(minutes: 1));
      await repository.addMessage(_message(conversation.id, '世界'));

      final beforeClear = (await repository.getConversation(conversation.id))!;
      expect(beforeClear.lastMessagePreview, '世界');
      expect(beforeClear.lastMessageAt, isNotNull);

      clock.current = clock.current.add(const Duration(minutes: 1));
      await repository.clearMessages(conversation.id);

      // 查询过滤 deletedAt IS NULL。
      expect(await repository.getMessages(conversation.id), isEmpty);
      // 摘要重置但不改 updatedAt、不 bump version（§7.4）。
      final afterClear = (await repository.getConversation(conversation.id))!;
      expect(afterClear.lastMessagePreview, isNull);
      expect(afterClear.lastMessageAt, isNull);
      expect(afterClear.version, beforeClear.version);
      expect(afterClear.updatedAt, beforeClear.updatedAt);

      // 逐条墓碑化入队 message delete ×2，快照含 deletedAt。
      final deletes = _opsOf(
        await harness.syncOperationRepository.getPending(),
        'message',
        SyncOperationKind.delete,
      );
      expect(deletes, hasLength(2));
      for (final op in deletes) {
        expect(op.payload['deletedAt'], isNotNull);
      }
    });

    test('deleteConversation 软删除后不再出现在查询中', () async {
      final conversation = await repository.createConversation(title: '待删除');

      await repository.deleteConversation(conversation.id);

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

    test('ensureDefaultConversation 幂等且真正创建时仅入队一次 create', () async {
      final first = await repository.ensureDefaultConversation();
      final second = await repository.ensureDefaultConversation();
      expect(first.title, 'AI助手');
      expect(first.id, second.id);
      expect((await repository.getConversations()).length, 1);

      final creates = _opsOf(
        await harness.syncOperationRepository.getPending(),
        'conversation',
        SyncOperationKind.create,
      );
      expect(creates, hasLength(1));
    });

    test('全部软删后 ensureDefaultConversation 重建默认会话（F4）', () async {
      final first = await repository.ensureDefaultConversation();
      await repository.deleteConversation(first.id);
      expect(await repository.getConversations(), isEmpty);

      final rebuilt = await repository.ensureDefaultConversation();
      expect(rebuilt.id, isNot(first.id));
      expect(rebuilt.title, 'AI助手');
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
  });
}

void main() {
  _runContract(
    'MemoryConversationRepository',
    create: (clock) async {
      final store = MemoryStore();
      final syncOps = MemorySyncOperationRepository(
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
        store: store,
      );
      final repository = MemoryConversationRepository(
        syncOperationRepository: syncOps,
        clock: clock,
        userId: 'user-1',
        deviceId: 'device-1',
        store: store,
      );
      return _Harness(repository, syncOps, () async {
        repository.dispose();
        syncOps.dispose();
      });
    },
  );

  _runContract(
    'ConversationRepositoryImpl（Drift 内存库）',
    create: (clock) async {
      final database = AppDatabase(NativeDatabase.memory());
      final syncOps = SyncOperationRepositoryImpl(
        database,
        clock,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      final repository = ConversationRepositoryImpl(
        database,
        clock,
        syncOperationRepository: syncOps,
        userId: 'user-1',
        deviceId: 'device-1',
      );
      return _Harness(repository, syncOps, () async => database.close());
    },
  );
}
