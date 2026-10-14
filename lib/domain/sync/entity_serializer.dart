import '../../core/errors/app_exception.dart';
import '../entities/ai_plan.dart';
import '../entities/calendar.dart';
import '../entities/conversation.dart';
import '../entities/syncable_entity.dart';
import '../entities/task.dart';

/// 实体 ↔ 同步 payload 快照（协议冻结，M2b 仅新增 `fromSyncJson`）。
///
/// 通过 extension 在编译期分发，无需依赖注入。`toSyncJson` 返回「实体快照对象
/// 本身」，由调用方 `jsonEncode` 后写入 `SyncOperations.payload` 列；**不回填
/// `entityType`/`entityId`/`kind`**（它们已是 SyncOperation 的列，避免漂移）。
/// `fromSyncJson` 为 M2b 新增的反序列化入口，严格往返 `toSyncJson`（§6.4）。
///
/// 通用约定：
/// - 时间一律 UTC ISO8601（`toUtc().toIso8601String()`，带 `Z`）。
/// - 枚举取 `.name` 字符串；bool 为 JSON bool；`List<String>` 为 JSON 数组。
/// - 可空字段为 null 则省略该键（不写 null）。
/// - delete 快照必须含 `deletedAt`（墓碑时间，供 M2b 排序/冲突判定）。
/// - 派生字段不进快照：`Conversation.lastMessagePreview`/`lastMessageAt`。
///
/// 反序列化错误（A8）：结构/类型/枚举非法统一抛 [SyncDecodeException]；
/// `AIPlan.changes` 内部沿用既有 [PlanValidationException] 并由其包装。
extension ConversationSync on Conversation {
  /// 会话快照；排除客户端派生的 lastMessagePreview/lastMessageAt。
  Map<String, Object?> toSyncJson() {
    return <String, Object?>{
      ..._syncBase(this),
      'title': title,
      'isArchived': isArchived,
    };
  }

