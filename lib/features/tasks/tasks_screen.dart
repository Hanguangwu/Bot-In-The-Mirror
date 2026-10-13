import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../di.dart';
import '../../domain/entities/ai_plan.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/ai_plan_repository.dart';
import '../../domain/repositories/task_repository.dart';
import 'widgets/plan_preview_card.dart';
import 'widgets/task_edit_dialog.dart';

/// 任务页：过滤器+任务列表+AI拆解预览。
class TasksScreen extends StatefulWidget {
  /// 创建任务页。
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final TaskRepository _taskRepository = getIt<TaskRepository>();
  final AIPlanRepository _aiPlanRepository = getIt<AIPlanRepository>();

  String _filter = '今日';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务'),
      ),
      body: StreamBuilder<List<AIPlan>>(
        stream: _aiPlanRepository.watchPending(),
        builder: (context, pendingSnapshot) {
          final pendingPlans = pendingSnapshot.data ?? const <AIPlan>[];
          return StreamBuilder<List<Task>>(
            stream: _taskRepository.watchTasks(const TaskQuery()),
            builder: (context, tasksSnapshot) {
              final tasks = tasksSnapshot.data ?? const <Task>[];
              final filtered = _filterTasks(tasks);
              return CustomScrollView(
                slivers: <Widget>[
                  if (pendingPlans.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              '待确认的 AI 拆解',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          ...pendingPlans.map((p) => PlanPreviewCard(plan: p)),
                        ],
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          ChoiceChip(
                            label: const Text('今日'),
                            selected: _filter == '今日',
                            onSelected: (v) {
                              if (v) setState(() => _filter = '今日');
                            },
                          ),
                          ChoiceChip(
                            label: const Text('待办'),
                            selected: _filter == '待办',
                            onSelected: (v) {
                              if (v) setState(() => _filter = '待办');
                            },
                          ),
                          ChoiceChip(
                            label: const Text('已完成'),
                            selected: _filter == '已完成',
                            onSelected: (v) {
                              if (v) setState(() => _filter = '已完成');
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (filtered.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          '还没有任务，点右下角按钮新建，或让 Alice 帮你拆解',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final task = filtered[index];
                          return _buildTaskItem(task);
                        },
                        childCount: filtered.length,
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        // 与首页 FAB 同处壳内 IndexedStack（默认 Hero tag 冲突），禁用转场动画。
        heroTag: null,
        onPressed: _createTask,
        child: const Icon(Icons.add),
      ),
    );
  }

  List<Task> _filterTasks(List<Task> tasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    switch (_filter) {
      case '今日':
        final list = tasks.where((t) {
          if (t.status == TaskStatus.done || t.status == TaskStatus.cancelled) {
            return false;
          }
          if (t.dueAt == null) return false;
          final dueDay = DateTime(t.dueAt!.year, t.dueAt!.month, t.dueAt!.day);
          return dueDay.isBefore(tomorrow);
        }).toList();
        list.sort((a, b) {
          final ad = a.dueAt;
          final bd = b.dueAt;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        });
        return list;
      case '待办':
        final list = tasks
            .where((t) =>
                t.status == TaskStatus.inbox ||
                t.status == TaskStatus.planned ||
                t.status == TaskStatus.doing)
            .toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list;
      case '已完成':
        final list = tasks
            .where((t) =>
                t.status == TaskStatus.done || t.status == TaskStatus.cancelled)
            .toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list;
      default:
        return tasks;
    }
  }

  /// 任务条目：勾选完成、标题、优先级与截止徽标、操作菜单。
  Widget _buildTaskItem(Task task) {
    final isDone = task.status == TaskStatus.done;
    final isCancelled = task.status == TaskStatus.cancelled;
    return ListTile(
      leading: Checkbox(
        value: isDone,
        onChanged: (checked) => _updateStatus(
          task,
          checked == true ? TaskStatus.done : TaskStatus.inbox,
        ),
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: isDone ? TextDecoration.lineThrough : null,
          color: isDone || isCancelled ? Colors.grey : Colors.black87,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _buildPriorityBadge(task.priority),
            if (task.dueAt != null) _buildDueChip(task.dueAt!),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'edit':
              TaskEditDialog.show(context, task: task);
            case 'done':
              _updateStatus(task, TaskStatus.done);
            case 'cancel':
              _updateStatus(task, TaskStatus.cancelled);
          }
        },
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
          PopupMenuItem<String>(value: 'done', child: Text('完成')),
          PopupMenuItem<String>(value: 'cancel', child: Text('取消')),
        ],
      ),
    );
  }

  /// 优先级徽标：紧急红、高橙、其余灰。
  Widget _buildPriorityBadge(TaskPriority priority) {
    late final String label;
    late final Color color;
    switch (priority) {
      case TaskPriority.urgent:
        label = '紧急';
        color = Colors.red;
      case TaskPriority.high:
        label = '高';
        color = Colors.orange;
      case TaskPriority.medium:
        label = '中';
        color = Colors.grey;
      case TaskPriority.low:
        label = '低';
        color = Colors.grey;
    }
    return _badge(label, color);
  }

  /// 截止时间徽标：今日蓝色、已过期红色、其余灰色。
  Widget _buildDueChip(DateTime dueAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
    final dateText =
        '${dueDay.month.toString().padLeft(2, '0')}-${dueDay.day.toString().padLeft(2, '0')}';
    late final String label;
    late final Color color;
    if (dueDay.isBefore(today)) {
      label = '已过期 $dateText';
      color = Colors.red;
    } else if (dueDay.isAtSameMomentAs(today)) {
      label = '今日 $dateText';
      color = Colors.blue;
    } else {
      label = dateText;
      color = Colors.grey;
    }
    return _badge(label, color);
  }

  /// 小徽标。
  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }

  /// 更新任务状态（完成/恢复/取消）。
  Future<void> _updateStatus(Task task, TaskStatus status) async {
    try {
      await _taskRepository.save(task.copyWith(status: status));
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

  /// 新建任务。
  Future<void> _createTask() async {
    await TaskEditDialog.show(context);
  }
}
