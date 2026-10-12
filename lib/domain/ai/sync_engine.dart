import '../entities/sync.dart';

/// 同步引擎接口。M0 仅声明，M2 起实现。
abstract interface class SyncEngine {
  /// 执行一次同步；[manual] 表示用户手动触发。
  Future<SyncReport> sync({bool manual = false});

  /// 监听同步状态变化。
  Stream<SyncState> watchState();
}
