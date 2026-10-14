import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/task.dart';
import '../../domain/sync/entity_serializer.dart';
import '../../domain/sync/lww.dart';
import '../../domain/sync/sync_change.dart';
import '../../domain/sync/sync_entity_store.dart';
import 'app_database.dart';

/// 基于 Drift 的远端变更应用实现（§6.3）。
///
/// **不经仓储写路径、不入同步队列**：按 `entityType` 分派到六张表直接写入，
/// 以 LWW（[acceptVersion]）决定是否落地；`payload` 含非空 `deletedAt` 即写墓碑。
///
/// `conversation` 必须**列级写入**：快照已排除客户端派生的
/// `lastMessagePreview`/`lastMessageAt`，行已存在时只更新快照含有的列，保留本地
/// 派生列；本地无该行则插入、派生列留空（B5）。
///
/// 未知 `entityType` → 返回 false 且不崩。
class SyncEntityStoreImpl implements SyncEntityStore {
  /// 创建实现；[db] 必须为应用共享的 [AppDatabase] 单例。
  SyncEntityStoreImpl(this._db);

  final AppDatabase _db;

  @override
  Future<bool> applyRemote(SyncChange change) async {
    switch (change.entityType) {
      case 'conversation':
        return _applyConversation(
          ConversationSync.fromSyncJson(change.payload),
        );
      case 'message':
        return _applyMessage(MessageSync.fromSyncJson(change.payload));
      case 'task':
        return _applyTask(TaskSync.fromSyncJson(change.payload));
      case 'ai_plan':
        return _applyAIPlan(AIPlanSync.fromSyncJson(change.payload));
      case 'calendar_entry':
        return _applyCalendarEntry(
          CalendarEntrySync.fromSyncJson(change.payload),
        );
      case 'project':
        return _applyProject(ProjectSync.fromSyncJson(change.payload));
      default:
        return false;
    }
  }

  @override
  Future<({int version, DateTime updatedAt})?> localVersion(
    String entityType,
    String entityId,
  ) {
    switch (entityType) {
      case 'conversation':
        return _conversationVersion(entityId);
      case 'message':
        return _messageVersion(entityId);
      case 'task':
        return _taskVersion(entityId);
      case 'ai_plan':
        return _aiPlanVersion(entityId);
      case 'calendar_entry':
        return _calendarVersion(entityId);
      case 'project':
        return _projectVersion(entityId);
      default:
        return Future<({int version, DateTime updatedAt})?>.value(null);
    }
  }

  // ---- conversation（列级写入，保留派生列） ----

  Future<bool> _applyConversation(Conversation entity) async {
    final stored = await _conversationVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    if (stored == null) {
      // 本地无该行：插入，派生列留空。
      await _db.into(_db.conversations).insert(_conversationInsert(entity));
    } else {
      // 行已存在：仅更新快照含有的列，保留 lastMessagePreview/lastMessageAt。
      await (_db.update(_db.conversations)
            ..where((t) => t.id.equals(entity.id)))
          .write(_conversationSnapshot(entity));
    }
    return true;
  }

  ConversationsCompanion _conversationInsert(Conversation c) =>
      ConversationsCompanion.insert(
        id: c.id,
        userId: c.userId,
        title: c.title,
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
        deviceId: c.deviceId,
        isArchived: Value(c.isArchived),
        lastMessagePreview: Value(c.lastMessagePreview),
        lastMessageAt: Value(c.lastMessageAt),
        deletedAt: Value(c.deletedAt),
        version: Value(c.version),
      );

  /// 仅快照含有的列（不含派生列），供已存在行更新。
  ConversationsCompanion _conversationSnapshot(Conversation c) =>
      ConversationsCompanion(
        userId: Value(c.userId),
        title: Value(c.title),
        isArchived: Value(c.isArchived),
        createdAt: Value(c.createdAt),
        updatedAt: Value(c.updatedAt),
        deletedAt: Value(c.deletedAt),
        version: Value(c.version),
        deviceId: Value(c.deviceId),
      );

