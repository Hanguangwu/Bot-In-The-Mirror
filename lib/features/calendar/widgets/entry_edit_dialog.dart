import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/ids/ids.dart';
import '../../../core/time/clock.dart';
import '../../../di.dart';
import '../../../domain/entities/calendar.dart';
import '../../../domain/entities/task.dart';
import '../../../domain/repositories/calendar_entry_repository.dart';
import '../../../domain/repositories/task_repository.dart';

/// 日程新建/编辑对话框。
class EntryEditDialog extends StatefulWidget {
  /// 创建对话框；[entry] 非空为编辑态，[initialDate] 用于新建时预填日期。
  const EntryEditDialog({super.key, this.entry, this.initialDate});

  /// 正在编辑的日程；为空表示新建。
  final CalendarEntry? entry;

  /// 新建时的预填日期。
  final DateTime? initialDate;

  /// 打开对话框。
  static Future<void> show(
    BuildContext context, {
    CalendarEntry? entry,
    DateTime? initialDate,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => EntryEditDialog(
        entry: entry,
        initialDate: initialDate,
      ),
    );
  }

  @override
  State<EntryEditDialog> createState() => _EntryEditDialogState();
}

class _EntryEditDialogState extends State<EntryEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  late DateTime _startAt;
  late DateTime _endAt;
  late bool _allDay;
  late Set<String> _taskIds;

  bool get _isEditing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _titleController = TextEditingController(text: entry?.title ?? '');
    _noteController = TextEditingController(text: entry?.note ?? '');
    _allDay = entry?.allDay ?? false;
    _taskIds = <String>{...?entry?.taskIds};
    if (entry != null) {
      _startAt = entry.startAt;
      _endAt = entry.endAt;
    } else {
      final base = widget.initialDate ?? DateTime.now();
      _startAt = DateTime(base.year, base.month, base.day, 9);
      _endAt = _startAt.add(const Duration(hours: 1));
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? '编辑日程' : '新建日程'),
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
                  return trimmed.isEmpty ? '标题不能为空' : null;
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('全天'),
                value: _allDay,
                onChanged: (value) => setState(() => _allDay = value),
              ),
              _buildDateTimeRow(
                label: '开始',
                value: _startAt,
                onTap: _pickStart,
              ),
              _buildDateTimeRow(
                label: '结束',
                value: _endAt,
                onTap: _pickEnd,
              ),
              const SizedBox(height: 12),
              const Text('关联任务', style: TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 4),
              _buildTaskChips(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteController,
                decoration: const InputDecoration(labelText: '备注'),
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (_isEditing)
          TextButton(
            onPressed: _confirmDelete,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
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

  Widget _buildDateTimeRow({
    required String label,
    required DateTime value,
    required VoidCallback onTap,
  }) {
    final text = _allDay ? _formatDate(value) : _formatDateTime(value);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            SizedBox(width: 48, child: Text(label)),
            Expanded(child: Text(text)),
            const Icon(Icons.edit_calendar, size: 18, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskChips() {
    final repository = getIt<TaskRepository>();
    return StreamBuilder<List<Task>>(
      stream: repository.watchTasks(const TaskQuery()),
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? const <Task>[];
        if (tasks.isEmpty) {
          return const Text('暂无任务', style: TextStyle(color: Colors.grey));
        }
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            for (final task in tasks)
              FilterChip(
                label: Text(task.title),
                selected: _taskIds.contains(task.id),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _taskIds.add(task.id);
                    } else {
                      _taskIds.remove(task.id);
                    }
                  });
                },
              ),
          ],
        );
      },
    );
  }

  /// 选择开始时间；保证结束晚于开始。
  Future<void> _pickStart() async {
    final picked = await _pickDateTime(_startAt);
    if (picked == null) {
      return;
    }
    setState(() {
      _startAt = picked;
      if (!_endAt.isAfter(_startAt)) {
        _endAt = _allDay
            ? DateTime(_startAt.year, _startAt.month, _startAt.day + 1)
            : _startAt.add(const Duration(hours: 1));
      }
    });
  }

  /// 选择结束时间；早于/等于开始时间时提示。
  Future<void> _pickEnd() async {
    final picked = await _pickDateTime(_endAt);
    if (picked == null) {
      return;
    }
    if (!picked.isAfter(_startAt)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('结束时间需晚于开始时间')),
        );
      }
      return;
    }
    setState(() => _endAt = picked);
  }

  /// 日期 + 时间选择；全天模式下只选日期（结束为次日 00:00）。
  Future<DateTime?> _pickDateTime(DateTime current) async {
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 2),
      lastDate: DateTime(current.year + 5),
    );
    if (date == null) {
      return null;
    }
    if (_allDay) {
      return DateTime(date.year, date.month, date.day);
    }
    if (!mounted) {
      return null;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) {
      return null;
    }
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  /// 保存；失败以 SnackBar 提示。
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (!_allDay && !_endAt.isAfter(_startAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结束时间需晚于开始时间')),
      );
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

  /// 构造并写入日程；id/userId/时间戳等由仓储统一维护。
  Future<void> _persist() async {
    final repository = getIt<CalendarEntryRepository>();
    final existing = widget.entry;
    final now = const SystemClock().now();
    final startAt = _allDay
        ? DateTime(_startAt.year, _startAt.month, _startAt.day)
        : _startAt;
    final endAt = _allDay
        ? DateTime(startAt.year, startAt.month, startAt.day + 1)
        : _endAt;
    final note = _noteController.text.trim();
    final entry = CalendarEntry(
      id: existing?.id ?? generateId(),
      userId: existing?.userId ?? '',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      deletedAt: existing?.deletedAt,
      version: existing?.version ?? 1,
      deviceId: existing?.deviceId ?? '',
      title: _titleController.text.trim(),
      startAt: startAt,
      endAt: endAt,
      allDay: _allDay,
      taskIds: _taskIds.toList(),
      note: note.isEmpty ? null : note,
    );
    await repository.save(entry);
  }

  /// 删除（二次确认后软删）。
  Future<void> _confirmDelete() async {
    final entry = widget.entry;
    if (entry == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除日程'),
        content: const Text('确定要删除这个日程吗？'),
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
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await getIt<CalendarEntryRepository>().delete(entry.id);
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
          const SnackBar(content: Text('删除失败，请稍后重试')),
        );
      }
    }
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';

  String _formatDateTime(DateTime dt) =>
      '${_formatDate(dt)} ${_two(dt.hour)}:${_two(dt.minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');
}
