import 'dart:async';

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/sync.dart';
import '../../domain/repositories/settings_store.dart';
import '../../domain/repositories/sync_operation_repository.dart';
import '../../domain/sync/sync_api.dart';
import '../../domain/sync/sync_change.dart';
import '../../domain/sync/sync_credential_store.dart';
import '../../domain/sync/sync_cursor_store.dart';
import '../../domain/sync/sync_engine.dart';
import '../../domain/sync/sync_entity_store.dart';
import '../../domain/sync/sync_status.dart';
import '../local/identity_store.dart';

/// SyncEngine 编排实现（§6.1）。
///
/// 严格按 M2b 契约：
/// - 前置：`syncBaseUrl` 为空 → 返回空报告、状态 `idle`、**不触网**；
///   无 token → `register` 并持久化 token/workspaceId。
/// - 推送：循环分批（≤ `syncPushBatchSize`，至多 `maxPushPasses` 轮）；
///   `applied` → `synced`、`conflict` → `conflicted`、`rejected` → `failed`；
///   整批网络/`5xx`/401（已重注册仍失败）→ 保持 `pending`、`retryCount++`、
///   记 `lastError`、`failed += n`、退出推送循环。
/// - 推送结束后 `deleteSynced()`（§7.5）。
/// - 拉取：游标自 `SyncCursorStore`；跳过本机 `deviceId`（回声抑制双保险，
///   §7.3）→ `SyncEntityStore.applyRemote` → `pulled++`；游标推进即持久化；
///   `hasMore` 且未超 `maxPullPages` 继续；完成后持久化 `lastSyncAt`。
/// - 收敛：拉取完成后 `deleteConflicted()`（§6.1 步骤 4）。
/// - 收尾：`SyncReport(pushed, pulled, failed, cursor:int?, at)`；
///   状态 `syncing` → `idle`（有失败 → `failed`；网络异常 → `offline`）。
/// - 退避：自动同步距上次尝试 < 当前退避（指数升至上限）时跳过；
///   `manual: true` 忽略退避。
/// - 401：自动重新 `register` 一次并以新 token 重试该请求（§14.6）。
class SyncEngineImpl implements SyncEngine {
  /// 创建引擎。
  SyncEngineImpl({
    required RemoteSyncApi api,
    required SyncOperationRepository operations,
    required SettingsStore settings,
    required SyncCredentialStore credentials,
    required SyncCursorStore cursorStore,
    required SyncEntityStore entityStore,
    required IdentityStore identity,
    Clock? clock,
  })  : _api = api,
        _operations = operations,
        _settings = settings,
        _credentials = credentials,
        _cursorStore = cursorStore,
        _entityStore = entityStore,
        _identity = identity,
        _clock = clock ?? const SystemClock();

  /// 冲突统一文案（§6.1 步骤 2）。
  static const String conflictMessage = '版本落后，服务端已更新';

  final RemoteSyncApi _api;
  final SyncOperationRepository _operations;
  final SettingsStore _settings;
  final SyncCredentialStore _credentials;
  final SyncCursorStore _cursorStore;
  final SyncEntityStore _entityStore;
  final IdentityStore _identity;
  final Clock _clock;

  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus(state: SyncState.idle);

  /// 上次同步**尝试**时间（含成功/失败），供自动同步退避判断（§6.1 步骤 6）。
  DateTime? _lastAttemptAt;

  /// 当前退避窗口：失败后指数翻倍、成功后复位（上限 `syncBackoffMax`）。
  Duration _currentBackoff = AppConfig.syncBackoffBase;

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> watchStatus() => _statusController.stream;