  Future<({int version, DateTime updatedAt})?> _conversationVersion(
    String id,
  ) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.conversations)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  // ---- message ----

  Future<bool> _applyMessage(Message entity) async {
    final stored = await _messageVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    await _db.into(_db.messages).insertOnConflictUpdate(
          MessagesCompanion(
            id: Value(entity.id),
            conversationId: Value(entity.conversationId),
            userId: Value(entity.userId),
            role: Value(entity.role.name),
            type: Value(entity.type.name),
            content: Value(entity.content),
            status: Value(entity.status.name),
            aiModel: Value(entity.aiModel),
            metadata: Value(encodeMetadata(entity.metadata)),
            createdAt: Value(entity.createdAt),
            updatedAt: Value(entity.updatedAt),
            deletedAt: Value(entity.deletedAt),
            version: Value(entity.version),
            deviceId: Value(entity.deviceId),
          ),
        );
    return true;
  }

  Future<({int version, DateTime updatedAt})?> _messageVersion(
    String id,
  ) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.messages)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  // ---- task ----

  Future<bool> _applyTask(Task entity) async {
    final stored = await _taskVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    await _db.into(_db.tasks).insertOnConflictUpdate(
          TasksCompanion(
            id: Value(entity.id),
            userId: Value(entity.userId),
            createdAt: Value(entity.createdAt),
            updatedAt: Value(entity.updatedAt),
            deletedAt: Value(entity.deletedAt),
            version: Value(entity.version),
            deviceId: Value(entity.deviceId),
            projectId: Value(entity.projectId),
            title: Value(entity.title),
            description: Value(entity.description),
            status: Value(entity.status.name),
            priority: Value(entity.priority.name),
            dueAt: Value(entity.dueAt),
            parentTaskId: Value(entity.parentTaskId),
            repeatRule: Value(entity.repeatRule),
            sourceMessageId: Value(entity.sourceMessageId),
            sortOrder: Value(entity.sortOrder),
          ),
        );
    return true;
  }

  Future<({int version, DateTime updatedAt})?> _taskVersion(String id) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  // ---- ai_plan ----

  Future<bool> _applyAIPlan(AIPlan entity) async {
    final stored = await _aiPlanVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    await _db.into(_db.aiPlans).insertOnConflictUpdate(
          AiPlansCompanion(
            id: Value(entity.id),
            userId: Value(entity.userId),
            createdAt: Value(entity.createdAt),
            updatedAt: Value(entity.updatedAt),
            deletedAt: Value(entity.deletedAt),
            version: Value(entity.version),
            deviceId: Value(entity.deviceId),
            conversationId: Value(entity.conversationId),
            sourceMessageId: Value(entity.sourceMessageId),
            status: Value(entity.status.name),
            aiModel: Value(entity.aiModel),
            aiModelVersion: Value(entity.aiModelVersion),
            promptVersion: Value(entity.promptVersion),
            changes: Value(jsonEncode(encodeChanges(entity.changes))),
            confirmedAt: Value(entity.confirmedAt),
            appliedAt: Value(entity.appliedAt),
            rejectedAt: Value(entity.rejectedAt),
            expiredAt: Value(entity.expiredAt),
          ),
        );
    return true;
  }

  Future<({int version, DateTime updatedAt})?> _aiPlanVersion(String id) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.aiPlans)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  // ---- calendar_entry ----

  Future<bool> _applyCalendarEntry(CalendarEntry entity) async {
    final stored = await _calendarVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    await _db.into(_db.calendarEntries).insertOnConflictUpdate(
          CalendarEntriesCompanion(
            id: Value(entity.id),
            userId: Value(entity.userId),
            createdAt: Value(entity.createdAt),
            updatedAt: Value(entity.updatedAt),
            deletedAt: Value(entity.deletedAt),
            version: Value(entity.version),
            deviceId: Value(entity.deviceId),
            title: Value(entity.title),
            startAt: Value(entity.startAt),
            endAt: Value(entity.endAt),
            allDay: Value(entity.allDay),
            taskIds: Value(jsonEncode(entity.taskIds)),
            note: Value(entity.note),
          ),
        );
    return true;
  }

  Future<({int version, DateTime updatedAt})?> _calendarVersion(
    String id,
  ) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.calendarEntries)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  // ---- project ----

  Future<bool> _applyProject(Project entity) async {
    final stored = await _projectVersion(entity.id);
    if (!_accept(entity.version, entity.updatedAt, stored)) {
      return false;
    }
    await _db.into(_db.projects).insertOnConflictUpdate(
          ProjectsCompanion(
            id: Value(entity.id),
            userId: Value(entity.userId),
            createdAt: Value(entity.createdAt),
            updatedAt: Value(entity.updatedAt),
            deletedAt: Value(entity.deletedAt),
            version: Value(entity.version),
            deviceId: Value(entity.deviceId),
            name: Value(entity.name),
            goal: Value(entity.goal),
            isArchived: Value(entity.isArchived),
          ),
        );
    return true;
  }

  Future<({int version, DateTime updatedAt})?> _projectVersion(String id) async {
    if (id.isEmpty) {
      return null;
    }
    final row = await (_db.select(_db.projects)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (version: row.version, updatedAt: row.updatedAt);
  }

  /// LWW 判定（§7.1）；委托 [acceptVersion] 统一语义。
  bool _accept(
    int incomingVersion,
    DateTime incomingUpdatedAt,
    ({int version, DateTime updatedAt})? stored,
  ) {
    return acceptVersion(
      incomingVersion: incomingVersion,
      incomingUpdatedAt: incomingUpdatedAt,
      storedVersion: stored?.version,
      storedUpdatedAt: stored?.updatedAt,
    );
  }
}
