import '../entities/task.dart';

/// 项目仓储（设计基线：项目归属任务区）。
abstract interface class ProjectRepository {
  /// 取全部未删项目。
  Future<List<Project>> getProjects();

  /// 监听全部未删项目。
  Stream<List<Project>> watchProjects();

  /// 按 id 取单条；不存在或已删时返回 null。
  Future<Project?> get(String id);

  /// upsert，内部补齐 Syncable 字段并递增 version（与 M1 save 语义一致）。
  Future<Project> save(Project project);

  /// 仅墓碑化项目本身；不改任务（M2b 前不做级联）。
  Future<void> delete(String id);
}
