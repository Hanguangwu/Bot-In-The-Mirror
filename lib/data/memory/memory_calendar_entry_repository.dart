import 'dart:async';

import '../../core/ids/ids.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/calendar_entry_repository.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../sync/sync_operation_factory.dart';
import 'memory_store.dart';

/// 内存日历条目仓储：行为与 Drift 实现等价。
///
/// 区间按 `startAt ∈ [start, end)` 命中（跨夜条目按起始日归属），稳定排序
/// `(startAt, id)`；已删一律过滤。写路径经 [MemoryStore.runAtomic] 包裹并入队
/// （§5.2/§7.1）。装配时若提供 [MemoryStore] 则注册自身。
class MemoryCalendarEntryRepository
    implements CalendarEntryRepository, MemoryStoreParticipant {
  /// 创建内存仓储；[userId]/[deviceId] 在本实例内固定。
  ///
  /// [syncOperationRepository] 用于入队；[store] 提供跨仓储全或无接缝。
  MemoryCalendarEntryRepository({
    required SyncOperationRepository syncOperationRepository,
    Clock? clock,
    String? userId,
    String? deviceId,
    MemoryStore? store,
  })  : _clock = clock ?? const SystemClock(),
        _userId = userId ?? newUserId(),
        _deviceId = deviceId ?? newDeviceId(),
        _syncOperationRepository = syncOperationRepository,
        _memoryStore = store {
    store?.register(this);
  }

  final Clock _clock;
  final String _userId;
  final String _deviceId;
  final SyncOperationRepository _syncOperationRepository;
  final MemoryStore? _memoryStore;
  final List<CalendarEntry> _entries = <CalendarEntry>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Future<List<CalendarEntry>> getInRange(DateTime start, DateTime end) async =>
      _inRange(start, end);

  @override
  Stream<List<CalendarEntry>> watchInRange(DateTime start, DateTime end) {
    late StreamController<List<CalendarEntry>> controller;
    StreamSubscription<void>? subscription;
    controller = StreamController<List<CalendarEntry>>(
      onListen: () {
        controller.add(_inRange(start, end));
        subscription = _changes.stream.listen((_) {
          if (!controller.isClosed) {
            controller.add(_inRange(start, end));
          }
        });
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<CalendarEntry?> get(String id) async {
    final index = _indexOf(id);
    if (index < 0) {
      return null;
    }
    final entry = _entries[index];
    return entry.deletedAt == null ? entry : null;
  }

  @override
  Future<CalendarEntry> save(CalendarEntry entry) {
    // §5.2/§7.1：实体写入与入队经同一原子接缝；回滚不留孤儿操作。
    return _atomic(() async {
      final now = _clock.now();
      final index = _indexOf(entry.id);
      if (index < 0) {
        final stored = entry.copyWith(
          id: entry.id.isEmpty ? generateId() : entry.id,
          userId: _userId,
          deviceId: _deviceId,
          createdAt: now,
          updatedAt: now,
          version: 1,
        );
        _entries.add(stored);
        await _enqueue(stored, SyncOperationKind.create, now);
        _notify();
        return stored;
      }
      final existing = _entries[index];
      final updated = entry.copyWith(
        id: existing.id,
        userId: _userId,
        deviceId: _deviceId,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: existing.version + 1,
      );
      _entries[index] = updated;
      await _enqueue(updated, SyncOperationKind.update, now);
      _notify();
      return updated;
    });
  }

  @override
  Future<void> delete(String id) {
    // §5.2/§7.1/§8：墓碑写入与入队同一原子接缝；快照含 deletedAt。
    return _atomic(() async {
      final index = _indexOf(id);
      if (index < 0) {
        return;
      }
      final entry = _entries[index];
      if (entry.deletedAt != null) {
        return;
      }
      final now = _clock.now();
      final tombstone = entry.copyWith(
        deletedAt: now,
        updatedAt: now,
        version: entry.version + 1,
      );
      _entries[index] = tombstone;
      await _enqueue(tombstone, SyncOperationKind.delete, now);
      _notify();
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

  @override
  Object? snapshot() => List<CalendarEntry>.of(_entries);

  @override
  void restore(Object? snapshot) {
    _entries
      ..clear()
      ..addAll(snapshot! as List<CalendarEntry>);
    _notify();
  }

  /// 在 [MemoryStore] 全或无接缝内执行 [action]（无 store 时直接执行）。
  Future<T> _atomic<T>(Future<T> Function() action) {
    final store = _memoryStore;
    return store == null ? action() : store.runAtomic(action);
  }

  /// 释放内部流资源（仅测试/预览使用）。
  void dispose() {
    _changes.close();
  }

  int _indexOf(String id) {
    if (id.isEmpty) {
      return -1;
    }
    return _entries.indexWhere((entry) => entry.id == id);
  }

  List<CalendarEntry> _inRange(DateTime start, DateTime end) {
    final result = _entries.where((entry) {
      if (entry.deletedAt != null) {
        return false;
      }
      return !entry.startAt.isBefore(start) && entry.startAt.isBefore(end);
    }).toList();
    result.sort((a, b) {
      final compared = a.startAt.compareTo(b.startAt);
      return compared != 0 ? compared : a.id.compareTo(b.id);
    });
    return List<CalendarEntry>.unmodifiable(result);
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
