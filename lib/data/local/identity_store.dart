import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ids/ids.dart';

/// 设备级匿名身份；首启生成并持久化，之后恒定（B1）。
///
/// `configureDependencies` 在 [load] 后把 `userId`/`deviceId` 注入全部仓储，
/// 保证同一库内所有实体与同步操作共享同一身份。
abstract interface class IdentityStore {
  /// 稳定匿名用户 ID。
  String get userId;

  /// 稳定设备 ID。
  String get deviceId;

  /// 首启读取；缺失时生成并写回。
  Future<void> load();
}

/// 生产实现：以 `shared_preferences` 持久化匿名身份。
///
/// 构造本身不读平台通道；平台访问只发生在 [load]。测试使用
/// `MemoryIdentityStore`（位于 `memory_identity_store.dart`），避免真实平台依赖。
class PersistentIdentityStore implements IdentityStore {
  /// 创建存储；[preferences] 可注入便于测试。
  PersistentIdentityStore({SharedPreferences? preferences})
      : _preferences = preferences;

  /// 用户 ID 的 shared_preferences key。
  static const String userIdKey = 'anonymous_user_id';

  /// 设备 ID 的 shared_preferences key。
  static const String deviceIdKey = 'anonymous_device_id';

  SharedPreferences? _preferences;
  String _userId = '';
  String _deviceId = '';

  @override
  String get userId => _userId;

  @override
  String get deviceId => _deviceId;

  @override
  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    var userId = preferences.getString(userIdKey);
    if (userId == null || userId.isEmpty) {
      userId = newUserId();
      await preferences.setString(userIdKey, userId);
    }
    var deviceId = preferences.getString(deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = newDeviceId();
      await preferences.setString(deviceIdKey, deviceId);
    }
    _userId = userId;
    _deviceId = deviceId;
  }
}
