import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../di.dart';
import '../../../domain/entities/ai_plan.dart';
import '../../../domain/entities/conversation.dart';
import '../../../domain/repositories/ai_plan_repository.dart';
import '../../../domain/repositories/conversation_repository.dart';
import '../../tasks/application/confirm_task_plan.dart';
import '../../tasks/application/reject_task_plan.dart';

/// AI 拆解计划预览卡片。
class PlanPreviewCard extends StatefulWidget {
  /// 创建预览卡片。
  const PlanPreviewCard({super.key, required this.plan});

  /// 待确认的计划。
  final AIPlan plan;

  @override
  State<PlanPreviewCard> createState() => _PlanPreviewCardState();
}

class _PlanPreviewCardState extends State<PlanPreviewCard> {
  final ConversationRepository _conversationRepository =
      getIt<ConversationRepository>();
  // 一次性读取来源消息：写在 build 里的话，FutureBuilder 每次重建都会创建
  // 新 Future，确认/拒绝切换 loading 时标题会闪烁回落（评审 A1）。
  late final Future<List<Message>> _sourceMessages = _conversationRepository
      .getMessages(widget.plan.conversationId);
  bool _loading = false;

  String _formatDateTime(DateTime dt) {
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FutureBuilder<List<Message>>(
              future: _sourceMessages,
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <Message>[];
                final source = messages
                    .where(
                      (m) => m.id == widget.plan.sourceMessageId,
                    )
                    .cast<Message?>()
                    .firstOrNull;
                final title = source?.content.trim().isNotEmpty == true
                    ? source!.content.trim()
                    : 'AI 拆解计划 · ${_formatDateTime(widget.plan.createdAt)}';
                return Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              '模型 ${widget.plan.aiModel} · ${widget.plan.promptVersion} · ${_formatDateTime(widget.plan.createdAt)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              '将创建 ${widget.plan.changes.length} 个任务',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            ...widget.plan.changes.map((change) => _buildChange(change)),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                FilledButton(
                  onPressed: _loading ? null : _confirm,
                  child: const Text('确认'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _loading ? null : _reject,
                  child: const Text('拒绝'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 单条变更摘要（createTask 的 payload）。
  Widget _buildChange(AIPlanChange change) {
    final payload = change.payload;
    final title = (payload['title'] as String?)?.trim();
    final priority = payload['priority'] as String?;
    final dueAtText = payload['dueAt'] as String?;
    final dueAt =
        dueAtText == null ? null : DateTime.tryParse(dueAtText)?.toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('• '),
          Expanded(
            child: Text(
              title == null || title.isEmpty ? '未命名任务' : title,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (priority != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                _priorityLabel(priority),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          if (dueAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${dueAt.month.toString().padLeft(2, '0')}-${dueAt.day.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  /// 优先级文案（payload 存字符串枚举名）。
  String _priorityLabel(String priority) {
    switch (priority.toLowerCase()) {
      case 'urgent':
        return '紧急';
      case 'high':
        return '高';
      case 'low':
        return '低';
      default:
        return '中';
    }
  }

  /// 确认计划：写入正式任务并把计划置为 applied。
  Future<void> _confirm() async {
    setState(() => _loading = true);
    try {
      await ConfirmTaskPlan(aiPlanRepository: getIt<AIPlanRepository>())
          .confirm(widget.plan.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已写入任务')),
        );
      }
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('确认失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 拒绝计划：标记 rejected，不写入任务。
  Future<void> _reject() async {
    setState(() => _loading = true);
    try {
      await RejectTaskPlan(aiPlanRepository: getIt<AIPlanRepository>())
          .reject(widget.plan.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已拒绝该拆解')),
        );
      }
    } on AppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('拒绝失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }
}
