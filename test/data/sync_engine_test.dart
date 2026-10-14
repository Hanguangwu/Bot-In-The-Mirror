import 'package:chatwithalice/core/config/app_config.dart';
import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/memory_identity_store.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_cursor_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_credential_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/data/sync/sync_engine_impl.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/sync/sync_api.dart';
import 'package:chatwithalice/domain/sync/sync_change.dart';
import 'package:chatwithalice/domain/sync/sync_entity_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控时钟（退避测试用）。
class _MutableClock implements Clock {
  _MutableClock(this.current);

  DateTime current;

  void advance(Duration by) => current = current.add(by);

  @override
  DateTime now() => current;
}

/// 假 RemoteSyncApi：记录调用，行为经回调注入；绝不触网。
class _FakeApi implements RemoteSyncApi {
  int registerCount = 0;
  final List<String> pushTokens = <String>[];
  final List<String> pullTokens = <String>[];
  final List<int> pullCursors = <int>[];
  final List<List<SyncOperation>> pushBatches = <List<SyncOperation>>[];

  Future<PushResponse> Function(List<SyncOperation> operations)? onPush;
  Future<PullResponse> Function(int cursor)? onPull;

  @override
  Future<AnonymousSession> register({
    required String userId,
    required String deviceId,
  }) async {
    registerCount += 1;
    return AnonymousSession(
      token: 'token-$registerCount',
      userId: userId,
      workspaceId: 'ws-1',
      deviceId: deviceId,
    );
  }

  @override
  Future<PushResponse> push({
    required String token,
    required List<SyncOperation> operations,
  }) async {
    pushTokens.add(token);
    pushBatches.add(List<SyncOperation>.of(operations));
    final override = onPush;
    if (override != null) {
      return override(operations);
    }
    return PushResponse(
      results: <PushItemResult>[
        for (final op in operations)
          PushItemResult(opId: op.id, status: PushItemStatus.applied),
      ],
    );
  }

  @override
  Future<PullResponse> pull({
    required String token,
    required int cursor,
    int limit = AppConfig.syncPullLimit,
  }) async {
    pullTokens.add(token);
    pullCursors.add(cursor);
    final override = onPull;
    if (override != null) {
      return override(cursor);
    }
    return PullResponse(
      changes: const <SyncChange>[],
      cursor: cursor,
      hasMore: false,
    );
  }
}

/// 记录型 SyncEntityStore 假实现。
class _RecordingEntityStore implements SyncEntityStore {
  final List<SyncChange> applied = <SyncChange>[];

  /// 非空时 `applyRemote` 抛出该异常（B1：模拟非 AppException 的落地失败）。
  Object? applyError;

  @override
  Future<bool> applyRemote(SyncChange change) async {
    final error = applyError;
    if (error != null) {
      throw error;
    }
    applied.add(change);
    return true;
  }

  @override
  Future<({int version, DateTime updatedAt})?> localVersion(
    String entityType,
    String entityId,
  ) async =>
      null;
}

/// 引擎测试环境：全内存/假实现，绝不触网。
class _Env {
  _Env({
    required this.api,
    required this.queue,
    required this.cursorStore,
    required this.credentials,
    required this.entityStore,
    required this.settings,
    required this.engine,
    required this.clock,
  });

  final _FakeApi api;
  final MemorySyncOperationRepository queue;
  final MemorySyncCursorStore cursorStore;
  final MemorySyncCredentialStore credentials;
  final _RecordingEntityStore entityStore;
  final MemorySettingsStore settings;
  final SyncEngineImpl engine;
  final _MutableClock clock;

  /// 队列当前全部操作快照。
  List<SyncOperation> get operations =>
      List<SyncOperation>.of(queue.snapshot()! as List<SyncOperation>);
}

Future<_Env> _buildEnv({
  String baseUrl = 'https://sync.example.com',
  DateTime? now,
}) async {
  final api = _FakeApi();
  final clock = _MutableClock(now ?? DateTime.utc(2026, 6, 1, 8));
  final queue = MemorySyncOperationRepository(
    userId: 'user-1',
    deviceId: 'device-1',
  );
  final cursorStore = MemorySyncCursorStore();
  final credentials = MemorySyncCredentialStore();
  final entityStore = _RecordingEntityStore();
  final settings = MemorySettingsStore();
  if (baseUrl.isNotEmpty) {
    await settings.saveSyncBaseUrl(baseUrl);
  }
  final engine = SyncEngineImpl(
    api: api,
    operations: queue,
    settings: settings,
    credentials: credentials,
    cursorStore: cursorStore,
    entityStore: entityStore,
    identity: MemoryIdentityStore(userId: 'user-1', deviceId: 'device-1'),
    clock: clock,
  );
  return _Env(
    api: api,
    queue: queue,
    cursorStore: cursorStore,
    credentials: credentials,
    entityStore: entityStore,
    settings: settings,
    engine: engine,
    clock: clock,
  );
}

