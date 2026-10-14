/// 可参与 [MemoryStore] 全或无回滚的内存仓储。
///
/// 各内存仓储在装配时把自己注册进 [MemoryStore]；`runAtomic` 在动作开始前
/// 快照全部注册方，动作异常时全部还原，从而实现跨仓储的「全或无」（A6/§7.2）。
abstract interface class MemoryStoreParticipant {
  /// 捕获当前全部内存状态（实现需返回可安全还原的不可变/深拷贝快照）。
  Object? snapshot();

  /// 用先前快照覆盖当前状态。
  void restore(Object? snapshot);
}

/// 注册表式内存全或无接缝。
///
/// 与 Drift 的事务语义对齐：让内存实现与 Drift 实现可在同一组契约断言下等价。
class MemoryStore {
  final List<MemoryStoreParticipant> _participants = <MemoryStoreParticipant>[];

  /// 注册一个参与回滚的内存仓储；重复注册会忽略。
  void register(MemoryStoreParticipant participant) {
    if (!_participants.contains(participant)) {
      _participants.add(participant);
    }
  }

  /// 在当前内存状态下执行 [action]；抛异常时还原全部注册方的快照并重新抛出。
  Future<T> runAtomic<T>(Future<T> Function() action) async {
    final snapshots = <Object?>[
      for (final participant in _participants) participant.snapshot(),
    ];
    try {
      return await action();
    } catch (_) {
      for (var i = 0; i < _participants.length; i++) {
        _participants[i].restore(snapshots[i]);
      }
      rethrow;
    }
  }
}
