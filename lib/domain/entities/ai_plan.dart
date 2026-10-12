import 'syncable_entity.dart';

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
