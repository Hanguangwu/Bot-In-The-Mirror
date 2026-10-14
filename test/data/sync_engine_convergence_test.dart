import 'package:chatwithalice/core/config/app_config.dart';
import 'package:chatwithalice/core/errors/app_exception.dart';
import 'package:chatwithalice/core/time/clock.dart';
import 'package:chatwithalice/data/local/memory_identity_store.dart';
import 'package:chatwithalice/data/memory/memory_ai_plan_repository.dart';
import 'package:chatwithalice/data/memory/memory_calendar_entry_repository.dart';
import 'package:chatwithalice/data/memory/memory_conversation_repository.dart';
import 'package:chatwithalice/data/memory/memory_project_repository.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_cursor_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_credential_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_entity_store.dart';
import 'package:chatwithalice/data/memory/memory_sync_operation_repository.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/data/sync/sync_engine_impl.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:chatwithalice/domain/sync/lww.dart';
import 'package:chatwithalice/domain/sync/sync_api.dart';
import 'package:chatwithalice/domain/sync/sync_change.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控时钟（构造确定性的时间顺序，LWW 同版本比 updatedAt）。
class _MutableClock implements Clock {
  _MutableClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;
}

final DateTime _t0 = DateTime.utc(2026, 3, 1, 10);
final DateTime _t1 = DateTime.utc(2026, 3, 1, 10, 30);
final DateTime _t2 = DateTime.utc(2026, 3, 1, 11);

