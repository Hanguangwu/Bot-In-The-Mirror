import 'syncable_entity.dart';

/// 用户身份。当前为本地生成的匿名稳定 ID；未来替换为登录账号。
///
/// 约定：`User.userId == User.id`。
class User extends SyncableEntity {
  /// 创建用户实体。
  const User({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    this.name,
  });

  /// 显示名称（匿名用户可为空）。
  final String? name;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  User copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? name,
  }) {
    return User(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
    );
  }
}

/// 个人数据空间。当前一用户一空间，未来支持多个空间或家庭空间。
class Workspace extends SyncableEntity {
  /// 创建工作空间实体。
  const Workspace({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.name,
  });

  /// 空间名称。
  final String name;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  Workspace copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? name,
  }) {
    return Workspace(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
    );
  }
}
