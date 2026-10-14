import '../entities/sync.dart';

/// 匿名注册成功后服务端返回的会话凭证（§5.1/§6.2）。
///
/// token 为明文，生产侧由 `SyncCredentialStore` 存入安全存储；绝不落库/写日志。
class AnonymousSession {
  /// 创建匿名会话凭证。
  const AnonymousSession({
    required this.token,
    required this.userId,
    required this.workspaceId,
    required this.deviceId,
  });

  /// 服务端签发的鉴权 token（64 位十六进制明文）。
  final String token;

  /// 服务端回显的本地匿名用户 ID。
  final String userId;

  /// 服务端生成的匿名工作区 ID。
  final String workspaceId;

  /// 服务端回显的设备 ID。
  final String deviceId;
}

/// 服务端对单条推送操作的判定（§5.2）。
enum PushItemStatus {
  /// 已接受并写入。
  applied,

  /// 因版本落后被拒（LWW 不通过）。
  conflict,

  /// 被拒绝（结构/所有权等校验失败）。
  rejected,
}

/// 单条推送操作的处理结果（§6.2）。
class PushItemResult {
  /// 创建推送结果。
  const PushItemResult({
    required this.opId,
    required this.status,
    this.reason,
    this.serverVersion,
    this.serverUpdatedAt,
  });

  /// 对应客户端 `SyncOperation.id`（幂等键）。
  final String opId;

  /// 处理判定。
  final PushItemStatus status;

  /// 拒绝/冲突原因（如 `stale_version`、`invalid_payload`）；无则为 null。
  final String? reason;

  /// 服务端当前版本（仅 conflict 时可能给出）。
  final int? serverVersion;

  /// 服务端当前更新时间（仅 conflict 时可能给出）。
  final DateTime? serverUpdatedAt;
}

/// 一次批量推送的响应（§5.2）。
class PushResponse {
  /// 创建推送响应。
  const PushResponse({required this.results});

  /// 逐条结果，顺序与请求 operations 对应。
  final List<PushItemResult> results;
}

/// 拉取到的一条远端变更（§5.3）。
class SyncChange {
  /// 创建远端变更。
  const SyncChange({
    required this.seq,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.version,
    required this.deviceId,
    required this.updatedAt,
    required this.payload,
  });

  /// 服务端单调变更游标。
  final int seq;

  /// 实体类型（白名单见 §5.4）。
  final String entityType;

  /// 实体 ID。
  final String entityId;

  /// 变更类型（复用本地队列枚举）。
  final SyncOperationKind kind;

  /// 该变更后的实体版本。
  final int version;

  /// 产生变更的设备 ID（用于回声抑制）。
  final String deviceId;

  /// 该变更后的实体更新时间（UTC）。
  final DateTime updatedAt;

  /// 实体快照（`toSyncJson` 对象本身）。
  final Map<String, Object?> payload;
}

/// 一次增量拉取的响应（§5.3）。
class PullResponse {
  /// 创建拉取响应。
  const PullResponse({
    required this.changes,
    required this.cursor,
    required this.hasMore,
  });

  /// 本次拉取到的变更（剔除本机回声后）。
  final List<SyncChange> changes;

  /// 推进后的游标（= 本次扫描行的最大 seq；无行则回显请求值）。
  final int cursor;

  /// 是否还有更多数据。
  final bool hasMore;
}
