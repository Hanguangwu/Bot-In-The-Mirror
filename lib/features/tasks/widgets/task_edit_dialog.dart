import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/ids/ids.dart';
import '../../../core/time/clock.dart';
import '../../../di.dart';
import '../../../domain/entities/task.dart';
import '../../../domain/repositories/project_repository.dart';
import '../../../domain/repositories/task_repository.dart';

/// 任务新建/编辑对话框。
class TaskEditDialog extends StatefulWidget {
  /// 创建对话框；[task] 非空为编辑态。
  const TaskEditDialog({super.key, this.task});

  /// 正在编辑的任务；为空表示新建。
  final Task? task;

  /// 打开对话框。
  static Future<void> show(BuildContext context, {Task? task}) {
    return showDialog<void>(
      context: context,
      builder: (context) => TaskEditDialog(task: task),
    );
  }

  @override
  State<TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<TaskEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late TaskPriority _priority;
  DateTime? _dueAt;
  String? _projectId;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController =
        TextEditingController(text: task?.description ?? '');
    _priority = task?.priority ?? TaskPriority.medium;
    _dueAt = task?.dueAt;
    _projectId = task?.projectId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.task == null ? '新建任务' : '编辑任务'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: '标题'),
                validator: (value) {
                  final trimmed = value?.trim() ?? '';
                  if (trimmed.isEmpty) {
                    return '标题不能为空';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: '描述'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              _buildProjectDropdown(),
              const SizedBox(height: 12),
              DropdownButtonFormField<TaskPriority>(
                decoration: const InputDecoration(labelText: '优先级'),
                initialValue: _priority,
                items: const <DropdownMenuItem<TaskPriority>>[
                  DropdownMenuItem<TaskPriority>(
                    value: TaskPriority.low,
                    child: Text('低'),
                  ),
                  DropdownMenuItem<TaskPriority>(
                    value: TaskPriority.medium,
                    child: Text('中'),
                  ),
                  DropdownMenuItem<TaskPriority>(
                    value: TaskPriority.high,
                    child: Text('高'),
                  ),
                  DropdownMenuItem<TaskPriority>(
                    value: TaskPriority.urgent,
                    child: Text('紧急'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _priority = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _dueAt == null
                          ? '未设置截止时间'
                          : '${_dueAt!.year}-${_dueAt!.month.toString().padLeft(2, '0')}-${_dueAt!.day.toString().padLeft(2, '0')}',
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _dueAt ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 5),
                      );
                      if (picked != null) {
                        setState(() => _dueAt =
                            DateTime(picked.year, picked.month, picked.day));
                      }
                    },
                  ),
                  if (_dueAt != null)
                    TextButton(
                      onPressed: () {
                        setState(() => _dueAt = null);
                      },
                      child: const Text('清除'),
                    ),
                ],
              ),
            ],
          ),
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

  /// 项目下拉（可选）；空串哨兵代表「无项目」。
  Widget _buildProjectDropdown() {
    final repository = getIt<ProjectRepository>();
    return StreamBuilder<List<Project>>(
      stream: repository.watchProjects(),
      builder: (context, snapshot) {
        final projects = snapshot.data ?? const <Project>[];
        // 项目已被删除时回退「无项目」（直接同步状态，避免下拉断言）。
        if (_projectId != null && !projects.any((p) => p.id == _projectId)) {
          _projectId = null;
        }
        return DropdownButtonFormField<String>(
          decoration: const InputDecoration(labelText: '项目'),
          initialValue: _projectId ?? '',
          items: <DropdownMenuItem<String>>[
            const DropdownMenuItem<String>(value: '', child: Text('无项目')),
            for (final project in projects)
              DropdownMenuItem<String>(
                value: project.id,
                child: Text(project.name),
              ),
          ],
          onChanged: (value) {
            setState(() {
              _projectId = value == null || value.isEmpty ? null : value;
            });
          },
        );
      },
    );
  }

  /// 保存；失败时抛出，由 [_save] 统一提示。
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

  /// 构造并保存任务；id/userId/时间戳等由仓储统一维护。
  Future<void> _persist() async {
    final repository = getIt<TaskRepository>();
    final now = const SystemClock().now();
    final task = widget.task;
    final description = _descriptionController.text.trim();
    if (task == null) {
      final newTask = Task(
        id: generateId(),
        userId: '',
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: '',
        projectId: _projectId,
        title: _titleController.text.trim(),
        description: description.isEmpty ? null : description,
        priority: _priority,
        dueAt: _dueAt,
        sourceMessageId: null,
        sortOrder: 0,
      );
      await repository.save(newTask);
    } else {
      final updated = task.copyWith(
        title: _titleController.text.trim(),
        description: description.isEmpty ? null : description,
        priority: _priority,
        dueAt: _dueAt,
        projectId: _projectId,
        clearDueAt: _dueAt == null && task.dueAt != null,
        clearDescription: description.isEmpty && task.description != null,
        updatedAt: now,
        version: task.version + 1,
      );
      // copyWith 无 clearProjectId，需要移除项目归属时重建实体。
      final saved = _projectId == null && task.projectId != null
          ? _detachProject(updated)
          : updated;
      await repository.save(saved);
    }
  }

  /// 复制任务并清空项目归属（规避 copyWith 无法置空的约定）。
  Task _detachProject(Task task) {
    return Task(
      id: task.id,
      userId: task.userId,
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      deletedAt: task.deletedAt,
      version: task.version,
      deviceId: task.deviceId,
      projectId: null,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      dueAt: task.dueAt,
      parentTaskId: task.parentTaskId,
      repeatRule: task.repeatRule,
      sourceMessageId: task.sourceMessageId,
      sortOrder: task.sortOrder,
    );
  }
}
