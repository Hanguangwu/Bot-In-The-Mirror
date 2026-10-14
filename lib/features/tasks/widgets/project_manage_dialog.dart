import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/ids/ids.dart';
import '../../../core/time/clock.dart';
import '../../../di.dart';
import '../../../domain/entities/task.dart';
import '../../../domain/repositories/project_repository.dart';

/// 项目管理对话框：项目列表 + 新建/编辑/归档/删除。
class ProjectManageDialog extends StatefulWidget {
  /// 创建项目管理对话框。
  const ProjectManageDialog({super.key});

  /// 打开对话框。
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => const ProjectManageDialog(),
    );
  }

  @override
  State<ProjectManageDialog> createState() => _ProjectManageDialogState();
}

class _ProjectManageDialogState extends State<ProjectManageDialog> {
  final ProjectRepository _repository = getIt<ProjectRepository>();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('项目管理'),
      content: SizedBox(
        width: double.maxFinite,
        child: StreamBuilder<List<Project>>(
          stream: _repository.watchProjects(),
          builder: (context, snapshot) {
            final projects = snapshot.data ?? const <Project>[];
            if (projects.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  '还没有项目，点下方按钮新建',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final project in projects) _buildProjectItem(project),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => ProjectEditDialog.show(context),
          child: const Text('新建项目'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildProjectItem(Project project) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(project.name),
      subtitle: Text(
        project.goal == null || project.goal!.isEmpty
            ? (project.isArchived ? '已归档' : '未设置目标')
            : '${project.goal}${project.isArchived ? ' · 已归档' : ''}',
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'edit':
              ProjectEditDialog.show(context, project: project);
            case 'archive':
              _toggleArchive(project);
            case 'delete':
              _confirmDelete(project);
          }
        },
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
          PopupMenuItem<String>(
            value: 'archive',
            child: Text(project.isArchived ? '取消归档' : '归档'),
          ),
          const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  Future<void> _toggleArchive(Project project) async {
    await _run(
      () => _repository.save(
        project.copyWith(isArchived: !project.isArchived),
      ),
      '操作失败，请稍后重试',
    );
  }

  Future<void> _confirmDelete(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('确定要删除「${project.name}」吗？关联任务将变为无项目。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _run(() => _repository.delete(project.id), '删除失败，请稍后重试');
  }

  /// 统一异常提示。
  Future<void> _run(Future<void> Function() action, String fallback) async {
    try {
      await action();
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fallback)));
      }
    }
  }
}

/// 项目新建/编辑对话框。
class ProjectEditDialog extends StatefulWidget {
  /// 创建对话框；[project] 非空为编辑态。
  const ProjectEditDialog({super.key, this.project});

  /// 正在编辑的项目；为空表示新建。
  final Project? project;

  /// 打开对话框。
  static Future<void> show(BuildContext context, {Project? project}) {
    return showDialog<void>(
      context: context,
      builder: (context) => ProjectEditDialog(project: project),
    );
  }

  @override
  State<ProjectEditDialog> createState() => _ProjectEditDialogState();
}

class _ProjectEditDialogState extends State<ProjectEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _goalController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project?.name ?? '');
    _goalController = TextEditingController(text: widget.project?.goal ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.project == null ? '新建项目' : '编辑项目'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称'),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                return trimmed.isEmpty ? '名称不能为空' : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _goalController,
              decoration: const InputDecoration(labelText: '目标（可选）'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 保存项目；失败以 SnackBar 提示。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    try {
      await _persist();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后重试')),
        );
      }
    }
  }

  /// 构造并写入项目；id/时间戳等由仓储统一维护。
  Future<void> _persist() async {
    final repository = getIt<ProjectRepository>();
    final existing = widget.project;
    final now = const SystemClock().now();
    final goal = _goalController.text.trim();
    final project = Project(
      id: existing?.id ?? generateId(),
      userId: existing?.userId ?? '',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      deletedAt: existing?.deletedAt,
      version: existing?.version ?? 1,
      deviceId: existing?.deviceId ?? '',
      name: _nameController.text.trim(),
      goal: goal.isEmpty ? null : goal,
      isArchived: existing?.isArchived ?? false,
    );
    await repository.save(project);
  }
}
