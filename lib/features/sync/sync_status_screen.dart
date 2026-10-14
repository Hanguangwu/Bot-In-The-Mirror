import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/local/identity_store.dart';
import '../../di.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/settings_store.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../../domain/sync/sync_credential_store.dart';
import '../../domain/sync/sync_engine.dart';
import '../../domain/sync/sync_status.dart';

/// 卡片小标题样式。
const TextStyle _sectionTitleStyle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.bold,
);

/// 同步状态页（M2b §10.1）。
///
/// 展示同步状态、上次同步时间、待同步条数与失败/冲突摘要，支持手动触发同步、
/// 配置同步服务地址，并脱敏展示身份与连接状态；未配置/无 token/网络失败均有
/// 明确文案，不崩溃。
///
/// 依赖全部经构造参数注入以便 widget 测试；生产从设置页 push 时传空，回退
/// `getIt`（由 Lane-C 装配）。
///
/// 关于失败/冲突摘要：失败条数取 `SyncStatus.lastReport.failed`；`conflicted`
/// 操作在同步收敛时即被 `deleteConflicted()` 清除，且队列域接口（Lane-0 冻结）
/// 未提供按状态计数，故冲突以引擎 `lastError` 摘要（如「版本落后，服务端已更新」）
/// 呈现，不伪造计数。
class SyncStatusScreen extends StatefulWidget {
  /// 创建同步状态页。
  const SyncStatusScreen({
    super.key,
    this.engine,
    this.queue,
    this.settings,
    this.credentials,
    this.identity,
  });

  /// 同步引擎；为空时回退 `getIt<SyncEngine>()`。
  final SyncEngine? engine;

  /// 本地同步队列；为空时回退 `getIt<SyncOperationRepository>()`。
  final SyncOperationRepository? queue;

  /// 设置存储（读写同步服务地址）；为空时回退 `getIt<SettingsStore>()`。
  final SettingsStore? settings;

  /// 同步凭证存储；为空时回退 `getIt<SyncCredentialStore>()`。
  final SyncCredentialStore? credentials;

  /// 匿名身份（脱敏展示）；为空时回退 `getIt<IdentityStore>()`。
  final IdentityStore? identity;

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  late final SyncEngine _engine = widget.engine ?? getIt<SyncEngine>();
  late final SyncOperationRepository _queue =
      widget.queue ?? getIt<SyncOperationRepository>();
  late final SettingsStore _settings = widget.settings ?? getIt<SettingsStore>();
  late final SyncCredentialStore _credentials =
      widget.credentials ?? getIt<SyncCredentialStore>();
  late final IdentityStore _identity = widget.identity ?? getIt<IdentityStore>();

  // 缓存订阅流：避免每次 build 重新取流导致 StreamBuilder 重订阅、
  // 丢失两次事件之间的推送（引擎实现可能每次返回新流对象）。
  late final Stream<SyncStatus> _statusStream = _engine.watchStatus();
  late final Stream<List<SyncOperation>> _pendingStream = _queue.watchPending();

  final TextEditingController _baseUrlController = TextEditingController();
  final DateFormat _timeFormat = DateFormat('yyyy-MM-dd HH:mm');

  /// 手动同步进行中（禁用按钮 + 进度指示）。
  bool _running = false;

  /// 服务地址保存中。
  bool _saving = false;

  /// 是否已取得 token（「已连接/未连接」）。
  bool _hasToken = false;

  /// 已持久化的工作区 ID（脱敏展示）。
  String? _workspaceId;

  @override
  void initState() {
    super.initState();
    _baseUrlController.text = _settings.syncBaseUrl;
    _loadCredentials();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    super.dispose();
  }

  /// 是否已配置同步服务地址。
  bool get _isConfigured => _settings.syncBaseUrl.trim().isNotEmpty;

