import 'package:uuid/uuid.dart';

/// 生成通用实体 ID（UUID v4 字符串）。
String generateId() => const Uuid().v4();

/// 生成用户 ID（匿名本地身份，未来可绑定登录账号）。
String newUserId() => const Uuid().v4();

/// 生成设备 ID（用于多设备同步与撤销）。
String newDeviceId() => const Uuid().v4();