final DateTime _t0 = DateTime.utc(2026, 6, 1, 8);

/// 构造一条待同步操作。
SyncOperation _op({
  required String id,
  int index = 0,
  DateTime? createdAt,
}) {
  final at = createdAt ?? _t0;
  return SyncOperation(
    id: id,
    userId: 'user-1',
    createdAt: at,
    updatedAt: at,
    version: 1,
    deviceId: 'device-1',
    entityType: 'task',
    entityId: 'e-$id',
    kind: SyncOperationKind.create,
    payload: <String, Object?>{
      'id': 'e-$id',
      'userId': 'user-1',
      'version': 1,
      'updatedAt': at.toIso8601String(),
      'deviceId': 'device-1',
      'title': '任务 $index',
    },
  );
}

/// 构造一条远端变更（默认来自其他设备）。
SyncChange _change({
  required int seq,
  String deviceId = 'device-remote',
  String? entityId,
}) {
  final id = entityId ?? 'e-$seq';
  return SyncChange(
    seq: seq,
    entityType: 'task',
    entityId: id,
    kind: SyncOperationKind.update,
    version: seq,
    deviceId: deviceId,
    updatedAt: _t0,
    payload: <String, Object?>{
      'id': id,
      'userId': 'user-1',
      'version': seq,
      'updatedAt': _t0.toIso8601String(),
      'deviceId': deviceId,
      'title': '远端 $seq',
    },
  );
}

