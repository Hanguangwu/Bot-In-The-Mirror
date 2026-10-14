import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import 'app_database.dart';

// TEXT 枚举：以枚举 `.name` 序列化，增删枚举值不错位历史数据（与 M0 仓储一致）。
SyncOperationKind _kindFromDrift(String name) =>
    SyncOperationKind.values.byName(name);
String _kindToDrift(SyncOperationKind kind) => kind.name;
SyncOperationStatus _statusFromDrift(String name) =>
    SyncOperationStatus.values.byName(name);
String _statusToDrift(SyncOperationStatus status) => status.name;

/// 基于 Drift 的同步队列仓储实现。
///
/// [enqueue]/[enqueueAll]/[mark] **内部不另开事务**：必须由调用方置于同一
/// 事务内，保证实体写入与入队原子（§5.1/§7.1）。
///
/// 入队项由调用方构造完整字段（§7.3）；本实现仅在 `id`/`userId`/`deviceId`
/// 为空时补齐，故 [clock] 参数当前保留以对齐仓储构造约定、暂不使用。
class SyncOperationRepositoryImpl implements SyncOperationRepository {
  /// 创建仓储；[userId]/[deviceId] 在本实例内固定。
  SyncOperationRepositoryImpl(
    this._db,
    Clock clock, {
    String? userId,
    String? deviceId,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId();

  final AppDatabase _db;
  final String _userId;
  final String _deviceId;

  @override
  Future<List<SyncOperation>> getPending() async {
    final rows = await _pendingQuery().get();
    return rows.map(_toOperation).toList(growable: false);
  }

  @override
  Stream<List<SyncOperation>> watchPending() => _pendingQuery()
      .watch()
      .map((rows) => rows.map(_toOperation).toList(growable: false));

  @override
  Future<void> enqueue(SyncOperation operation) async {
    await _db.into(_db.syncOperations).insert(_toCompanion(_normalize(operation)));
  }

  @override
  Future<void> enqueueAll(List<SyncOperation> operations) async {
    // 刻意逐条 insert 而不使用 batch：batch 会自行开启事务，违反「内部不另开
    // 事务」的约定（§5.1）；原子性由调用方的事务保证。
    for (final operation in operations) {
      await _db
          .into(_db.syncOperations)
          .insert(_toCompanion(_normalize(operation)));
    }
  }

  @override
  Future<void> mark(SyncOperation operation) async {
    await (_db.update(_db.syncOperations)
          ..where((t) => t.id.equals(operation.id)))
        .write(_toCompanion(operation));
  }

  SimpleSelectStatement<$SyncOperationsTable, SyncOperationRow> _pendingQuery() {
    return _db.select(_db.syncOperations)
      ..where((t) => t.status.equals(SyncOperationStatus.pending.name))
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt),
        (t) => OrderingTerm(expression: t.id),
      ]);
  }

  /// 补齐空 id（队列行必须有主键）与空身份；其余字段由调用方负责。
  SyncOperation _normalize(SyncOperation operation) {
    var result = operation;
    if (result.id.isEmpty) {
      result = result.copyWith(id: generateId());
    }
    if (result.userId.isEmpty) {
      result = result.copyWith(userId: _userId);
    }
    if (result.deviceId.isEmpty) {
      result = result.copyWith(deviceId: _deviceId);
    }
    return result;
  }

  SyncOperation _toOperation(SyncOperationRow row) => SyncOperation(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        entityType: row.entityType,
        entityId: row.entityId,
        kind: _kindFromDrift(row.kind),
        payload: _decodePayload(row.payload),
        status: _statusFromDrift(row.status),
        retryCount: row.retryCount,
        lastError: row.lastError,
        syncedAt: row.syncedAt,
      );

  SyncOperationsCompanion _toCompanion(SyncOperation operation) =>
      SyncOperationsCompanion(
        id: Value(operation.id),
        userId: Value(operation.userId),
        createdAt: Value(operation.createdAt),
        updatedAt: Value(operation.updatedAt),
        deletedAt: Value(operation.deletedAt),
        version: Value(operation.version),
        deviceId: Value(operation.deviceId),
        entityType: Value(operation.entityType),
        entityId: Value(operation.entityId),
        kind: Value(_kindToDrift(operation.kind)),
        payload: Value(jsonEncode(operation.payload)),
        status: Value(_statusToDrift(operation.status)),
        retryCount: Value(operation.retryCount),
        lastError: Value(operation.lastError),
        syncedAt: Value(operation.syncedAt),
      );

  /// 解析 payload JSON 字符串为 Map；非对象（损坏数据）兜底为空 Map。
  Map<String, Object?> _decodePayload(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map) {
      return decoded.cast<String, Object?>();
    }
    return <String, Object?>{};
  }
}
