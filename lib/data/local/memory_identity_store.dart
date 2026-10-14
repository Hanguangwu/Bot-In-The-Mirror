import 'identity_store.dart';

/// 内存身份存储：测试用固定值，不触碰任何平台 API。
class MemoryIdentityStore implements IdentityStore {
  /// 创建内存身份；默认固定为 `user-1`/`device-1`。
  MemoryIdentityStore({
    this.userId = 'user-1',
    this.deviceId = 'device-1',
  });

  @override
  final String userId;

  @override
  final String deviceId;

  @override
  Future<void> load() async {}
}
