import 'package:characters/characters.dart';
import 'package:drift/drift.dart';

import '../../core/errors/app_exception.dart';
import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/conversation_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'app_database.dart';

/// 基于 Drift 的会话仓储实现。
///
/// 写入时由实现统一补齐/覆盖 `id`、`userId`、`deviceId`、`createdAt`、
/// `updatedAt`、`version`，保证同步字段一致。
class ConversationRepositoryImpl implements ConversationRepository {
  /// 创建仓储；[userId]/[deviceId] 在本实例内固定。
  ConversationRepositoryImpl(
    this._db,
    this._clock, {
    required SyncOperationRepository syncOperationRepository,
    String? userId,
    String? deviceId,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _syncOperationRepository = syncOperationRepository;

  final AppDatabase _db;
  final Clock _clock;
  final String _userId;
  final String _deviceId;
  final SyncOperationRepository _syncOperationRepository;

  @override
  Stream<List<Conversation>> watchConversations() {
    final query = _db.select(_db.conversations)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.lastMessageAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    return query.watch().map(
          (rows) => rows.map(_toConversation).toList(growable: false),
        );
  }

  @override
  Future<List<Conversation>> getConversations() async {
    final rows = await (_db.select(_db.conversations)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.lastMessageAt, mode: OrderingMode.desc),
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
    return rows.map(_toConversation).toList(growable: false);
  }

  @override
  Stream<List<Message>> watchMessages(String conversationId) {
    final query = _db.select(_db.messages)
      ..where(
        (t) => t.conversationId.equals(conversationId) & t.deletedAt.isNull(),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch().map(
          (rows) => rows.map(_toMessage).toList(growable: false),
        );
  }

  @override
  Future<List<Message>> getMessages(String conversationId) async {
    final rows = await (_db.select(_db.messages)
          ..where(
            (t) =>
                t.conversationId.equals(conversationId) & t.deletedAt.isNull(),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    return rows.map(_toMessage).toList(growable: false);
  }

  @override
  Future<Conversation?> getConversation(String conversationId) async {
    final row = await (_db.select(_db.conversations)
          ..where(
            (t) => t.id.equals(conversationId) & t.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    return row == null ? null : _toConversation(row);
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
    await _db.transaction(() async {
      await _db
          .into(_db.conversations)
          .insert(_toConversationCompanion(conversation));
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
    });
    return conversation;
  }

  @override
  Future<Conversation> updateConversation(Conversation conversation) async {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.conversations)
            ..where((t) => t.id.equals(conversation.id)))
          .getSingleOrNull();
      if (existing == null) {
        throw const NotFoundException('会话不存在或已被删除');
      }
      final now = _clock.now();
      final updated = conversation.copyWith(
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _db
          .into(_db.conversations)
          .insertOnConflictUpdate(_toConversationCompanion(updated));
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
      return updated;
    });
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
    await _db.transaction(() async {
      await _db.into(_db.messages).insert(_toMessageCompanion(stored));
      final conversation = await (_db.select(_db.conversations)
            ..where((t) => t.id.equals(stored.conversationId)))
          .getSingleOrNull();
      if (conversation != null) {
        // §7.4：摘要派生字段更新不改 conversation.updatedAt、不 bump version、不入队。
        await (_db.update(_db.conversations)
              ..where((t) => t.id.equals(conversation.id)))
            .write(
          ConversationsCompanion(
            lastMessagePreview: Value(_preview(stored.content)),
            lastMessageAt: Value(now),
          ),
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
    });
    return stored;
  }

  @override
  Future<void> clearMessages(String conversationId) async {
    // §8：物理删除改为墓碑化（deletedAt/updatedAt/version+1），并逐条入队 message
    // delete；会话摘要重置遵循 §7.4（不改 updatedAt、不 bump version、不入队）。
    await _db.transaction(() async {
      final now = _clock.now();
      final rows = await (_db.select(_db.messages)
            ..where(
              (t) =>
                  t.conversationId.equals(conversationId) & t.deletedAt.isNull(),
            ))
          .get();
      final operations = <SyncOperation>[];
      for (final row in rows) {
        await (_db.update(_db.messages)..where((t) => t.id.equals(row.id)))
            .write(
          MessagesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            version: Value(row.version + 1),
          ),
        );
        operations.add(
          buildSyncOperation(
            entity: _toMessage(row).copyWith(
              deletedAt: now,
              updatedAt: now,
              version: row.version + 1,
            ),
            entityType: 'message',
            kind: SyncOperationKind.delete,
            userId: _userId,
            deviceId: _deviceId,
            now: now,
          ),
        );
      }
      await _syncOperationRepository.enqueueAll(operations);
      final conversation = await (_db.select(_db.conversations)
            ..where((t) => t.id.equals(conversationId)))
          .getSingleOrNull();
      if (conversation == null) {
        return;
      }
      await (_db.update(_db.conversations)
            ..where((t) => t.id.equals(conversationId)))
          .write(
        ConversationsCompanion(
          lastMessagePreview: const Value<String?>(null),
          lastMessageAt: const Value<DateTime?>(null),
        ),
      );
    });
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    await _db.transaction(() async {
      final existing = await (_db.select(_db.conversations)
            ..where((t) => t.id.equals(conversationId)))
          .getSingleOrNull();
      if (existing == null) {
        return;
      }
      final now = _clock.now();
      // 墓碑快照须含 deletedAt（§6/§7.3）。
      final tombstone = _toConversation(existing).copyWith(
        deletedAt: now,
        updatedAt: now,
        version: existing.version + 1,
      );
      await (_db.update(_db.conversations)
            ..where((t) => t.id.equals(conversationId)))
          .write(
        ConversationsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
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
    });
  }

  @override
  Future<Conversation> ensureDefaultConversation() async {
    // F4：仅当不存在活跃（deletedAt 为 null）会话时才创建；全部软删后会重建默认会话。
    // §7.1：整个「查找或创建」包在同一事务内；createConversation 入队 create。
    return _db.transaction(() async {
      final active = await (_db.select(_db.conversations)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([
              (t) => OrderingTerm(
                    expression: t.lastMessageAt,
                    mode: OrderingMode.desc,
                  ),
              (t) => OrderingTerm(
                    expression: t.createdAt,
                    mode: OrderingMode.desc,
                  ),
            ]))
          .get();
      if (active.isNotEmpty) {
        return _toConversation(active.first);
      }
      return createConversation(title: 'AI助手');
    });
  }

  /// 会话摘要截断到约 50 个字素，避免把 emoji / 组合字符从中间切断（F11）。
  String _preview(String content) {
    const maxLength = 50;
    final graphemes = content.characters;
    return graphemes.length <= maxLength
        ? content
        : graphemes.take(maxLength).toString();
  }

  Conversation _toConversation(ConversationRow row) => Conversation(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        title: row.title,
        isArchived: row.isArchived,
        lastMessagePreview: row.lastMessagePreview,
        lastMessageAt: row.lastMessageAt,
      );

  Message _toMessage(MessageRow row) => Message(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        conversationId: row.conversationId,
        role: MessageRole.values.byName(row.role),
        type: MessageType.values.byName(row.type),
        content: row.content,
        status: MessageStatus.values.byName(row.status),
        aiModel: row.aiModel,
        metadata: decodeMetadata(row.metadata),
      );

  ConversationsCompanion _toConversationCompanion(Conversation c) =>
      ConversationsCompanion(
        id: Value(c.id),
        userId: Value(c.userId),
        title: Value(c.title),
        isArchived: Value(c.isArchived),
        lastMessagePreview: Value(c.lastMessagePreview),
        lastMessageAt: Value(c.lastMessageAt),
        createdAt: Value(c.createdAt),
        updatedAt: Value(c.updatedAt),
        deletedAt: Value(c.deletedAt),
        version: Value(c.version),
        deviceId: Value(c.deviceId),
      );

  MessagesCompanion _toMessageCompanion(Message m) => MessagesCompanion(
        id: Value(m.id),
        conversationId: Value(m.conversationId),
        userId: Value(m.userId),
        role: Value(m.role.name),
        type: Value(m.type.name),
        content: Value(m.content),
        status: Value(m.status.name),
        aiModel: Value(m.aiModel),
        metadata: Value(encodeMetadata(m.metadata)),
        createdAt: Value(m.createdAt),
        updatedAt: Value(m.updatedAt),
        deletedAt: Value(m.deletedAt),
        version: Value(m.version),
        deviceId: Value(m.deviceId),
      );
}
