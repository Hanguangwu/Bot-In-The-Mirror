import '../entities/ai_plan.dart';
import '../entities/calendar.dart';
import '../entities/conversation.dart';
import '../entities/syncable_entity.dart';
import '../entities/task.dart';

/// 实体 → 同步 payload 快照（协议冻结，M2b 不得改）。
///
/// 通过 extension 在编译期分发，无需依赖注入。返回值为「实体快照对象本身」，
/// 由调用方 `jsonEncode` 后写入 `SyncOperations.payload` 列；**不回填
/// `entityType`/`entityId`/`kind`**（它们已是 SyncOperation 的列，避免漂移）。
///
/// 通用约定：
/// - 时间一律 UTC ISO8601（`toUtc().toIso8601String()`，带 `Z`）。
/// - 枚举取 `.name` 字符串；bool 为 JSON bool；`List<String>` 为 JSON 数组。
/// - 可空字段为 null 则省略该键（不写 null）。
/// - delete 快照必须含 `deletedAt`（墓碑时间，供 M2b 排序/冲突判定）。
/// - 派生字段不进快照：`Conversation.lastMessagePreview`/`lastMessageAt`。
/// - 本期只实现 `toSyncJson`，不实现 `fromSyncJson`（YAGNI）。
extension ConversationSync on Conversation {
  /// 会话快照；排除客户端派生的 lastMessagePreview/lastMessageAt。
  Map<String, Object?> toSyncJson() {
    return <String, Object?>{
      ..._syncBase(this),
      'title': title,
      'isArchived': isArchived,
    };
  }
}

/// [Message] 的同步快照。
extension MessageSync on Message {
  /// 消息快照；metadata 原样放入。
  Map<String, Object?> toSyncJson() {
    final map = <String, Object?>{
      ..._syncBase(this),
      'conversationId': conversationId,
      'role': role.name,
      'type': type.name,
      'content': content,
      'status': status.name,
      'metadata': metadata,
    };
    _putIfNotNull(map, 'aiModel', aiModel);
    return map;
  }
}

/// [Task] 的同步快照。
extension TaskSync on Task {
  /// 任务快照。
  Map<String, Object?> toSyncJson() {
    final map = <String, Object?>{
      ..._syncBase(this),
      'title': title,
      'status': status.name,
      'priority': priority.name,
      'sortOrder': sortOrder,
    };
    _putIfNotNull(map, 'projectId', projectId);
    _putIfNotNull(map, 'description', description);
    _putIfNotNull(map, 'dueAt', _utcOrNull(dueAt));
    _putIfNotNull(map, 'parentTaskId', parentTaskId);
    _putIfNotNull(map, 'repeatRule', repeatRule);
    _putIfNotNull(map, 'sourceMessageId', sourceMessageId);
    return map;
  }
}

/// [Project] 的同步快照。
extension ProjectSync on Project {
  /// 项目快照。
  Map<String, Object?> toSyncJson() {
    final map = <String, Object?>{
      ..._syncBase(this),
      'name': name,
      'isArchived': isArchived,
    };
    _putIfNotNull(map, 'goal', goal);
    return map;
  }
}

/// [AIPlan] 的同步快照。
extension AIPlanSync on AIPlan {
  /// 计划快照；changes 复用 [encodeChanges] 的条目编码（纯 JSON 类型）。
  Map<String, Object?> toSyncJson() {
    final map = <String, Object?>{
      ..._syncBase(this),
      'conversationId': conversationId,
      'sourceMessageId': sourceMessageId,
      'status': status.name,
      'aiModel': aiModel,
      'promptVersion': promptVersion,
      'changes': encodeChanges(changes)['changes'],
    };
    _putIfNotNull(map, 'aiModelVersion', aiModelVersion);
    _putIfNotNull(map, 'confirmedAt', _utcOrNull(confirmedAt));
    _putIfNotNull(map, 'appliedAt', _utcOrNull(appliedAt));
    _putIfNotNull(map, 'rejectedAt', _utcOrNull(rejectedAt));
    _putIfNotNull(map, 'expiredAt', _utcOrNull(expiredAt));
    return map;
  }
}

/// [CalendarEntry] 的同步快照。
extension CalendarEntrySync on CalendarEntry {
  /// 日历条目快照；taskIds 为 JSON 字符串数组。
  Map<String, Object?> toSyncJson() {
    final map = <String, Object?>{
      ..._syncBase(this),
      'title': title,
      'startAt': startAt.toUtc().toIso8601String(),
      'endAt': endAt.toUtc().toIso8601String(),
      'allDay': allDay,
      'taskIds': List<String>.of(taskIds),
    };
    _putIfNotNull(map, 'note', note);
    return map;
  }
}

/// Syncable 公共七字段；deletedAt 为空则省略。
Map<String, Object?> _syncBase(SyncableEntity entity) {
  final map = <String, Object?>{
    'id': entity.id,
    'userId': entity.userId,
    'createdAt': entity.createdAt.toUtc().toIso8601String(),
    'updatedAt': entity.updatedAt.toUtc().toIso8601String(),
    'version': entity.version,
    'deviceId': entity.deviceId,
  };
  final deletedAt = entity.deletedAt;
  if (deletedAt != null) {
    map['deletedAt'] = deletedAt.toUtc().toIso8601String();
  }
  return map;
}

/// 仅在非 null 时写入键（空值省略语义）。
void _putIfNotNull(Map<String, Object?> map, String key, Object? value) {
  if (value != null) {
    map[key] = value;
  }
}

/// 时间转 UTC ISO8601；输入为 null 时返回 null。
String? _utcOrNull(DateTime? value) => value?.toUtc().toIso8601String();
