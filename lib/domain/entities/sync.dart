import 'syncable_entity.dart';

/// 同步操作类型。
enum SyncOperationKind {
  /// 新建。
  create,

  /// 更新。
  update,

  /// 删除。
  delete,
}

/// 同步操作状态。
enum SyncOperationStatus {
  /// 待处理。
  pending,

  /// 同步中。
  syncing,

  /// 已同步。
  synced,

  /// 失败。
  failed,

  /// 冲突。
  conflicted,
}

/// 同步引擎整体状态。
enum SyncState {
  /// 空闲。
  idle,

  /// 同步中。
  syncing,

  /// 离线。
  offline,

  /// 失败。
  failed,
}

/// 本地同步队列中的一条待同步变更。
class SyncOperation extends SyncableEntity {
  /// 创建同步操作。
  const SyncOperation({
    required super.id,
    required super.userId,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required super.version,
    required super.deviceId,
    required this.entityType,
    required this.entityId,
    required this.kind,
    this.payload = const <String, Object?>{},
    this.status = SyncOperationStatus.pending,
    this.retryCount = 0,
    this.lastError,
    this.syncedAt,
  });

  /// 实体类型（如 `conversation` / `message`）。
  final String entityType;

  /// 实体 ID。
  final String entityId;

  /// 操作类型。
  final SyncOperationKind kind;

  /// 序列化后的变更载荷，必须可 JSON 编码。
  final Map<String, Object?> payload;

  /// 操作状态。
  final SyncOperationStatus status;

  /// 重试次数。
  final int retryCount;

  /// 最近一次错误摘要。
  final String? lastError;

  /// 同步完成时间。
  final DateTime? syncedAt;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  SyncOperation copyWith({
    String? id,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    int? version,
    String? deviceId,
    String? entityType,
    String? entityId,
    SyncOperationKind? kind,
    Map<String, Object?>? payload,
    SyncOperationStatus? status,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    DateTime? syncedAt,
  }) {
    return SyncOperation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      version: version ?? this.version,
      deviceId: deviceId ?? this.deviceId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      kind: kind ?? this.kind,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      // lastError 无法经 `copyWith(lastError: null)` 置空：统一用 clearLastError（M1 约定）。
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }
}

/// 一次同步的结果报告（值对象）。
class SyncReport {
  /// 创建同步报告。
  const SyncReport({
    required this.pushed,
    required this.pulled,
    required this.failed,
    required this.at,
    this.cursor,
  });

  /// 推送成功条数。
  final int pushed;

  /// 拉取应用条数。
  final int pulled;

  /// 失败条数。
  final int failed;

  /// 新的同步游标；无拉取时为 null。
  final int? cursor;

  /// 报告生成时间。
  final DateTime at;

  /// 复制并覆盖指定字段；未传入的字段保持不变。
  SyncReport copyWith({
    int? pushed,
    int? pulled,
    int? failed,
    int? cursor,
    DateTime? at,
  }) {
    return SyncReport(
      pushed: pushed ?? this.pushed,
      pulled: pulled ?? this.pulled,
      failed: failed ?? this.failed,
      cursor: cursor ?? this.cursor,
      at: at ?? this.at,
    );
  }
}