/// token → 身份（§5.1；身份只来自 token）。
class _TokenIdentity {
  const _TokenIdentity({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;
}

/// `entities` 表快照行。
class _EntityRow {
  const _EntityRow({
    required this.version,
    required this.updatedAt,
    required this.deviceId,
    required this.deletedAt,
    required this.payload,
  });

  final int version;
  final DateTime updatedAt;
  final String deviceId;
  final DateTime? deletedAt;
  final Map<String, Object?> payload;
}

/// `change_log` 行。
class _LogRow {
  const _LogRow({
    required this.seq,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.version,
    required this.deviceId,
    required this.opId,
    required this.updatedAt,
    required this.payload,
  });

  final int seq;
  final String entityType;
  final String entityId;
  final SyncOperationKind kind;
  final int version;
  final String deviceId;
  final String opId;
  final DateTime updatedAt;
  final Map<String, Object?> payload;
}

/// 假 Worker：内存 `entities` + `change_log`，实现 §5 契约子集——
/// token 鉴权、幂等（`op_id`）、LWW（复用 `acceptVersion`，payload 权威）、
/// `device_id` 取自 token、pull 全量扫描 + 设备过滤 + 游标 = 扫描最大 seq（B2）。
class _FakeWorker {
  final Map<String, _TokenIdentity> _tokens = <String, _TokenIdentity>{};
  final Map<String, _EntityRow> _entities = <String, _EntityRow>{};
  final List<_LogRow> _changeLog = <_LogRow>[];
  int _tokenSeq = 0;
  int _seq = 0;

  /// 服务端实体数量（断言「不产生重复实体」用）。
  int get entityCount => _entities.length;

  /// 读服务端当前实体快照。
  _EntityRow? entity(String entityType, String entityId) =>
      _entities['$entityType:$entityId'];

  /// POST /v1/auth/anonymous（§5.1，幂等换发 token）。
  AnonymousSession register({required String userId, required String deviceId}) {
    final token = 'tok-${++_tokenSeq}';
    _tokens[token] = _TokenIdentity(userId: userId, deviceId: deviceId);
    return AnonymousSession(
      token: token,
      userId: userId,
      workspaceId: 'ws-1',
      deviceId: deviceId,
    );
  }

  /// POST /v1/sync/push（§5.2 子集）。
  PushResponse push({
    required String token,
    required List<SyncOperation> operations,
  }) {
    final identity = _tokens[token]!;
    final results = <PushItemResult>[];
    for (final op in operations) {
      // 幂等（§7.2）：同 opId 重放直接 applied，不重复写。
      if (_changeLog.any((row) => row.opId == op.id)) {
        results.add(PushItemResult(opId: op.id, status: PushItemStatus.applied));
        continue;
      }
      final payload = op.payload;
      final version = payload['version'];
      final updatedAtRaw = payload['updatedAt'];
      if (payload['id'] != op.entityId ||
          version is! int ||
          updatedAtRaw is! String) {
        results.add(PushItemResult(
          opId: op.id,
          status: PushItemStatus.rejected,
          reason: 'invalid_payload',
        ));
        continue;
      }
      // 所有权校验（§5.2/基线 §10）。
      if (payload['userId'] != identity.userId) {
        results.add(PushItemResult(
          opId: op.id,
          status: PushItemStatus.rejected,
          reason: 'ownership_mismatch',
        ));
        continue;
      }
      final updatedAt = DateTime.parse(updatedAtRaw);
      final deletedAtRaw = payload['deletedAt'];
      final key = '${op.entityType}:${op.entityId}';
      final stored = _entities[key];
      // LWW（§7.1）：payload 权威，version 优先、其次 updatedAt。
      final accepted = acceptVersion(
        incomingVersion: version,
        incomingUpdatedAt: updatedAt,
        storedVersion: stored?.version,
        storedUpdatedAt: stored?.updatedAt,
      );
      if (!accepted) {
        results.add(PushItemResult(
          opId: op.id,
          status: PushItemStatus.conflict,
          reason: 'stale_version',
          serverVersion: stored?.version,
          serverUpdatedAt: stored?.updatedAt,
        ));
        continue; // 冲突不写 change_log（服务端未变）
      }
      _entities[key] = _EntityRow(
        version: version,
        updatedAt: updatedAt,
        deviceId: identity.deviceId, // §4/B1：取自 token
        deletedAt: deletedAtRaw is String ? DateTime.parse(deletedAtRaw) : null,
        payload: payload,
      );
      final seq = ++_seq;
      _changeLog.add(_LogRow(
        seq: seq,
        entityType: op.entityType,
        entityId: op.entityId,
        kind: op.kind,
        version: version,
        deviceId: identity.deviceId, // 取自 token
        opId: op.id,
        updatedAt: updatedAt,
        payload: payload,
      ));
      results.add(PushItemResult(opId: op.id, status: PushItemStatus.applied));
    }
    return PushResponse(results: results);
  }

  /// GET /v1/sync/pull（§5.3/B2）：全量扫描 seq > cursor，设备过滤在组装阶段，
  /// 游标 = 本次扫描行的最大 seq（不得用 MAX(seq)）。
  PullResponse pull({
    required String token,
    required int cursor,
    int limit = AppConfig.syncPullLimit,
  }) {
    final identity = _tokens[token]!;
    final scanned = _changeLog
        .where((row) => row.seq > cursor)
        .take(limit)
        .toList(growable: false);
    final changes = <SyncChange>[];
    for (final row in scanned) {
      if (row.deviceId == identity.deviceId) {
        continue; // 回声过滤（§7.3）
      }
      changes.add(SyncChange(
        seq: row.seq,
        entityType: row.entityType,
        entityId: row.entityId,
        kind: row.kind,
        version: row.version,
        deviceId: row.deviceId,
        updatedAt: row.updatedAt,
        payload: row.payload,
      ));
    }
    final newCursor = scanned.isEmpty ? cursor : scanned.last.seq;
    return PullResponse(
      changes: changes,
      cursor: newCursor,
      hasMore: scanned.length == limit,
    );
  }
}

/// 假 Worker 的 RemoteSyncApi 适配层（引擎不感知假实现；仍不触网）。
class _WorkerApi implements RemoteSyncApi {
  _WorkerApi(this._worker);

  final _FakeWorker _worker;

  /// 模拟拉取阶段断网（冲突保留用例）。
  bool failPull = false;

  @override
  Future<AnonymousSession> register({
    required String userId,
    required String deviceId,
  }) async =>
      _worker.register(userId: userId, deviceId: deviceId);

  @override
  Future<PushResponse> push({
    required String token,
    required List<SyncOperation> operations,
  }) async =>
      _worker.push(token: token, operations: operations);

  @override
  Future<PullResponse> pull({
    required String token,
    required int cursor,
    int limit = AppConfig.syncPullLimit,
  }) async {
    if (failPull) {
      throw const SyncNetworkException('模拟断网');
    }
    return _worker.pull(token: token, cursor: cursor, limit: limit);
  }
}

/// 一台「设备」：完整内存环境（队列 + 六实体仓储 + 引擎），共享同一假 Worker。
class _Device {
  _Device({
    required _FakeWorker worker,
    required String deviceId,
    _MutableClock? taskClock,
  })  : userId = 'user-1',
        deviceId = deviceId,
        taskClock = taskClock {
    api = _WorkerApi(worker);
    queue = MemorySyncOperationRepository(userId: userId, deviceId: deviceId);
    conversations = MemoryConversationRepository(
      syncOperationRepository: queue,
      userId: userId,
      deviceId: deviceId,
    );
    tasks = MemoryTaskRepository(
      syncOperationRepository: queue,
      userId: userId,
      deviceId: deviceId,
      clock: taskClock,
    );
    calendarEntries = MemoryCalendarEntryRepository(
      syncOperationRepository: queue,
      userId: userId,
      deviceId: deviceId,
    );
    projects = MemoryProjectRepository(
      syncOperationRepository: queue,
      userId: userId,
      deviceId: deviceId,
    );
    plans = MemoryAIPlanRepository(
      tasks,
      syncOperationRepository: queue,
      calendarEntryRepository: calendarEntries,
      userId: userId,
      deviceId: deviceId,
    );
    entityStore = MemorySyncEntityStore(
      conversations: conversations,
      tasks: tasks,
      plans: plans,
      calendarEntries: calendarEntries,
      projects: projects,
    );
    credentials = MemorySyncCredentialStore();
    cursorStore = MemorySyncCursorStore();
    settings = MemorySettingsStore();
    engine = SyncEngineImpl(
      api: api,
      operations: queue,
      settings: settings,
      credentials: credentials,
      cursorStore: cursorStore,
      entityStore: entityStore,
      identity: MemoryIdentityStore(userId: userId, deviceId: deviceId),
    );
  }

  final String userId;
  final String deviceId;
  final _MutableClock? taskClock;
  late final _WorkerApi api;
  late final MemorySyncOperationRepository queue;
  late final MemoryConversationRepository conversations;
  late final MemoryTaskRepository tasks;
  late final MemoryCalendarEntryRepository calendarEntries;
  late final MemoryProjectRepository projects;
  late final MemoryAIPlanRepository plans;
  late final MemorySyncEntityStore entityStore;
  late final MemorySyncCredentialStore credentials;
  late final MemorySyncCursorStore cursorStore;
  late final MemorySettingsStore settings;
  late final SyncEngineImpl engine;

  /// 配置同步基址（否则引擎空转）。
  Future<void> init() => settings.saveSyncBaseUrl('https://fake.worker.test');

  /// 本机可见任务（不含墓碑）。
  Future<List<Task>> tasksList() => tasks.getTasks(const TaskQuery());

  /// 队列当前全部操作快照。
  List<SyncOperation> get operations =>
      List<SyncOperation>.of(queue.snapshot()! as List<SyncOperation>);
}

/// 构造一台设备（同步创建 + 异步配置基址）。
Future<_Device> _device({
  required _FakeWorker worker,
  required String deviceId,
  _MutableClock? taskClock,
}) async {
  final device = _Device(worker: worker, deviceId: deviceId, taskClock: taskClock);
  await device.init();
  return device;
}

Task _task({required String title}) => Task(
      id: 't1',
      userId: '',
      createdAt: _t0,
      updatedAt: _t0,
      version: 1,
      deviceId: '',
      title: title,
    );

void main() {
  group('SyncEngine 收敛（双设备 + 假 Worker，A7）', () {
    test('交替推送/拉取后最终一致；重复同步不产生重复实体', () async {
      final worker = _FakeWorker();
      final a = await _device(worker: worker, deviceId: 'device-a');
      final b = await _device(worker: worker, deviceId: 'device-b');

      // A 新建任务并推送。
      await a.tasks.save(_task(title: '买牛奶'));
      final ra1 = await a.engine.sync(manual: true);
      expect(ra1.pushed, 1);
      expect(ra1.pulled, 0); // 本机回声被过滤
      expect(worker.entityCount, 1);

      // B 拉取落地。
      final rb1 = await b.engine.sync(manual: true);
      expect(rb1.pushed, 0);
      expect(rb1.pulled, 1);
      final bTasks1 = await b.tasksList();
      expect(bTasks1, hasLength(1));
      expect(bTasks1.single.title, '买牛奶');
      expect(bTasks1.single.version, 1);

      // B 更新并推送（回声：拉不到自己的变更）。
      await b.tasks.save(bTasks1.single.copyWith(title: '买牛奶（B改）'));
      final rb2 = await b.engine.sync(manual: true);
      expect(rb2.pushed, 1);
      expect(rb2.pulled, 0);
      expect(worker.entity('task', 't1')!.payload['title'], '买牛奶（B改）');

      // A 拉取收敛。
      final ra2 = await a.engine.sync(manual: true);
      expect(ra2.pushed, 0);
      expect(ra2.pulled, 1);
      final aTasks = await a.tasksList();
      final bTasks2 = await b.tasksList();
      expect(aTasks.single.title, '买牛奶（B改）');
      expect(aTasks.single.version, bTasks2.single.version);
      expect(aTasks.single.updatedAt.toUtc(), bTasks2.single.updatedAt.toUtc());

      // 双端队列清空。
      expect(a.operations, isEmpty);
      expect(b.operations, isEmpty);

      // 重复同步：幂等，无新推送/拉取，不产生重复实体。
      final ra3 = await a.engine.sync(manual: true);
      final rb3 = await b.engine.sync(manual: true);
      expect(ra3.pushed + ra3.pulled, 0);
      expect(rb3.pushed + rb3.pulled, 0);
      expect(await a.tasksList(), hasLength(1));
      expect(await b.tasksList(), hasLength(1));
      expect(worker.entityCount, 1);
      expect(a.engine.status.state, SyncState.idle);
      expect(b.engine.status.state, SyncState.idle);
    });

    test('并发编辑：LWW 冲突自动收敛，队列清理', () async {
      final worker = _FakeWorker();
      final a = await _device(
        worker: worker,
        deviceId: 'device-a',
        taskClock: _MutableClock(_t0),
      );
      final b = await _device(
        worker: worker,
        deviceId: 'device-b',
        taskClock: _MutableClock(_t0),
      );

      // 基线：A 建立 v1，B 拉取。
      await a.tasks.save(_task(title: '初稿'));
      await a.engine.sync(manual: true);
      await b.engine.sync(manual: true);
      expect((await b.tasksList()).single.title, '初稿');

      // B 于 T1 编辑（v2/T1），A 于 T2 编辑（v2/T2）。
      b.taskClock!.current = _t1;
      await b.tasks.save((await b.tasksList()).single.copyWith(title: 'B 版'));
      a.taskClock!.current = _t2;
      await a.tasks.save((await a.tasksList()).single.copyWith(title: 'A 版'));

      // A 先推送成功；B 后推送 → 同版本、updatedAt 更早 → conflict。
      final ra = await a.engine.sync(manual: true);
      expect(ra.pushed, 1);
      final rb = await b.engine.sync(manual: true);
      expect(rb.pushed, 0); // B 的写被 LWW 拒绝
      expect(rb.pulled, 1); // 同次同步内拉取收敛（A9）
      // 服务端保持 A 的版本。
      expect(worker.entity('task', 't1')!.payload['title'], 'A 版');
      // B 本地收敛到 A 版。
      final bTask = (await b.tasksList()).single;
      expect(bTask.title, 'A 版');
      expect(bTask.version, 2);
      // conflicted 操作已被 deleteConflicted 清理。
      expect(b.operations, isEmpty);

      // A 不变，双端最终一致。
      await a.engine.sync(manual: true);
      final aTask = (await a.tasksList()).single;
      expect(aTask.title, 'A 版');
      expect(aTask.updatedAt.toUtc(), bTask.updatedAt.toUtc());
      expect(worker.entityCount, 1);
    });

    test('冲突 + 拉取断网：conflicted 保留待收敛，恢复后清理', () async {
      final worker = _FakeWorker();
      final a = await _device(
        worker: worker,
        deviceId: 'device-a',
        taskClock: _MutableClock(_t0),
      );
      final b = await _device(
        worker: worker,
        deviceId: 'device-b',
        taskClock: _MutableClock(_t0),
      );
      await a.tasks.save(_task(title: '初稿'));
      await a.engine.sync(manual: true);
      await b.engine.sync(manual: true);
      b.taskClock!.current = _t1;
      await b.tasks.save((await b.tasksList()).single.copyWith(title: 'B 版'));
      a.taskClock!.current = _t2;
      await a.tasks.save((await a.tasksList()).single.copyWith(title: 'A 版'));
      await a.engine.sync(manual: true);

      // B 推送冲突，随后拉取断网 → conflicted 保留（deleteConflicted 未执行）。
      b.api.failPull = true;
      final rb1 = await b.engine.sync(manual: true);
      expect(rb1.pushed, 0);
      expect(b.engine.status.state, SyncState.offline);
      final conflicted = b.operations.single;
      expect(conflicted.status, SyncOperationStatus.conflicted);
      expect(conflicted.lastError, SyncEngineImpl.conflictMessage);

      // 网络恢复 → 拉取收敛 + 队列清理。
      b.api.failPull = false;
      final rb2 = await b.engine.sync(manual: true);
      expect(rb2.pulled, 1);
      expect(b.operations, isEmpty);
      expect((await b.tasksList()).single.title, 'A 版');
      expect(b.engine.status.state, SyncState.idle);
    });

    test('删除传播：墓碑经同步生效且不复活', () async {
      final worker = _FakeWorker();
      final a = await _device(worker: worker, deviceId: 'device-a');
      final b = await _device(worker: worker, deviceId: 'device-b');

      await a.tasks.save(_task(title: '待删任务'));
      await a.engine.sync(manual: true);
      await b.engine.sync(manual: true);
      expect(await b.tasksList(), hasLength(1));

      // A 删除 → 墓碑（v2）→ 推送。
      await a.tasks.applyChanges(<TaskChange>[const TaskDeleted('t1')]);
      final ra = await a.engine.sync(manual: true);
      expect(ra.pushed, 1);
      expect(worker.entity('task', 't1')!.deletedAt, isNotNull);

      // B 拉取墓碑 → 本地不可见。
      final rb = await b.engine.sync(manual: true);
      expect(rb.pulled, 1);
      expect(await b.tasksList(), isEmpty);

      // 重复同步：不复活、不产生重复实体。
      final rb2 = await b.engine.sync(manual: true);
      expect(rb2.pushed + rb2.pulled, 0);
      expect(await b.tasksList(), isEmpty);
      expect(worker.entityCount, 1);
      expect(a.operations, isEmpty);
      expect(b.operations, isEmpty);
    });
  });
}
