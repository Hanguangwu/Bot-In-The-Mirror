import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/ids/ids.dart';
import '../../../core/time/clock.dart';
import '../../../di.dart';
import '../../../domain/entities/task.dart';
import '../../../domain/repositories/task_repository.dart';

/// 任务编辑对话框。
class TaskEditDialog extends StatefulWidget {
  /// 创建对话框。
  const TaskEditDialog({super.key, this.task});

  /// 初始任务（null 表示新建）。
  final Task? task;

  /// 显示对话框。
  static Future<Task?> show(BuildContext context, {Task? task}) {
    return showDialog<Task>(
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

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController = TextEditingController(text: task?.description ?? '');
    _priority = task?.priority ?? TaskPriority.medium;
    _dueAt = task?.dueAt;
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
              DropdownButtonFormField<TaskPriority>(
                initialValue: _priority,
                decoration: const InputDecoration(labelText: '优先级'),
                items: const <DropdownMenuItem<TaskPriority>>[
                  DropdownMenuItem(
                    value: TaskPriority.low,
                    child: Text('低'),
                  ),
                  DropdownMenuItem(
                    value: TaskPriority.medium,
                    child: Text('中'),
                  ),
                  DropdownMenuItem(
                    value: TaskPriority.high,
                    child: Text('高'),
                  ),
                  DropdownMenuItem(
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
                        setState(() => _dueAt = DateTime(picked.year, picked.month, picked.day));
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    try {
      await _persist();
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

  /// 构造并保存任务；失败时抛出，由 [_save] 统一提示。
  Future<void> _persist() async {
    final repository = getIt<TaskRepository>();
    final now = const SystemClock().now();
    final task = widget.task;
    if (task == null) {
      final newTask = Task(
        id: generateId(),
        userId: newUserId(),
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: newDeviceId(),
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        priority: _priority,
        dueAt: _dueAt,
        sourceMessageId: null,
        sortOrder: 0,
      );
      final saved = await repository.save(newTask);
      if (mounted) {
        Navigator.of(context).pop(saved);
      }
    } else {
      final updated = task.copyWith(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        priority: _priority,
        dueAt: _dueAt,
        clearDueAt: _dueAt == null && task.dueAt != null,
        clearDescription:
            _descriptionController.text.trim().isEmpty && task.description != null,
        updatedAt: now,
        version: task.version + 1,
      );
      final saved = await repository.save(updated);
      if (mounted) {
        Navigator.of(context).pop(saved);
      }
    }
  }
}
