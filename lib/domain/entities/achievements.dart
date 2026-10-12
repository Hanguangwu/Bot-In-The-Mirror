import 'syncable_entity.dart';

/// 成就定义（值对象，非同步）。规则可版本化，便于调整而不改客户端逻辑。
class Achievement {
  /// 创建成就定义。
  const Achievement({
    required this.code,
    required this.title,
    this.description = '',
    required this.ruleVersion,
  });

  /// 成就唯一编码（如 `task_completed`）。
  final String code;

  /// 成就标题。
  final String title;

  /// 描述文案。
  final String description;

  /// 规则版本号。
  final int ruleVersion;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Achievement copyWith({
    String? code,
    String? title,
    String? description,
    int? ruleVersion,
  }) {
    return Achievement(
      code: code ?? this.code,
      title: title ?? this.title,
      description: description ?? this.description,
      ruleVersion: ruleVersion ?? this.ruleVersion,
    );
  }
}

/// 用户已解锁的成就。
class UserAchievement extends SyncableEntity {
  /// 创建用户成就记录。
  const UserAchievement({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.achievementId,
    required this.eventKey,
    required this.unlockedAt,
  });

  /// 成就定义 ID/编码。
  final String achievementId;

  /// 触发事件幂等键。
  final String eventKey;

  /// 解锁时间。
  final DateTime unlockedAt;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  UserAchievement copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? achievementId,
    String? eventKey,
    DateTime? unlockedAt,
  }) {
    return UserAchievement(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      achievementId: achievementId ?? this.achievementId,
      eventKey: eventKey ?? this.eventKey,
      unlockedAt: unlockedAt ?? this.unlockedAt,
    );
  }
}
