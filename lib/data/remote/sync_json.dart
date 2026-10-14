import '../../core/errors/app_exception.dart';
import '../../domain/entities/sync.dart';
import '../../domain/sync/sync_change.dart';

/// JSON 编解码的统一键名常量（Worker API 契约）。
class _Keys {
  static const String token = 'token';
  static const String userId = 'userId';
  static const String workspaceId = 'workspaceId';
  static const String deviceId = 'deviceId';
  static const String operations = 'operations';
  static const String opId = 'opId';
  static const String entityType = 'entityType';
  static const String entityId = 'entityId';
  static const String kind = 'kind';
  static const String payload = 'payload';
  static const String results = 'results';
  static const String status = 'status';
  static const String reason = 'reason';
  static const String serverVersion = 'serverVersion';
  static const String serverUpdatedAt = 'serverUpdatedAt';
  static const String cursor = 'cursor';
  static const String limit = 'limit';
  static const String changes = 'changes';
  static const String seq = 'seq';
  static const String version = 'version';
  static const String updatedAt = 'updatedAt';
  static const String hasMore = 'hasMore';
  static const String error = 'error';
  static const String code = 'code';
  static const String message = 'message';
}

/// DTO ↔ JSON 编解码（请求/响应），纯函数，便于单测（§6.2/A11）。
class SyncJson {
  /// 构建匿名注册请求体（§5.1）。
  static Map<String, Object?> buildRegisterRequest({
    required String userId,
    required String deviceId,
  }) {
    return <String, Object?>{
      _Keys.userId: userId,
      _Keys.deviceId: deviceId,
    };
  }

  /// 解析匿名注册响应（§5.1）。
  static AnonymousSession parseRegisterResponse(Map<String, Object?> json) {
    try {
      return AnonymousSession(
        token: _requireString(json, _Keys.token),
        userId: _requireString(json, _Keys.userId),
        workspaceId: _requireString(json, _Keys.workspaceId),
        deviceId: _requireString(json, _Keys.deviceId),
      );
    } catch (e) {
      throw SyncDecodeException('注册响应格式非法', cause: e);
    }
  }

  /// 构建推送请求体（§5.2）。
  ///
  /// **注意**：请求体不含 version/updatedAt/deviceId（信封只包含
  /// opId/entityType/entityId/kind/payload）。
  static Map<String, Object?> buildPushRequest({
    required List<SyncOperation> operations,
  }) {
    final ops = operations
        .map(
          (op) => <String, Object?>{
            _Keys.opId: op.id,
            _Keys.entityType: op.entityType,
            _Keys.entityId: op.entityId,
            _Keys.kind: op.kind.name,
            _Keys.payload: op.payload,
          },
        )
        .toList(growable: false);

    return <String, Object?>{_Keys.operations: ops};
  }

  /// 解析推送响应（§5.2）。
  static PushResponse parsePushResponse(Map<String, Object?> json) {
    try {
      final resultsJson = json[_Keys.results];
      if (resultsJson is! List) {
        throw SyncDecodeException(_fieldError(_Keys.results));
      }
      final results = <PushItemResult>[];
      for (final item in resultsJson) {
        if (item is! Map) {
          throw SyncDecodeException(_fieldError(_Keys.results));
        }
        results.add(_parsePushItem(item));
      }
      return PushResponse(results: results);
    } catch (e) {
      throw SyncDecodeException('推送响应格式非法', cause: e);
    }
  }

  /// 构建拉取请求 URL 查询参数（§5.3）。
  static Map<String, String> buildPullQuery({
    required int cursor,
    required int limit,
  }) {
    return <String, String>{
      _Keys.cursor: cursor.toString(),
      _Keys.limit: limit.toString(),
    };
  }

