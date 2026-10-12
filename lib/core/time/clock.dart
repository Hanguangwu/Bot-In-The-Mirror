/// 时间抽象，便于在测试中注入可控时间。
abstract class Clock {
  /// 返回当前时间。
  DateTime now();
}

/// 基于系统时钟的默认实现。
class SystemClock implements Clock {
  /// 创建系统时钟。
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
