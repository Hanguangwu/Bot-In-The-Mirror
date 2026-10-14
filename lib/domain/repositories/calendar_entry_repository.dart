import '../entities/calendar.dart';

/// 日历条目仓储。
abstract interface class CalendarEntryRepository {
  /// 按 startAt 命中半开区间 [start, end)，按 (startAt, id) 稳定排序；不含已删。
  Future<List<CalendarEntry>> getInRange(DateTime start, DateTime end);

  /// 监听上述区间条目。
  Stream<List<CalendarEntry>> watchInRange(DateTime start, DateTime end);

  /// 按 id 取单条；不存在或已删时返回 null。
  Future<CalendarEntry?> get(String id);

  /// upsert，内部补齐 Syncable 字段并递增 version（与 M1 save 语义一致）。
  Future<CalendarEntry> save(CalendarEntry entry);

  /// 软删墓碑（写 deletedAt，不物理删）。
  Future<void> delete(String id);
}