  /// 从同步快照反序列化会话；派生字段（预览/时间）不在快照内，恒为 null。
  static Conversation fromSyncJson(Map<String, Object?> json) {
    return Conversation(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      title: _requireString(json, 'title'),
      isArchived: _requireBool(json, 'isArchived'),
    );
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

  /// 从同步快照反序列化消息；缺失的可空字段还原为 null，metadata 缺失还原为空 Map。
  static Message fromSyncJson(Map<String, Object?> json) {
    return Message(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      conversationId: _requireString(json, 'conversationId'),
      role: _requireEnum(json, 'role', MessageRole.values),
      type: _requireEnum(json, 'type', MessageType.values),
      content: _requireString(json, 'content'),
      status: _requireEnum(json, 'status', MessageStatus.values),
      aiModel: _optionalString(json, 'aiModel'),
      metadata: _optionalMap(json, 'metadata'),
    );
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

  /// 从同步快照反序列化任务；缺失的可空字段（含 dueAt）还原为 null。
  static Task fromSyncJson(Map<String, Object?> json) {
    return Task(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      projectId: _optionalString(json, 'projectId'),
      title: _requireString(json, 'title'),
      description: _optionalString(json, 'description'),
      status: _requireEnum(json, 'status', TaskStatus.values),
      priority: _requireEnum(json, 'priority', TaskPriority.values),
      dueAt: _optionalDateTime(json, 'dueAt'),
      parentTaskId: _optionalString(json, 'parentTaskId'),
      repeatRule: _optionalString(json, 'repeatRule'),
      sourceMessageId: _optionalString(json, 'sourceMessageId'),
      sortOrder: _requireInt(json, 'sortOrder'),
    );
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

  /// 从同步快照反序列化项目；goal 缺失还原为 null。
  static Project fromSyncJson(Map<String, Object?> json) {
    return Project(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      name: _requireString(json, 'name'),
      goal: _optionalString(json, 'goal'),
      isArchived: _requireBool(json, 'isArchived'),
    );
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

  /// 从同步快照反序列化 AI 计划。
  ///
  /// `changes` 复用 [decodeChanges]；其抛出的 [PlanValidationException]
  /// 由 [SyncDecodeException] 包装（A8，不泄露实现细节）。
  static AIPlan fromSyncJson(Map<String, Object?> json) {
    final List<AIPlanChange> changes;
    try {
      changes = decodeChanges(json);
    } on PlanValidationException catch (error) {
      throw SyncDecodeException('同步快照字段 changes 非法', cause: error);
    }
    return AIPlan(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      conversationId: _requireString(json, 'conversationId'),
      sourceMessageId: _requireString(json, 'sourceMessageId'),
      status: _requireEnum(json, 'status', AIPlanStatus.values),
      aiModel: _requireString(json, 'aiModel'),
      aiModelVersion: _optionalString(json, 'aiModelVersion'),
      promptVersion: _requireString(json, 'promptVersion'),
      changes: changes,
      confirmedAt: _optionalDateTime(json, 'confirmedAt'),
      appliedAt: _optionalDateTime(json, 'appliedAt'),
      rejectedAt: _optionalDateTime(json, 'rejectedAt'),
      expiredAt: _optionalDateTime(json, 'expiredAt'),
    );
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

  /// 从同步快照反序列化日历条目；taskIds 还原为字符串数组，note 缺失为 null。
  static CalendarEntry fromSyncJson(Map<String, Object?> json) {
    return CalendarEntry(
      id: _requireString(json, 'id'),
      userId: _requireString(json, 'userId'),
      createdAt: _requireDateTime(json, 'createdAt'),
      updatedAt: _requireDateTime(json, 'updatedAt'),
      deletedAt: _optionalDateTime(json, 'deletedAt'),
      version: _requireInt(json, 'version'),
      deviceId: _requireString(json, 'deviceId'),
      title: _requireString(json, 'title'),
      startAt: _requireDateTime(json, 'startAt'),
      endAt: _requireDateTime(json, 'endAt'),
      allDay: _requireBool(json, 'allDay'),
      taskIds: _requireStringList(json, 'taskIds'),
      note: _optionalString(json, 'note'),
    );
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

// ---------------------------------------------------------------------------
// fromSyncJson 辅助：类型/结构校验失败统一抛 [SyncDecodeException]（A8）。
// ---------------------------------------------------------------------------

/// 字段非法时的统一错误文案。
String _fieldError(String key) => '同步快照字段 $key 非法';

/// 读取必填字符串字段；缺失或类型非法抛 [SyncDecodeException]。
String _requireString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

/// 读取可选字符串字段；缺失为 null，非 null 但类型非法抛 [SyncDecodeException]。
String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

/// 读取必填整数字段；缺失或类型非法抛 [SyncDecodeException]。
int _requireInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

/// 读取必填布尔字段；缺失或类型非法抛 [SyncDecodeException]。
bool _requireBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

/// 读取必填时间字段（UTC ISO8601 字符串）并还原为本地 [DateTime]；
/// 缺失/非字符串/不可解析一律抛 [SyncDecodeException]。
DateTime _requireDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw SyncDecodeException(_fieldError(key));
  }
  return parsed.toLocal();
}

/// 读取可选时间字段；缺失为 null，非 null 但非法抛 [SyncDecodeException]。
DateTime? _optionalDateTime(Map<String, Object?> json, String key) {
  if (json[key] == null) {
    return null;
  }
  return _requireDateTime(json, key);
}

/// 读取必填枚举字段（`byName`）；缺失/未知名称抛 [SyncDecodeException]。
T _requireEnum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) {
  final value = json[key];
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  for (final candidate in values) {
    if (candidate.name == value) {
      return candidate;
    }
  }
  throw SyncDecodeException(_fieldError(key));
}

/// 读取必填 `List<String>` 字段；非 List 或含非字符串项抛 [SyncDecodeException]。
List<String> _requireStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw SyncDecodeException(_fieldError(key));
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String) {
      throw SyncDecodeException(_fieldError(key));
    }
    result.add(item);
  }
  return result;
}

/// 读取可选 Map 字段（缺失还原为空 Map）；类型非法抛 [SyncDecodeException]。
Map<String, Object?> _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return const <String, Object?>{};
  }
  if (value is! Map) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value.map<String, Object?>(
    (Object? mapKey, Object? mapValue) =>
        MapEntry<String, Object?>(mapKey.toString(), mapValue),
  );
}
