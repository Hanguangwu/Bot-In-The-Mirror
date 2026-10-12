import 'syncable_entity.dart';

/// 任务状态。生命周期：inbox → planned → doing → done，另有 cancelled。
enum TaskStatus {
  /// 收件箱（默认落点）。
  inbox,

  /// 已计划。
  planned,

  /// 进行中。
  doing,

  /// 已完成。
  done,

  /// 已取消。
  cancelled,
}

/// 任务优先级。
enum TaskPriority {
  /// 低。
  low,

  /// 中。
  medium,

  /// 高。
  high,

  /// 紧急。
  urgent,
}

/// 可执行事项。
class Task extends SyncableEntity {
  /// 创建任务实体。
  const Task({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    this.projectId,
    required this.title,
    this.description,
    this.status = TaskStatus.inbox,
    this.priority = TaskPriority.medium,
    this.dueAt,
    this.parentTaskId,
    this.repeatRule,
    this.sourceMessageId,
    this.sortOrder = 0,
  });

  /// 所属项目 ID。
  final String? projectId;

  /// 任务标题。
  final String title;

  /// 详细描述。
  final String? description;

  /// 状态。
  final TaskStatus status;

  /// 优先级。
  final TaskPriority priority;

  /// 截止时间。
  final DateTime? dueAt;

  /// 父任务 ID（支持子任务）。
  final String? parentTaskId;

  /// 重复规则（RRULE 风格的字符串，M2 起使用）。
  final String? repeatRule;

  /// 来源消息 ID，用于追溯到原始对话。
  final String? sourceMessageId;

  /// 手动排序值，越小越靠前。
  final int sortOrder;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Task copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? projectId,
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? dueAt,
    String? parentTaskId,
    String? repeatRule,
    String? sourceMessageId,
    int? sortOrder,
  }) {
    return Task(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      projectId: projectId ?? this.projectId,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      dueAt: dueAt ?? this.dueAt,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      repeatRule: repeatRule ?? this.repeatRule,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

/// 任务集合。
class Project extends SyncableEntity {
  /// 创建项目实体。
  const Project({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.name,
    this.goal,
    this.isArchived = false,
  });

  /// 项目名称。
  final String name;

  /// 项目目标。
  final String? goal;

  /// 是否归档。
  final bool isArchived;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Project copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? name,
    String? goal,
    bool? isArchived,
  }) {
    return Project(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      goal: goal ?? this.goal,
      isArchived: isArchived ?? this.isArchived,
    );
  }
}

/// 任务查询条件（值对象）。所有字段为空表示不过滤。
class TaskQuery {
  /// 创建任务查询条件。
  const TaskQuery({
    this.status,
    this.projectId,
    this.dueFrom,
    this.dueTo,
    this.text,
  });

  /// 过滤状态。
  final TaskStatus? status;

  /// 过滤项目。
  final String? projectId;

  /// 截止时间下界（含）。
  final DateTime? dueFrom;

  /// 截止时间上界（含）。
  final DateTime? dueTo;

  /// 标题/描述文本模糊匹配。
  final String? text;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  TaskQuery copyWith({
    TaskStatus? status,
    String? projectId,
    DateTime? dueFrom,
    DateTime? dueTo,
    String? text,
  }) {
    return TaskQuery(
      status: status ?? this.status,
      projectId: projectId ?? this.projectId,
      dueFrom: dueFrom ?? this.dueFrom,
      dueTo: dueTo ?? this.dueTo,
      text: text ?? this.text,
    );
  }
}

/// 任务变更事件（sealed），供批量应用与同步使用。
sealed class TaskChange {
  /// 创建任务变更事件基类。
  const TaskChange();
}

/// 新增任务。
class TaskInserted extends TaskChange {
  /// 创建新增事件。
  const TaskInserted(this.task);

  /// 新增的任务。
  final Task task;
}

/// 更新任务。
class TaskUpdated extends TaskChange {
  /// 创建更新事件。
  const TaskUpdated(this.task);

  /// 更新后的任务。
  final Task task;
}

/// 删除任务。
class TaskDeleted extends TaskChange {
  /// 创建删除事件。
  const TaskDeleted(this.id);

  /// 被删除任务的 ID。
  final String id;
}
