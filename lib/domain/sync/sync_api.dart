import '../../core/config/app_config.dart';
import '../entities/sync.dart';
import 'sync_change.dart';

/// 远端同步 API 接口（§6.2）。
///
/// 生产实现 `WorkerSyncApi`（Lane-C）走 HTTPS；测试用假实现/`MockClient`，
/// **不得触网**。所有方法失败语义：
/// - 非 2xx → `SyncApiException(code, status)`；
/// - 网络异常 → `SyncNetworkException`；
/// - 响应解析失败 → `SyncDecodeException`。
abstract interface class RemoteSyncApi {
  /// 匿名注册/换发令牌（§5.1）。
  Future<AnonymousSession> register({
    required String userId,
    required String deviceId,
  });

  /// 批量推送本地待同步操作（§5.2）。
  Future<PushResponse> push({
    required String token,
    required List<SyncOperation> operations,
  });

  /// 增量拉取游标之后的远端变更（§5.3）。
  Future<PullResponse> pull({
    required String token,
    required int cursor,
    int limit = AppConfig.syncPullLimit,
  });
}
