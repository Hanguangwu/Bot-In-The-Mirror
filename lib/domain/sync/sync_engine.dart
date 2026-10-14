import '../entities/sync.dart';
import 'sync_status.dart';

/// 同步引擎接口（§6.6，B4）。
///
/// 由 M0 的 `lib/domain/ai/sync_engine.dart` 迁入并按 M2b 契约扩展：
/// 除 `sync()` 外提供 `watchStatus()`/`status` 供状态页观测（携带报告/错误/
/// 上次同步时间）。生产实现 `SyncEngineImpl`（Lane-C）。
abstract interface class SyncEngine {
  /// 执行一次同步；[manual] 为 true 时忽略自动同步退避。
  Future<SyncReport> sync({bool manual = false});

  /// 监听同步状态变化（状态页订阅）。
  Stream<SyncStatus> watchStatus();

  /// 当前同步状态（同步读取，供构建时使用）。
  SyncStatus get status;
}
