/// LWW（Last-Write-Wins）整实体级判定（§7.1）。
///
/// 与 `worker/src/lww.ts` 同语义：接受 incoming 当且仅当
/// - 本地无存储版本（[storedVersion] 为 null）；或
/// - incoming 版本更高（`incomingVersion > storedVersion`）；或
/// - 版本相同且 incoming 的更新时间更晚（`incomingUpdatedAt > storedUpdatedAt`）。
///
/// 删除与更新同规则（不额外「删除必胜」）；字段级合并后置。
bool acceptVersion({
  required int incomingVersion,
  required DateTime incomingUpdatedAt,
  int? storedVersion,
  DateTime? storedUpdatedAt,
}) {
  // 本地无该实体：直接接受。
  if (storedVersion == null) {
    return true;
  }
  // 版本不同：高版本胜出。
  if (incomingVersion != storedVersion) {
    return incomingVersion > storedVersion;
  }
  // 版本相同：比较更新时间；本地时间缺失时保守接受 incoming。
  if (storedUpdatedAt == null) {
    return true;
  }
  return incomingUpdatedAt.isAfter(storedUpdatedAt);
}
