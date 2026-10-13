import 'package:uuid/uuid.dart';

import '../../core/errors/app_exception.dart';
import 'syncable_entity.dart';
import 'task.dart';

/// AI 计划状态机：draft → awaitingConfirmation → applied/rejected/expired。
enum AIPlanStatus {
  /// 草稿。
  draft,

  /// 等待用户确认。
  awaitingConfirmation,

  /// 已应用（写入正式任务/日历）。
  applied,

  /// 用户已拒绝。
  rejected,

  /// 已过期。
  expired,
}

/// AI 计划中的变更类型。
enum AIPlanChangeType {
  /// 创建任务。
  createTask,

  /// 更新任务。
  updateTask,

  /// 安排日程。
  scheduleTask,

  /// 删除任务。
  deleteTask,
}

/// AI 计划中的单条变更（值对象）。
class AIPlanChange {
  /// 创建计划变更。
  const AIPlanChange({
    required this.type,
    this.taskId,
    this.calendarEntryId,
    this.payload = const <String, Object?>{},
  });

  /// 变更类型。
  final AIPlanChangeType type;

  /// 关联任务 ID。
  final String? taskId;

  /// 关联日历条目 ID。
  final String? calendarEntryId;

  /// 变更载荷，必须可 JSON 编码。
  final Map<String, Object?> payload;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  AIPlanChange copyWith({
    AIPlanChangeType? type,
    String? taskId,
    String? calendarEntryId,
    Map<String, Object?>? payload,
  }) {
    return AIPlanChange(
      type: type ?? this.type,
      taskId: taskId ?? this.taskId,
      calendarEntryId: calendarEntryId ?? this.calendarEntryId,
      payload: payload ?? this.payload,
    );
  }
}

/// AI 对用户意图的结构化计划，包含待确认的任务变更。
class AIPlan extends SyncableEntity {
  /// 创建 AI 计划。
  const AIPlan({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.conversationId,
    required this.sourceMessageId,
    required this.status,
    required this.aiModel,
    this.aiModelVersion,
    required this.promptVersion,
    this.changes = const <AIPlanChange>[],
    this.confirmedAt,
    this.appliedAt,
    this.rejectedAt,
  });

  /// 来源会话 ID。
  final String conversationId;

  /// 来源消息 ID。
  final String sourceMessageId;

  /// 计划状态。
  final AIPlanStatus status;

  /// 生成计划的模型名。
  final String aiModel;

  /// 模型版本。
  final String? aiModelVersion;

  /// 提示词版本，便于回溯。
  final String promptVersion;

  /// 待确认的变更列表。
  final List<AIPlanChange> changes;

  /// 用户确认时间。
  final DateTime? confirmedAt;

  /// 应用完成时间。
  final DateTime? appliedAt;

  /// 用户拒绝时间。
  final DateTime? rejectedAt;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  AIPlan copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? conversationId,
    String? sourceMessageId,
    AIPlanStatus? status,
    String? aiModel,
    String? aiModelVersion,
    String? promptVersion,
    List<AIPlanChange>? changes,
    DateTime? confirmedAt,
    DateTime? appliedAt,
    DateTime? rejectedAt,
  }) {
    return AIPlan(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      conversationId: conversationId ?? this.conversationId,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      status: status ?? this.status,
      aiModel: aiModel ?? this.aiModel,
      aiModelVersion: aiModelVersion ?? this.aiModelVersion,
      promptVersion: promptVersion ?? this.promptVersion,
      changes: changes ?? this.changes,
      confirmedAt: confirmedAt ?? this.confirmedAt,
      appliedAt: appliedAt ?? this.appliedAt,
      rejectedAt: rejectedAt ?? this.rejectedAt,
    );
  }
}

/// 将计划变更列表编码为 JSON 可序列化的结构。
/// 每条条目：{'type': 枚举.name, 'taskId'?, 'calendarEntryId'?, 'payload': {...}}。
/// payload 键值必须是 JSON 原生类型（String/int/double/bool/null/嵌套 List/Map）。
/// dueAt 由调用方以 ISO 字符串放入 payload —— 本函数只做结构编码，不做类型转换。
Map<String, Object?> _changeToJson(AIPlanChange change) {
  final map = <String, Object?>{
    'type': change.type.name,
    'payload': change.payload,
  };
  if (change.taskId != null) {
    map['taskId'] = change.taskId;
  }
  if (change.calendarEntryId != null) {
    map['calendarEntryId'] = change.calendarEntryId;
  }
  return map;
}