  void _emit(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  SyncReport _emptyReport(DateTime at) =>
      SyncReport(pushed: 0, pulled: 0, failed: 0, at: at, cursor: null);

  @override
  Future<SyncReport> sync({bool manual = false}) async {
    // 防重入：启动自动同步与手动同步并发时只允许一路执行。
    if (_status.state == SyncState.syncing) {
      return _status.lastReport ?? _emptyReport(_clock.now());
    }

    // §6.1 步骤 1：未配置基址 → 空转，状态 idle，不报错、不触网。
    if (_settings.syncBaseUrl.trim().isEmpty) {
      final report = _emptyReport(_clock.now());
      _emit(
        SyncStatus(
          state: SyncState.idle,
          lastReport: report,
          lastError: null,
          lastSyncAt: _status.lastSyncAt,
        ),
      );
      return report;
    }

    final now = _clock.now();

    // §6.1 步骤 6：自动同步退避（手动忽略）。
    final lastAttempt = _lastAttemptAt;
    if (!manual &&
        lastAttempt != null &&
        now.difference(lastAttempt) < _currentBackoff) {
      return _status.lastReport ?? _emptyReport(now);
    }

    _lastAttemptAt = now;
    _emit(
      SyncStatus(
        state: SyncState.syncing,
        lastReport: _status.lastReport,
        lastError: _status.lastError,
        lastSyncAt: _status.lastSyncAt,
      ),
    );

    var pushed = 0;
    var pulled = 0;
    var failed = 0;

    // 拉取游标（报告用 int?：未进入拉取阶段时为 null，B3）。
    int? cursor;
    String? lastError;

    try {
      // §6.1 步骤 1：无 token → 注册并持久化 token/workspaceId。
      final storedToken = await _credentials.readToken();
      var token = storedToken ?? await _ensureRegistered();

      // ---- 推送（§6.1 步骤 2，A2 循环分批）----
      var offline = false;
      for (var pass = 0; pass < AppConfig.maxPushPasses; pass++) {
        final pending = await _operations.getPending();
        if (pending.isEmpty) {
          break;
        }
        final batch = pending
            .take(AppConfig.syncPushBatchSize)
            .toList(growable: false);
        try {
          final resp = await _withAuthRetry(
            token,
            (t) => _api.push(token: t, operations: batch),
          );
          for (final r in resp.results) {
            final idx = batch.indexWhere((op) => op.id == r.opId);
            if (idx < 0) {
              continue;
            }
            final op = batch[idx];
            switch (r.status) {
              case PushItemStatus.applied:
                await _operations.mark(
                  op.copyWith(status: SyncOperationStatus.synced),
                );
                pushed += 1;
              case PushItemStatus.conflict:
                // 冲突不计入 failed：拉取（LWW）收敛后由 deleteConflicted 清除。
                await _operations.mark(
                  op.copyWith(
                    status: SyncOperationStatus.conflicted,
                    lastError: conflictMessage,
                  ),
                );
              case PushItemStatus.rejected:
                final reason = r.reason ?? '远端拒绝该变更';
                await _operations.mark(
                  op.copyWith(
                    status: SyncOperationStatus.failed,
                    lastError: reason,
                  ),
                );
                failed += 1;
                lastError = reason;
            }
          }
        } on SyncNetworkException catch (e) {
          // 整批网络失败：保持 pending、retryCount++、记 lastError、
          // failed += n，退出推送循环。
          await _retainBatch(batch, e);
          failed += batch.length;
          lastError = e.toString();
          offline = true;
          break;
        } on SyncApiException catch (e) {
          // 401（重注册一次后仍失败）/5xx/其他远端错误：同上保持 pending，
          // 退出推送循环（§6.1 步骤 2）。
          await _retainBatch(batch, e);
          failed += batch.length;
          lastError = e.toString();
          break;
        }
        // A1：`_withAuthRetry` 内部可能已因 401 重注册换发新 token，
        // 每轮回读，避免多轮推送（>100 条）反复 401 → 重复注册。
        token = await _credentials.readToken() ?? token;
      }

      // §6.1 步骤 2：推送结束删除已同步操作（§7.5）。
      await _operations.deleteSynced();

      if (offline) {
        // 网络已断定：跳过拉取，直接以 offline 收尾（§7.4）。
        final report = SyncReport(
          pushed: pushed,
          pulled: 0,
          failed: failed,
          at: now,
          cursor: null,
        );
        _updateBackoff();
        _emit(
          SyncStatus(
            state: SyncState.offline,
            lastReport: report,
            lastError: lastError,
            lastSyncAt: _status.lastSyncAt,
          ),
        );
        return report;
      }

      // ---- 拉取（§6.1 步骤 3，B2 游标）----
      // 推送阶段可能已因 401 重注册换发新 token：拉取沿用最新持久化 token。
      token = await _credentials.readToken() ?? token;
      var page = await _cursorStore.read();
      final localDeviceId = _identity.deviceId;
      for (var i = 0; i < AppConfig.maxPullPages; i++) {
        final resp = await _withAuthRetry(
          token,
          (t) => _api.pull(token: t, cursor: page),
        );
        for (final change in resp.changes) {
          // §7.3 回声抑制：跳过本机设备（服务端已过滤，此处双保险）。
          if (change.deviceId == localDeviceId) {
            continue;
          }
          await _entityStore.applyRemote(change);
          pulled += 1;
        }
        page = resp.cursor;
        cursor = page;
        // 游标推进即落盘：中途失败不丢已确认进度。
        await _cursorStore.write(page);
        if (!resp.hasMore) {
          break;
        }
      }
      // §9.2：持久化上次同步完成时间。
      await _cursorStore.writeLastSyncAt(now);

      // §6.1 步骤 4（A4）：拉取收敛后删除冲突操作。
      await _operations.deleteConflicted();

      // ---- 收尾（§6.1 步骤 5）----
      final report = SyncReport(
        pushed: pushed,
        pulled: pulled,
        failed: failed,
        at: now,
        cursor: cursor,
      );
      if (failed > 0) {
        _updateBackoff();
        _emit(
          SyncStatus(
            state: SyncState.failed,
            lastReport: report,
            lastError: lastError,
            lastSyncAt: now,
          ),
        );
      } else {
        _resetBackoff();
        _emit(
          SyncStatus(
            state: SyncState.idle,
            lastReport: report,
            lastError: null,
            lastSyncAt: now,
          ),
        );
      }
      return report;
    } on SyncNetworkException catch (e) {
      // §7.4：断网（注册/拉取阶段）→ 状态 offline，操作保持 pending。
      final report = SyncReport(
        pushed: pushed,
        pulled: pulled,
        failed: failed,
        at: now,
        cursor: cursor,
      );
      _updateBackoff();
      _emit(
        SyncStatus(
          state: SyncState.offline,
          lastReport: report,
          lastError: e.toString(),
          lastSyncAt: _status.lastSyncAt,
        ),
      );
      return report;
    } on AppException catch (e) {
      // 其余同步异常（401/4xx/5xx/解码失败等）→ 状态 failed，不阻塞 UI。
      final report = SyncReport(
        pushed: pushed,
        pulled: pulled,
        failed: failed,
        at: now,
        cursor: cursor,
      );
      _updateBackoff();
      _emit(
        SyncStatus(
          state: SyncState.failed,
          lastReport: report,
          lastError: e.toString(),
          lastSyncAt: _status.lastSyncAt,
        ),
      );
      return report;
    } finally {
      // B1：任何未被上述 catch 覆盖的异常（如损坏 payload 触发的
      // `FormatException`、枚举 `.byName` 触发的 `ArgumentError`、Drift 写入
      // 触发的 `SqliteException`）都会穿过整段 `sync()`，把状态永久留在
      // `syncing`：顶部防重入护栏会令之后所有同步直接短路，状态页「立即同步」
      // 永久禁用 → 不可自愈。此处兜底落地 `failed` 终态，保证可恢复。
      if (_status.state == SyncState.syncing) {
        _updateBackoff();
        _emit(
          SyncStatus(
            state: SyncState.failed,
            lastReport: _status.lastReport,
            lastError: _status.lastError ?? '同步异常',
            lastSyncAt: _status.lastSyncAt,
          ),
        );
      }
    }
  }

  /// 匿名注册并持久化凭证（§5.1）；身份只来自本地 `IdentityStore`。
  Future<String> _ensureRegistered() async {
    final session = await _api.register(
      userId: _identity.userId,
      deviceId: _identity.deviceId,
    );
    await _credentials.saveToken(session.token);
    await _credentials.saveWorkspaceId(session.workspaceId);
    return session.token;
  }

  /// 401 自动重注册一次并用新 token 重试（§14.6）；重试仍 401 则向上抛出。
  Future<T> _withAuthRetry<T>(
    String token,
    Future<T> Function(String token) action,
  ) async {
    try {
      return await action(token);
    } on SyncApiException catch (e) {
      if (e.statusCode != 401) {
        rethrow;
      }
      final freshToken = await _ensureRegistered();
      return await action(freshToken);
    }
  }

  /// 整批失败时保持 `pending`（§6.1 步骤 2）：`retryCount++`、记 `lastError`，
  /// 操作不流失、留待下次同步自动重试（§7.4）。
  Future<void> _retainBatch(List<SyncOperation> batch, Object error) async {
    final message = error.toString();
    for (final op in batch) {
      await _operations.mark(
        op.copyWith(
          status: SyncOperationStatus.pending,
          retryCount: op.retryCount + 1,
          lastError: message,
        ),
      );
    }
  }

  /// 失败后指数扩大退避窗口（上限 `syncBackoffMax`）。
  void _updateBackoff() {
    final doubled = _currentBackoff.inMilliseconds * 2;
    _currentBackoff = Duration(
      milliseconds: doubled.clamp(
        AppConfig.syncBackoffBase.inMilliseconds,
        AppConfig.syncBackoffMax.inMilliseconds,
      ),
    );
  }

  /// 同步成功后复位退避窗口。
  void _resetBackoff() {
    _currentBackoff = AppConfig.syncBackoffBase;
  }
}
