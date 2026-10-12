import 'syncable_entity.dart';

/// 日历中的时间块，可关联一个或多个任务。
class CalendarEntry extends SyncableEntity {
  /// 创建日历条目。
  const CalendarEntry({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.title,
    required this.startAt,
    required this.endAt,
    this.allDay = false,
    this.taskIds = const <String>[],
    this.note,
  });

  /// 标题。
  final String title;

  /// 开始时间。
  final DateTime startAt;

  /// 结束时间。
  final DateTime endAt;

  /// 是否全天事件。
  final bool allDay;

  /// 关联的任务 ID 列表。
  final List<String> taskIds;

  /// 备注。
  final String? note;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  CalendarEntry copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? title,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    List<String>? taskIds,
    String? note,
  }) {
    return CalendarEntry(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      title: title ?? this.title,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      taskIds: taskIds ?? this.taskIds,
      note: note ?? this.note,
    );
  }
}
