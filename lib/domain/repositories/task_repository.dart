import '../entities/task.dart';

/// 任务仓储接口。M0 仅声明，M1 起实现。
abstract interface class TaskRepository {
  /// 监听满足 [query] 的任务列表。
  Stream<List<Task>> watchTasks(TaskQuery query);

  /// 一次性获取满足 [query] 的任务列表。
  Future<List<Task>> getTasks(TaskQuery query);

  /// 保存任务（新建或更新）。
  Future<Task> save(Task task);

  /// 批量应用任务变更（AI 计划确认后一次性写入）。
  Future<void> applyChanges(List<TaskChange> changes);
}
