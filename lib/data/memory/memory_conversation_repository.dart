import 'dart:async';

import 'package:characters/characters.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/conversation_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'memory_store.dart';

/// 内存会话仓储：行为与 Drift 实现一致，供测试与预览使用。
///
/// 写路径经 [MemoryStore.runAtomic] 包裹，事务中途异常时会话/消息/队列一并还原
/// （§7.2）。装配时若提供 [store] 则注册自身参与全或无回滚。
class MemoryConversationRepository
    implements ConversationRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  MemoryConversationRepository({
    required SyncOperationRepository syncOperationRepository,
    String? userId,
    String? deviceId,
    Clock? clock,
    MemoryStore? store,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock(),
        _syncOperationRepository = syncOperationRepository,
        _memoryStore = store {
    store?.register(this);
  }

  final String _userId;
  final String _deviceId;
  final Clock _clock;
  final SyncOperationRepository _syncOperationRepository;
  final MemoryStore? _memoryStore;
  final List<Conversation> _conversations = <Conversation>[];
  final List<Message> _messages = <Message>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<List<Conversation>> watchConversations() {
    late StreamController<List<Conversation>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<Conversation>>(
      onListen: () {
        controller.add(_sortedConversations());
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_sortedConversations());
          }
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<List<Conversation>> getConversations() async => _sortedConversations();

  @override
  Stream<List<Message>> watchMessages(String conversationId) {
    late StreamController<List<Message>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<Message>>(
      onListen: () {
        controller.add(_sortedMessages(conversationId));
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_sortedMessages(conversationId));
          }
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<List<Message>> getMessages(String conversationId) async =>
      _sortedMessages(conversationId);

  @override
  Future<Conversation?> getConversation(String conversationId) async {
    for (final conversation in _conversations) {
      if (conversation.id == conversationId && conversation.deletedAt == null) {
        return conversation;
      }
    }
    return null;
  }

  @override
  Future<Conversation> createConversation({required String title}) {
    return _atomic(() async {
      final now = _clock.now();
      final conversation = Conversation(
        id: generateId(),
        userId: _userId,
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: _deviceId,
        title: title,
      );
      _conversations.add(conversation);
      await _syncOperationRepository.enqueue(
        buildSyncOperation(
          entity: conversation,
          entityType: 'conversation',
          kind: SyncOperationKind.create,
          userId: _userId,
          deviceId: _deviceId,
          now: now,
        ),
      );
      _notify();
      return conversation;
    });
  }

  @override
  Future<Conversation> updateConversation(Conversation conversation) {
    return _atomic(() async {
      final index =
          _conversations.indexWhere((item) => item.id == conversation.id);
      if (index < 0) {
        throw const NotFoundException('会话不存在或已被删除');
      }
      final existing = _conversations[index];
      final now = _clock.now();
      final updated = conversation.copyWith(
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      _conversations[index] = updated;
      await _syncOperationRepository.enqueue(
        buildSyncOperation(
          entity: updated,
          entityType: 'conversation',
          kind: SyncOperationKind.update,
          userId: _userId,
          deviceId: _deviceId,
          now: now,
        ),
      );
      _notify();
      return updated;
    });
  }

  @override
  Future<Message> addMessage(Message message) {
    return _atomic(() async {
      final now = _clock.now();
      final stored = message.copyWith(
        id: message.id.isEmpty ? generateId() : message.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: now,
        updatedAt: now,
        version: 1,
      );
      _messages.add(stored);
      final index =
          _conversations.indexWhere((item) => item.id == stored.conversationId);
      if (index >= 0) {
        // §7.4：摘要派生字段更新不改 conversation.updatedAt、不 bump version、不入队。
        final conversation = _conversations[index];
        _conversations[index] = conversation.copyWith(
          lastMessagePreview: _preview(stored.content),
          lastMessageAt: now,
        );
      }
      // §7.3：仅消息入队 create（会话摘要为派生数据，不入队）。
      await _syncOperationRepository.enqueue(
        buildSyncOperation(
          entity: stored,
          entityType: 'message',
          kind: SyncOperationKind.create,
          userId: _userId,
          deviceId: _deviceId,
          now: now,
        ),
      );
      _notify();
      return stored;
    });
  }

  @override
  Future<void> clearMessages(String conversationId) {
    // §8：逐条墓碑化（deletedAt/updatedAt/version+1）并入队 delete；
    // 摘要重置遵循 §7.4（不改 updatedAt、不 bump version、不入队）。
    return _atomic(() async {
      final now = _clock.now();
      final operations = <SyncOperation>[];
      for (var i = 0; i < _messages.length; i++) {
        final message = _messages[i];
        if (message.conversationId != conversationId ||
            message.deletedAt != null) {
          continue;
        }
        final tombstone = message.copyWith(
          deletedAt: now,
          updatedAt: now,
          version: message.version + 1,
        );
        _messages[i] = tombstone;
        operations.add(
          buildSyncOperation(
            entity: tombstone,
            entityType: 'message',
            kind: SyncOperationKind.delete,
            userId: _userId,
            deviceId: _deviceId,
            now: now,
          ),
        );
      }
      await _syncOperationRepository.enqueueAll(operations);
      final index =
          _conversations.indexWhere((item) => item.id == conversationId);
      if (index >= 0) {
        final existing = _conversations[index];
        // copyWith 无法把可空字段置回 null（见 AGENTS.md），故显式重建实体。
        _conversations[index] = Conversation(
          id: existing.id,
          userId: existing.userId,
          createdAt: existing.createdAt,
          updatedAt: existing.updatedAt,
          deletedAt: existing.deletedAt,
          version: existing.version,
          deviceId: existing.deviceId,
          title: existing.title,
          isArchived: existing.isArchived,
        );
      }
      _notify();
    });
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    return _atomic(() async {
      final index =
          _conversations.indexWhere((item) => item.id == conversationId);
      if (index < 0) {
        return;
      }
      final conversation = _conversations[index];
      final now = _clock.now();
      final tombstone = conversation.copyWith(
        deletedAt: now,
        updatedAt: now,
        version: conversation.version + 1,
      );
      _conversations[index] = tombstone;
      await _syncOperationRepository.enqueue(
        buildSyncOperation(
          entity: tombstone,
          entityType: 'conversation',
          kind: SyncOperationKind.delete,
          userId: _userId,
          deviceId: _deviceId,
          now: now,
        ),
      );
      _notify();
    });
  }

  @override
  Future<Conversation> ensureDefaultConversation() {
    // F4：仅当不存在活跃会话时才创建；全部软删后会重建默认会话。
    return _atomic(() async {
      final active = _sortedConversations();
      if (active.isNotEmpty) {
        return active.first;
      }
      return createConversation(title: 'AI助手');
    });
  }

  @override
  Object? snapshot() => <Object?>[
        List<Conversation>.of(_conversations),
        List<Message>.of(_messages),
      ];

  @override
  void restore(Object? snapshot) {
    final data = snapshot! as List<Object?>;
    _conversations
      ..clear()
      ..addAll(data[0]! as List<Conversation>);
    _messages
      ..clear()
      ..addAll(data[1]! as List<Message>);
    _notify();
  }

  /// 在 [MemoryStore] 全或无接缝内执行 [action]（无 store 时直接执行）。
  Future<T> _atomic<T>(Future<T> Function() action) {
    final store = _memoryStore;
    return store == null ? action() : store.runAtomic(action);
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _changes.close();
  }

  /// 会话摘要截断到约 50 个字素，避免把 emoji / 组合字符从中间切断（F11）。
  String _preview(String content) {
    const maxLength = 50;
    final graphemes = content.characters;
    return graphemes.length <= maxLength
        ? content
        : graphemes.take(maxLength).toString();
  }

  List<Conversation> _sortedConversations() {
    final active =
        _conversations.where((item) => item.deletedAt == null).toList();
    active.sort((a, b) {
      final aTime = a.lastMessageAt;
      final bTime = b.lastMessageAt;
      if (aTime == null && bTime == null) {
        return b.createdAt.compareTo(a.createdAt);
      }
      if (aTime == null) {
        return 1;
      }
      if (bTime == null) {
        return -1;
      }
      final compared = bTime.compareTo(aTime);
      return compared != 0 ? compared : b.createdAt.compareTo(a.createdAt);
    });
    return List<Conversation>.unmodifiable(active);
  }

  List<Message> _sortedMessages(String conversationId) {
    final list = _messages
        .where(
          (item) =>
              item.conversationId == conversationId && item.deletedAt == null,
        )
        .toList();
    list.sort((a, b) {
      final compared = a.createdAt.compareTo(b.createdAt);
      return compared != 0 ? compared : a.id.compareTo(b.id);
    });
    return List<Message>.unmodifiable(list);
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