void main() {
  group('SyncEngineImpl', () {
    test('未配置基址：空转不触网，状态 idle、空报告', () async {
      final env = await _buildEnv(baseUrl: '');

      final report = await env.engine.sync();

      expect(report.pushed, 0);
      expect(report.pulled, 0);
      expect(report.failed, 0);
      expect(report.cursor, isNull);
      expect(env.api.registerCount, 0);
      expect(env.api.pushBatches, isEmpty);
      expect(env.api.pullCursors, isEmpty);
      expect(env.engine.status.state, SyncState.idle);
    });

    test('无 token 先注册；applied → synced → 推送后删除', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));

      final report = await env.engine.sync();

      expect(env.api.registerCount, 1);
      expect(env.api.pushBatches.single, hasLength(1));
      expect(report.pushed, 1);
      expect(report.failed, 0);
      expect(env.operations, isEmpty); // synced 已被 deleteSynced 清除
      expect(env.engine.status.state, SyncState.idle);
      expect(env.engine.status.lastError, isNull);
      expect(await env.cursorStore.readLastSyncAt(), isNotNull); // §9.2 持久化
    });

    test('conflict → conflicted（拉取中可见），拉取后删除且不计 failed', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));
      late List<SyncOperation> seenAtPull;
      env.api.onPush = (ops) async => PushResponse(
            results: <PushItemResult>[
              PushItemResult(
                opId: ops.single.id,
                status: PushItemStatus.conflict,
                reason: 'stale_version',
                serverVersion: 4,
              ),
            ],
          );
      env.api.onPull = (cursor) async {
        seenAtPull = env.operations; // deleteConflicted 尚未执行时的快照
        return PullResponse(changes: const <SyncChange>[], cursor: cursor, hasMore: false);
      };

      final report = await env.engine.sync();

      expect(seenAtPull.single.status, SyncOperationStatus.conflicted);
      expect(seenAtPull.single.lastError, SyncEngineImpl.conflictMessage);
      expect(env.operations, isEmpty); // 收敛后 deleteConflicted 清除
      expect(report.pushed, 0);
      expect(report.failed, 0); // 冲突不计入 failed（§7.5）
      expect(env.engine.status.state, SyncState.idle);
    });

    test('rejected → failed 保留供排查；requeueFailed 归零重试', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));
      env.api.onPush = (ops) async => PushResponse(
            results: <PushItemResult>[
              PushItemResult(
                opId: ops.single.id,
                status: PushItemStatus.rejected,
                reason: 'ownership_mismatch',
              ),
            ],
          );

      final report = await env.engine.sync();

      expect(report.failed, 1);
      expect(env.engine.status.state, SyncState.failed);
      expect(env.engine.status.lastError, contains('ownership_mismatch'));
      final failed = env.operations.single;
      expect(failed.status, SyncOperationStatus.failed);
      expect(failed.lastError, 'ownership_mismatch');

      // 手动重试：failed → pending，清 lastError。
      await env.queue.requeueFailed();
      final requeued = env.operations.single;
      expect(requeued.status, SyncOperationStatus.pending);
      expect(requeued.lastError, isNull);
    });

    test('整批网络失败：保持 pending、retryCount++、offline、跳过拉取', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));
      env.api.onPush = (ops) async => throw SyncNetworkException('网络不可用');

      final report = await env.engine.sync();

      expect(report.failed, 1);
      expect(report.cursor, isNull);
      expect(env.api.pullCursors, isEmpty); // 离线跳过拉取
      final op = env.operations.single;
      expect(op.status, SyncOperationStatus.pending); // 保持 pending
      expect(op.retryCount, 1);
      expect(op.lastError, contains('网络不可用'));
      expect(env.engine.status.state, SyncState.offline);
      expect(env.engine.status.lastError, isNotNull);
    });

    test('5xx 整批失败：保持 pending 并以 failed 收尾（服务可达，仍尝试拉取）', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));
      env.api.onPush = (ops) async =>
          throw const SyncApiException('服务端错误', code: 'server_error', statusCode: 500);

      final report = await env.engine.sync();

      expect(report.failed, 1);
      expect(env.operations.single.status, SyncOperationStatus.pending);
      expect(env.operations.single.retryCount, 1);
      expect(env.api.pullCursors, hasLength(1)); // 5xx 未断网，拉取照常
      expect(env.engine.status.state, SyncState.failed);
    });

    test('多批推送循环：101 条 → 100 + 1，全部推送并删除', () async {
      final env = await _buildEnv();
      for (var i = 0; i < 101; i++) {
        await env.queue.enqueue(
          _op(
            id: 'op-$i',
            index: i,
            createdAt: _t0.add(Duration(minutes: i)),
          ),
        );
      }

      final report = await env.engine.sync();

      expect(env.api.pushBatches, hasLength(2));
      expect(env.api.pushBatches[0], hasLength(AppConfig.syncPushBatchSize));
      expect(env.api.pushBatches[1], hasLength(1));
      expect(report.pushed, 101);
      expect(env.operations, isEmpty);
      expect(env.engine.status.state, SyncState.idle);
    });

    test('拉取：多页游标推进 + 持久化 + lastSyncAt', () async {
      final env = await _buildEnv();
      env.api.onPull = (cursor) async {
        if (cursor == 0) {
          return PullResponse(
            changes: <SyncChange>[_change(seq: 1), _change(seq: 2)],
            cursor: 2,
            hasMore: true,
          );
        }
        return PullResponse(
          changes: <SyncChange>[_change(seq: 3)],
          cursor: 3,
          hasMore: false,
        );
      };

      final report = await env.engine.sync();

      expect(env.api.pullCursors, <int>[0, 2]);
      expect(env.entityStore.applied, hasLength(3));
      expect(report.pulled, 3);
      expect(report.cursor, 3);
      expect(await env.cursorStore.read(), 3); // 游标持久化
      expect(await env.cursorStore.readLastSyncAt(), isNotNull);
      expect(env.engine.status.state, SyncState.idle);
    });

    test('拉取：hasMore 恒真时最多 maxPullPages 页', () async {
      final env = await _buildEnv();
      env.api.onPull = (cursor) async => PullResponse(
            changes: <SyncChange>[_change(seq: cursor + 1)],
            cursor: cursor + 1,
            hasMore: true,
          );

      final report = await env.engine.sync();

      expect(env.api.pullCursors, hasLength(AppConfig.maxPullPages));
      expect(env.api.pullCursors.first, 0);
      expect(env.api.pullCursors.last, AppConfig.maxPullPages - 1);
      expect(await env.cursorStore.read(), AppConfig.maxPullPages);
      expect(report.pulled, AppConfig.maxPullPages);
    });

    test('回声抑制：本机 deviceId 的变更跳过但游标照常推进', () async {
      final env = await _buildEnv();
      env.api.onPull = (cursor) async => PullResponse(
            changes: <SyncChange>[
              _change(seq: 1, deviceId: 'device-1'), // 本机回声
            ],
            cursor: 1,
            hasMore: false,
          );

      final report = await env.engine.sync();

      expect(report.pulled, 0);
      expect(env.entityStore.applied, isEmpty);
      expect(await env.cursorStore.read(), 1);
    });

    test('退避：自动同步在窗口内跳过，手动同步忽略', () async {
      final env = await _buildEnv();
      await env.queue.enqueue(_op(id: 'op-1'));

      final first = await env.engine.sync(); // 首次无退避记录，执行
      expect(first.pushed, 1);
      final pushes = env.api.pushBatches.length;
      final pulls = env.api.pullCursors.length;

      env.clock.advance(const Duration(seconds: 10)); // < 退避基数 30s
      final skipped = await env.engine.sync(); // 自动 → 跳过
      expect(identical(skipped, first), isTrue); // 返回上次报告
      expect(env.api.pushBatches.length, pushes); // 未触网
      expect(env.api.pullCursors.length, pulls);

      await env.queue.enqueue(_op(id: 'op-2'));
      final manual = await env.engine.sync(manual: true); // 手动 → 忽略退避
      expect(manual.pushed, 1);
      expect(env.api.pushBatches.length, pushes + 1);
      expect(env.api.pullCursors.length, pulls + 1);
    });

    test('401：自动重注册一次并以新 token 重试（后续拉取亦用新 token）', () async {
      final env = await _buildEnv();
      await env.credentials.saveToken('stale-token'); // 已有失效 token
      await env.queue.enqueue(_op(id: 'op-1'));
      var attempts = 0;
      env.api.onPush = (ops) async {
        attempts += 1;
        if (attempts == 1) {
          throw const SyncApiException(
            '未授权',
            code: 'unauthorized',
            statusCode: 401,
          );
        }
        return PushResponse(
          results: <PushItemResult>[
            PushItemResult(opId: ops.single.id, status: PushItemStatus.applied),
          ],
        );
      };

      final report = await env.engine.sync();

      expect(env.api.registerCount, 1); // 仅 401 触发的一次重注册
      expect(env.api.pushTokens, <String>['stale-token', 'token-1']);
      expect(await env.credentials.readToken(), 'token-1'); // 已持久化新 token
      expect(env.api.pullTokens.single, 'token-1'); // 拉取用新 token
      expect(report.pushed, 1);
      expect(env.engine.status.state, SyncState.idle);
    });

    test('拉取中断网：已推进游标保留，状态 offline', () async {
      final env = await _buildEnv();
      env.api.onPull = (cursor) async {
        if (cursor == 0) {
          return PullResponse(
            changes: <SyncChange>[_change(seq: 1)],
            cursor: 1,
            hasMore: true,
          );
        }
        throw SyncNetworkException('拉取中断');
      };

      final report = await env.engine.sync();

      expect(report.pulled, 1);
      expect(report.cursor, 1); // 已成功页的游标
      expect(await env.cursorStore.read(), 1); // 分页推进即持久化
      expect(env.engine.status.state, SyncState.offline);
    });

    test('状态广播：syncing → idle / offline', () async {
      final env = await _buildEnv();
      final states = <SyncState>[];
      final sub = env.engine.watchStatus().listen((s) => states.add(s.state));
      addTearDown(sub.cancel);

      await env.engine.sync();
      await Future<void>.delayed(Duration.zero);
      expect(states, <SyncState>[SyncState.syncing, SyncState.idle]);

      states.clear();
      env.api.onPush = (ops) async => throw SyncNetworkException('断网');
      await env.queue.enqueue(_op(id: 'net-1'));
      await env.engine.sync(manual: true);
      await Future<void>.delayed(Duration.zero);
      expect(states, <SyncState>[SyncState.syncing, SyncState.offline]);
    });

    test('B1：非 AppException 抛出 → finally 落地 failed 终态，护栏不砖化', () async {
      final env = await _buildEnv();
      env.api.onPull = (cursor) async => PullResponse(
            changes: <SyncChange>[_change(seq: 1)],
            cursor: 1,
            hasMore: false,
          );
      // StateError 非 AppException，会穿过 sync() 的两个 catch 而不落地终态。
      env.entityStore.applyError = StateError('损坏的 payload');

      await expectLater(
        env.engine.sync(manual: true),
        throwsA(isA<StateError>()),
      );
      // 终态必须是 failed 而非 syncing，否则后续同步会被顶部防重入护栏永久短路。
      expect(env.engine.status.state, isNot(SyncState.syncing));
      expect(env.engine.status.state, SyncState.failed);

      // 故障恢复后再次同步：不被 syncing 护栏短路，能正常推进并返回报告。
      env.entityStore.applyError = null;
      final report = await env.engine.sync(manual: true);
      expect(report.pulled, 1);
      expect(env.entityStore.applied, hasLength(1));
      expect(env.engine.status.state, SyncState.idle);
    });
  });
}
