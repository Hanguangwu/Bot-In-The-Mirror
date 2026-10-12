/// 可同步实体公共基类。
///
/// 参与多设备同步的所有实体都必须携带以下字段：稳定 `id`、`userId`、
/// 创建/更新时间、软删除墓碑 `deletedAt`、乐观并发 `version` 与来源 `deviceId`。
///
/// 模型不可变：字段全部 `final`，子类通过 `copyWith` 生成新实例。
abstract class SyncableEntity {
  /// 创建可同步实体基类。
  const SyncableEntity({
    required this.id,
    required this.userId,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.version,
    required this.deviceId,
  });

  /// 实体稳定 ID（客户端生成，UUID v4）。
  final String id;

  /// 所属用户 ID（当前单用户，为多用户预留）。
  final String userId;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近更新时间。
  final DateTime updatedAt;

  /// 软删除墓碑时间；非空表示已删除。
  final DateTime? deletedAt;

  /// 乐观并发版本号，每次写入递增。
  final int version;

  /// 产生本次变更的设备 ID。
  final String deviceId;
}