  /// 读取凭证（token/workspaceId）；平台存储不可用时按未连接处理，不阻塞页面。
  Future<void> _loadCredentials() async {
    String? token;
    String? workspaceId;
    try {
      token = await _credentials.readToken();
      workspaceId = await _credentials.readWorkspaceId();
    } catch (_) {
      token = null;
      workspaceId = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _hasToken = token != null && token.isNotEmpty;
      _workspaceId = workspaceId;
    });
  }

  /// 去空白并去掉尾部斜杠（§9.3 服务基址规范化）。
  String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  /// 保存同步服务地址。
  Future<void> _saveBaseUrl() async {
    final normalized = _normalizeBaseUrl(_baseUrlController.text);
    setState(() => _saving = true);
    var saved = true;
    try {
      await _settings.saveSyncBaseUrl(normalized);
    } catch (_) {
      saved = false;
    }
    if (!mounted) {
      return;
    }
    // 同步输入框为规范化后的值。
    _baseUrlController.text = normalized;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '同步服务地址已保存' : '保存失败，请重试')),
    );
  }

  /// 手动触发同步（忽略退避）。
  Future<void> _runSync() async {
    if (_running) {
      return;
    }
    setState(() => _running = true);
    String message;
    try {
      final report = await _engine.sync(manual: true);
      message = '同步完成：推送 ${report.pushed} · 拉取 ${report.pulled}'
          '${report.failed > 0 ? ' · 失败 ${report.failed}' : ''}';
    } catch (_) {
      message = '同步失败，请稍后重试';
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
    // 同步可能完成匿名注册（token 由无到有），刷新连接状态。
    await _loadCredentials();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 重试失败项：`failed` → `pending`（§7.5）。
  Future<void> _retryFailed() async {
    var ok = true;
    try {
      await _queue.requeueFailed();
    } catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '失败项已重新排队，将在下次同步重试' : '重试操作失败，请稍后重试')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue.shade50,
      appBar: AppBar(
        backgroundColor: Colors.blue.shade100,
        title: const Text('同步', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<SyncStatus>(
        stream: _statusStream,
        initialData: _engine.status,
        builder: (context, statusSnapshot) {
          final status = statusSnapshot.data ?? _engine.status;
          return StreamBuilder<List<SyncOperation>>(
            stream: _pendingStream,
            initialData: const <SyncOperation>[],
            builder: (context, pendingSnapshot) {
              final pending = pendingSnapshot.data ?? const <SyncOperation>[];
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildStatusCard(status, pending.length),
                    const SizedBox(height: 16),
                    _buildSummaryCard(status),
                    const SizedBox(height: 16),
                    _buildConfigCard(),
                    const SizedBox(height: 16),
                    _buildIdentityCard(),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 状态区：状态徽标 + 待同步条数 + 上次同步时间 + 立即同步。
  Widget _buildStatusCard(SyncStatus status, int pendingCount) {
    final style = _stateStyle(status.state);
    final isSyncing = _running || status.state == SyncState.syncing;
    final lastSyncAt = status.lastSyncAt;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('同步状态', style: _sectionTitleStyle),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _badge(style.label, style.color),
              const Spacer(),
              Text(
                '待同步 $pendingCount 条',
                style: const TextStyle(color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow(
            '上次同步',
            lastSyncAt == null ? '尚未同步' : _timeFormat.format(lastSyncAt),
          ),
          if (!_isConfigured) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.deepOrange.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '填写同步服务地址后可用',
                style: TextStyle(color: Colors.deepOrange),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isSyncing || !_isConfigured ? null : _runSync,
              icon: isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync),
              label: Text(isSyncing ? '同步中…' : '立即同步'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 失败/冲突摘要：失败计数 + 最近错误摘要 + 重试失败项。
  Widget _buildSummaryCard(SyncStatus status) {
    final failed = status.lastReport?.failed ?? 0;
    final lastError = status.lastError;
    final hasFailures = failed > 0 || (lastError != null && lastError.isNotEmpty);
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('失败与冲突摘要', style: _sectionTitleStyle),
          const SizedBox(height: 12),
          _infoRow('失败条数', '$failed 条'),
          const SizedBox(height: 8),
          _infoRow('冲突/错误摘要', lastError ?? '无'),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: hasFailures ? _retryFailed : null,
              icon: const Icon(Icons.refresh),
              label: const Text('重试失败项'),
            ),
          ),
        ],
      ),
    );
  }

  /// 配置区：同步服务地址 + 保存。
  Widget _buildConfigCard() {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('同步服务', style: _sectionTitleStyle),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: 'https://sync.example.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveBaseUrl,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }

  /// 身份区：脱敏 userId/workspaceId + 连接状态（不显示明文 token）。
  Widget _buildIdentityCard() {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('身份', style: _sectionTitleStyle),
          const SizedBox(height: 12),
          _infoRow('用户 ID', _mask(_identity.userId)),
          const SizedBox(height: 8),
          _infoRow('工作区 ID', _mask(_workspaceId)),
          const SizedBox(height: 8),
          _infoRow('连接状态', _hasToken ? '已连接' : '未连接'),
        ],
      ),
    );
  }

  /// 脱敏：仅保留首尾各 4 位（短值首尾各 1 位）；空值显示「未设置」。
  String _mask(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '未设置';
    }
    if (text.length <= 8) {
      return '${text.substring(0, 1)}…${text.substring(text.length - 1)}';
    }
    return '${text.substring(0, 4)}…${text.substring(text.length - 4)}';
  }

  /// 状态徽标文案与颜色。
  ({String label, Color color}) _stateStyle(SyncState state) {
    switch (state) {
      case SyncState.idle:
        return (label: '闲置', color: Colors.grey);
      case SyncState.syncing:
        return (label: '同步中', color: Colors.blue);
      case SyncState.offline:
        return (label: '离线', color: Colors.orange);
      case SyncState.failed:
        return (label: '失败', color: Colors.red);
    }
  }

  /// 统一卡片（与设置页视觉一致）。
  Widget _card(Widget child) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  /// 标签/值一行。
  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: const TextStyle(color: Colors.grey)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  /// 小徽标（沿用任务页样式）。
  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