  /// 解析拉取响应（§5.3）。
  static PullResponse parsePullResponse(Map<String, Object?> json) {
    try {
      final changesJson = json[_Keys.changes];
      if (changesJson is! List) {
        throw SyncDecodeException(_fieldError(_Keys.changes));
      }
      final changes = <SyncChange>[];
      for (final item in changesJson) {
        if (item is! Map) {
          throw SyncDecodeException(_fieldError(_Keys.changes));
        }
        changes.add(_parseChange(item));
      }
      return PullResponse(
        changes: changes,
        cursor: _requireInt(json, _Keys.cursor),
        hasMore: _requireBool(json, _Keys.hasMore),
      );
    } catch (e) {
      throw SyncDecodeException('拉取响应格式非法', cause: e);
    }
  }

  /// 从 Worker 错误体提取错误码（§5，错误体 `{ error: { code, message } }`）。
  static String? tryParseErrorCode(Map<String, Object?> json) {
    final error = json[_Keys.error];
    if (error is! Map) {
      return null;
    }
    final code = error[_Keys.code];
    return code is String ? code : null;
  }

  /// 从 Worker 错误体提取错误简述（§5）；仅供日志/cause，不直接展示。
  static String? tryParseErrorMessage(Map<String, Object?> json) {
    final error = json[_Keys.error];
    if (error is! Map) {
      return null;
    }
    final message = error[_Keys.message];
    return message is String ? message : null;
  }
}

PushItemResult _parsePushItem(Map<Object?, Object?> json) {
  final statusStr = _requireString(json, _Keys.status);
  final status = _parsePushStatus(statusStr);
  return PushItemResult(
    opId: _requireString(json, _Keys.opId),
    status: status,
    reason: _optionalString(json, _Keys.reason),
    serverVersion: _optionalInt(json, _Keys.serverVersion),
    serverUpdatedAt: _optionalDateTime(json, _Keys.serverUpdatedAt),
  );
}

PushItemStatus _parsePushStatus(String status) {
  switch (status) {
    case 'applied':
      return PushItemStatus.applied;
    case 'conflict':
      return PushItemStatus.conflict;
    case 'rejected':
      return PushItemStatus.rejected;
    default:
      throw SyncDecodeException(_fieldError(_Keys.status));
  }
}

SyncChange _parseChange(Map<Object?, Object?> json) {
  final kindStr = _requireString(json, _Keys.kind);
  final kind = _parseSyncKind(kindStr);
  final payload = json[_Keys.payload];
  if (payload is! Map<String, Object?>) {
    if (payload is Map) {
      // 将非 String 键规范化
      return SyncChange(
        seq: _requireInt(json, _Keys.seq),
        entityType: _requireString(json, _Keys.entityType),
        entityId: _requireString(json, _Keys.entityId),
        kind: kind,
        version: _requireInt(json, _Keys.version),
        deviceId: _requireString(json, _Keys.deviceId),
        updatedAt: _requireDateTime(json, _Keys.updatedAt),
        payload: payload.map<String, Object?>(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        ),
      );
    }
    throw SyncDecodeException(_fieldError(_Keys.payload));
  }

  return SyncChange(
    seq: _requireInt(json, _Keys.seq),
    entityType: _requireString(json, _Keys.entityType),
    entityId: _requireString(json, _Keys.entityId),
    kind: kind,
    version: _requireInt(json, _Keys.version),
    deviceId: _requireString(json, _Keys.deviceId),
    updatedAt: _requireDateTime(json, _Keys.updatedAt),
    payload: payload,
  );
}

SyncOperationKind _parseSyncKind(String kind) {
  switch (kind) {
    case 'create':
      return SyncOperationKind.create;
    case 'update':
      return SyncOperationKind.update;
    case 'delete':
      return SyncOperationKind.delete;
    default:
      throw SyncDecodeException(_fieldError(_Keys.kind));
  }
}

String _fieldError(String key) => '同步响应字段 $key 非法';

String _requireString(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

String? _optionalString(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

int _requireInt(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

int? _optionalInt(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

bool _requireBool(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw SyncDecodeException(_fieldError(key));
  }
  return value;
}

DateTime _requireDateTime(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw SyncDecodeException(_fieldError(key));
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw SyncDecodeException(_fieldError(key));
  }
  return parsed.toLocal();
}

DateTime? _optionalDateTime(Map<Object?, Object?> json, String key) {
  if (json[key] == null) {
    return null;
  }
  return _requireDateTime(json, key);
}
