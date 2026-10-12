import 'dart:async';

import 'package:characters/characters.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_repository.dart';

/// 内存会话仓储：行为与 Drift 实现一致，供测试与预览使用。
class MemoryConversationRepository implements ConversationRepository {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  MemoryConversationRepository({
    String? userId,
    String? deviceId,
    Clock? clock,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _clock = clock ?? const SystemClock();

  final String _userId;
  final String _deviceId;
  final Clock _clock;
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
  Future<Conversation> createConversation({required String title}) async {
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
    _notify();
    return conversation;
  }

  @override
  Future<Conversation> updateConversation(Conversation conversation) async {
    final index =
        _conversations.indexWhere((item) => item.id == conversation.id);
    if (index < 0) {
      throw const NotFoundException('会话不存在或已被删除');
    }
    final existing = _conversations[index];
    final updated = conversation.copyWith(
      userId: _userId,
      deviceId: _deviceId,
      createdAt: existing.createdAt,
      updatedAt: _clock.now(),
      version: existing.version + 1,
    );
    _conversations[index] = updated;
    _notify();
    return updated;
  }

  @override
  Future<Message> addMessage(Message message) async {
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
      final conversation = _conversations[index];
      _conversations[index] = conversation.copyWith(
        lastMessagePreview: _preview(stored.content),
        lastMessageAt: now,
        updatedAt: now,
        version: conversation.version + 1,
      );
    }
    _notify();
    return stored;
  }

  @override
  Future<void> clearMessages(String conversationId) async {
    // F2：清空消息的同时重置会话摘要（预览、最近消息时间、版本），
    // 与 Drift 实现保持一致。copyWith 无法把可空字段置回 null（见 AGENTS.md），
    // 因此这里显式重建实体。
    _messages.removeWhere(
      (message) => message.conversationId == conversationId,
    );
    final index =
        _conversations.indexWhere((item) => item.id == conversationId);
    if (index >= 0) {
      final existing = _conversations[index];
      _conversations[index] = Conversation(
        id: existing.id,
        userId: existing.userId,
        createdAt: existing.createdAt,
        updatedAt: _clock.now(),
        deletedAt: existing.deletedAt,
        version: existing.version + 1,
        deviceId: existing.deviceId,
        title: existing.title,
        isArchived: existing.isArchived,
      );
    }
    _notify();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final index =
        _conversations.indexWhere((item) => item.id == conversationId);
    if (index < 0) {
      return;
    }
    final conversation = _conversations[index];
    final now = _clock.now();
    _conversations[index] = conversation.copyWith(
      deletedAt: now,
      updatedAt: now,
      version: conversation.version + 1,
    );
    _notify();
  }

  @override
  Future<Conversation> ensureDefaultConversation() async {
    // F4：仅当不存在活跃会话时才创建；全部软删后会重建默认会话。
    final active = _sortedConversations();
    if (active.isNotEmpty) {
      return active.first;
    }
    return createConversation(title: 'AI助手');
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
