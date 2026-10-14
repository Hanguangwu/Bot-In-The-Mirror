import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/calendar_entry_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'app_database.dart';

/// 基于 Drift 的日历条目仓储实现。
///
/// 写入时由实现统一补齐/覆盖 `userId`、`deviceId`、`createdAt`、`updatedAt`、
/// `version`（与 M1 任务/会话仓储同规则）；查询一律过滤 `deletedAt IS NULL`。
/// `save`/`delete` 在单事务内原子「实体写入 + 入队」（§5.2/§7.1）。
class CalendarEntryRepositoryImpl implements CalendarEntryRepository {
  /// 创建仓储；[userId]/[deviceId] 在本实例内固定。
  ///
  /// [syncOperationRepository] 必须与本仓储共享同一 [AppDatabase] 单例，
  /// 使入队复用外层事务（§7.1）。
  CalendarEntryRepositoryImpl(
    this._db,
    this._clock, {
    required SyncOperationRepository syncOperationRepository,
    String? userId,
    String? deviceId,
  })  : _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _syncOperationRepository = syncOperationRepository;

  final AppDatabase _db;
  final Clock _clock;
  final String _userId;
  final String _deviceId;
  final SyncOperationRepository _syncOperationRepository;

  @override
  Future<List<CalendarEntry>> getInRange(DateTime start, DateTime end) async {
    final rows = await _rangeQuery(start, end).get();
    return rows.map(_toEntry).toList(growable: false);
  }

  @override
  Stream<List<CalendarEntry>> watchInRange(DateTime start, DateTime end) =>
      _rangeQuery(start, end)
          .watch()
          .map((rows) => rows.map(_toEntry).toList(growable: false));

  @override
  Future<CalendarEntry?> get(String id) async {
    final row = await _findRow(id);
    if (row == null || row.deletedAt != null) {
      return null;
    }
    return _toEntry(row);
  }

  @override
  Future<CalendarEntry> save(CalendarEntry entry) async {
    // §5.2/§7.1：实体写入与入队同一事务；回滚不留孤儿操作。
    return _db.transaction(() async {
      final now = _clock.now();
      final existing = await _findRow(entry.id);
      if (existing == null) {
        final stored = entry.copyWith(
          id: entry.id.isEmpty ? generateId() : entry.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        await _db.into(_db.calendarEntries).insert(_toCompanion(stored));
        await _enqueue(stored, SyncOperationKind.create, now);
        return stored;
      }
      final updated = entry.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _db
          .into(_db.calendarEntries)
          .insertOnConflictUpdate(_toCompanion(updated));
      await _enqueue(updated, SyncOperationKind.update, now);
      return updated;
    });
  }

  @override
  Future<void> delete(String id) async {
    // §5.2/§7.1/§8：墓碑写入与入队同一事务；快照取墓碑化后的实体（含 deletedAt）。
    await _db.transaction(() async {
      final existing = await _findRow(id);
      if (existing == null || existing.deletedAt != null) {
        return;
      }
      final now = _clock.now();
      await (_db.update(_db.calendarEntries)..where((t) => t.id.equals(id)))
          .write(
        CalendarEntriesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
      final tombstone = _toEntry(existing).copyWith(
        deletedAt: now,
        updatedAt: now,
        version: existing.version + 1,
      );
      await _enqueue(tombstone, SyncOperationKind.delete, now);
    });
  }

  /// 构造并入队一条 calendar_entry 同步操作（payload 为最终实体快照，§6/§7.3）。
  Future<void> _enqueue(
    CalendarEntry entry,
    SyncOperationKind kind,
    DateTime now,
  ) async {
    await _syncOperationRepository.enqueue(
      buildSyncOperation(
        entity: entry,
        entityType: 'calendar_entry',
        kind: kind,
        userId: _userId,
        deviceId: _deviceId,
        now: now,
      ),
    );
  }

  /// 半开区间 [start, end)，按 `startAt` 命中；稳定排序 (startAt, id)。
  SimpleSelectStatement<$CalendarEntriesTable, CalendarEntryRow> _rangeQuery(
    DateTime start,
    DateTime end,
  ) {
    return _db.select(_db.calendarEntries)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            t.startAt.isBiggerOrEqualValue(start) &
            t.startAt.isSmallerThanValue(end),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.startAt),
        (t) => OrderingTerm(expression: t.id),
      ]);
  }

  Future<CalendarEntryRow?> _findRow(String id) async {
    if (id.isEmpty) {
      return null;
    }
    return (_db.select(_db.calendarEntries)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  CalendarEntry _toEntry(CalendarEntryRow row) => CalendarEntry(
        id: row.id,
        userId: row.userId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        version: row.version,
        deviceId: row.deviceId,
        title: row.title,
        startAt: row.startAt,
        endAt: row.endAt,
        allDay: row.allDay,
        taskIds: _decodeTaskIds(row.taskIds),
        note: row.note,
      );

  CalendarEntriesCompanion _toCompanion(CalendarEntry entry) =>
      CalendarEntriesCompanion(
        id: Value(entry.id),
        userId: Value(entry.userId),
        createdAt: Value(entry.createdAt),
        updatedAt: Value(entry.updatedAt),
        deletedAt: Value(entry.deletedAt),
        version: Value(entry.version),
        deviceId: Value(entry.deviceId),
        title: Value(entry.title),
        startAt: Value(entry.startAt),
        endAt: Value(entry.endAt),
        allDay: Value(entry.allDay),
        taskIds: Value(jsonEncode(entry.taskIds)),
        note: Value(entry.note),
      );

  /// 解析 taskIds JSON 数组；损坏或非字符串项一律丢弃。
  List<String> _decodeTaskIds(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! List) {
      return const <String>[];
    }
    return <String>[
      for (final item in decoded)
        if (item is String) item,
    ];
  }
}
