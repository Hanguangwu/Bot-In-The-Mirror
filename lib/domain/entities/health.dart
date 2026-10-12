import 'syncable_entity.dart';

/// 健康记录类型。健康功能仅做记录、趋势与习惯反馈，不替代医疗建议。
enum HealthRecordType {
  /// 饮食。
  meal,

  /// 热量。
  calorie,

  /// 运动。
  exercise,

  /// 体重。
  weight,

  /// 其他。
  other,
}

/// 健康记录。
class HealthRecord extends SyncableEntity {
  /// 创建健康记录。
  const HealthRecord({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.type,
    required this.title,
    this.value = const <String, Object?>{},
    required this.occurredAt,
    required this.source,
    this.confidence,
    this.note,
  });

  /// 记录类型。
  final HealthRecordType type;

  /// 标题。
  final String title;

  /// 结构化取值，必须可 JSON 编码（如份量、热量范围）。
  final Map<String, Object?> value;

  /// 发生时间。
  final DateTime occurredAt;

  /// 来源：manual / ai / vision。
  final String source;

  /// 置信度（AI/视觉识别时使用，0~1）。
  final double? confidence;

  /// 备注。
  final String? note;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  HealthRecord copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    HealthRecordType? type,
    String? title,
    Map<String, Object?>? value,
    DateTime? occurredAt,
    String? source,
    double? confidence,
    String? note,
  }) {
    return HealthRecord(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      type: type ?? this.type,
      title: title ?? this.title,
      value: value ?? this.value,
      occurredAt: occurredAt ?? this.occurredAt,
      source: source ?? this.source,
      confidence: confidence ?? this.confidence,
      note: note ?? this.note,
    );
  }
}