/// 编码 AI 计划变更列表。
Map<String, Object?> encodeChanges(List<AIPlanChange> changes) {
  return <String, Object?>{
    'changes': changes.map(_changeToJson).toList(),
  };
}

/// 将 JSON 解码为计划变更列表。
/// 数据完整性优先：null/非 List、缺 type、type 非已知四枚举均抛 [PlanValidationException]。
/// 与 Conversation metadata 的宽容默认不同，此处要求结构完整。
List<AIPlanChange> decodeChanges(Object? json) {
  if (json == null) {
    throw const PlanValidationException('AI 返回的任务计划格式无效');
  }
  if (json is! Map<String, Object?>) {
    throw const PlanValidationException('AI 返回的任务计划格式无效');
  }
  final rawChanges = json['changes'];
  if (rawChanges is! List<Object?>) {
    throw const PlanValidationException('AI 返回的任务计划格式无效');
  }
  final result = <AIPlanChange>[];
  for (final item in rawChanges) {
    if (item is! Map<String, Object?>) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }
    final typeName = item['type'];
    if (typeName is! String || typeName.isEmpty) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }
    AIPlanChangeType? type;
    for (final t in AIPlanChangeType.values) {
      if (t.name == typeName) {
        type = t;
        break;
      }
    }
    if (type == null) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }
    final payload = item['payload'];
    final payloadMap = payload is Map<String, Object?>
        ? payload
        : <String, Object?>{};
    final taskId = item['taskId'];
    final calendarEntryId = item['calendarEntryId'];
    result.add(
      AIPlanChange(
        type: type,
        taskId: taskId is String ? taskId : null,
        calendarEntryId: calendarEntryId is String ? calendarEntryId : null,
        payload: payloadMap,
      ),
    );
  }
  return result;
}

/// 将 createTask 变更物化为 [Task]。
/// change.type != createTask 时抛 [ConflictException]。
Task taskFromPlanChange(
  AIPlanChange change,
  AIPlan plan, {
  required String userId,
  required String deviceId,
  required DateTime now,
}) {
  if (change.type != AIPlanChangeType.createTask) {
    throw const ConflictException('计划变更类型不匹配，无法物化为任务');
  }
  final payload = change.payload;
  final title = payload['title'];
  if (title is! String || title.isEmpty) {
    throw const PlanValidationException('AI 返回的任务计划格式无效');
  }
  final description = payload['description'];
  final descriptionVal = description is String ? description : null;
  final priorityStr = payload['priority'];
  TaskPriority priority = TaskPriority.medium;
  if (priorityStr is String) {
    final lower = priorityStr.toLowerCase();
    switch (lower) {
      case 'low':
        priority = TaskPriority.low;
        break;
      case 'medium':
        priority = TaskPriority.medium;
        break;
      case 'high':
        priority = TaskPriority.high;
        break;
      case 'urgent':
        priority = TaskPriority.urgent;
        break;
      default:
        throw const PlanValidationException('AI 返回的任务计划格式无效');
    }
  }
  DateTime? dueAt;
  final dueAtStr = payload['dueAt'];
  if (dueAtStr is String) {
    try {
      dueAt = DateTime.parse(dueAtStr).toLocal();
    } catch (_) {
      throw const PlanValidationException('AI 返回的任务计划格式无效');
    }
  }
  const uuid = Uuid();
  return Task(
    id: uuid.v4(),
    userId: userId,
    createdAt: now,
    updatedAt: now,
    version: 1,
    deviceId: deviceId,
    title: title,
    description: descriptionVal,
    status: TaskStatus.inbox,
    priority: priority,
    dueAt: dueAt,
    parentTaskId: null,
    repeatRule: null,
    sourceMessageId: plan.sourceMessageId,
    sortOrder: 0,
  );
}

