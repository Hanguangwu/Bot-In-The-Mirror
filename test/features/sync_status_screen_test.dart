import 'dart:async';

import 'package:chatwithalice/data/local/memory_identity_store.dart';
import 'package:chatwithalice/data/memory/memory_settings_store.dart';
import 'package:chatwithalice/di.dart';
import 'package:chatwithalice/domain/entities/sync.dart';
import 'package:chatwithalice/domain/repositories/sync_operation_repository.dart';
import 'package:chatwithalice/domain/sync/sync_credential_store.dart';
import 'package:chatwithalice/domain/sync/sync_engine.dart';
import 'package:chatwithalice/domain/sync/sync_status.dart';
import 'package:chatwithalice/features/settings/settings_screen.dart';
import 'package:chatwithalice/features/sync/sync_status_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假同步引擎：状态流可控，`sync()` 记录调用并返回预设报告（或抛预设异常）。
class _FakeSyncEngine implements SyncEngine {
  _FakeSyncEngine({SyncStatus? initial, this.report, this.error})
      : _status = initial ?? const SyncStatus(state: SyncState.idle);

  final StreamController<SyncStatus> _controller =
      StreamController<SyncStatus>.broadcast();

  SyncStatus _status;

  /// `sync()` 返回的报告；为空时返回全零报告。
  final SyncReport? report;

  /// `sync()` 抛出的异常；非空时优先于 [report]。
  final Object? error;

  /// `sync()` 被调用次数。
  int syncCalls = 0;

  /// 最近一次 `sync()` 的 manual 参数。
  bool? lastManual;

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> watchStatus() => _controller.stream;

  @override
  Future<SyncReport> sync({bool manual = false}) async {
    syncCalls++;
    lastManual = manual;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    final result = report ??
        SyncReport(
          pushed: 0,
          pulled: 0,
          failed: 0,
          at: DateTime(2024, 5, 1),
        );
    _status = SyncStatus(
      state: SyncState.idle,
      lastReport: result,
      lastSyncAt: result.at,
    );
    _controller.add(_status);
    return result;
  }

  /// 向订阅者推送一个状态（不改变已返回的报告）。
  void emit(SyncStatus status) {
    _status = status;
    _controller.add(status);
  }

  void dispose() => _controller.close();
}

/// 假同步队列：仅维护 pending 列表并统计 `requeueFailed` 调用。
class _FakeQueue implements SyncOperationRepository {
  _FakeQueue({List<SyncOperation>? initial})
      : _operations = List<SyncOperation>.of(initial ?? const <SyncOperation>[]);

  final StreamController<List<SyncOperation>> _controller =
      StreamController<List<SyncOperation>>.broadcast();

  final List<SyncOperation> _operations;

  /// `requeueFailed()` 调用次数。
  int requeueCalls = 0;

  @override
  Future<List<SyncOperation>> getPending() async => _pending();

  @override
  Stream<List<SyncOperation>> watchPending() => _controller.stream;

  @override
  Future<void> enqueue(SyncOperation operation) async {
    _operations.add(operation);
    _controller.add(_pending());
  }

  @override
  Future<void> enqueueAll(List<SyncOperation> operations) async {
    _operations.addAll(operations);
    _controller.add(_pending());
  }

  @override
  Future<void> mark(SyncOperation operation) async {}

  @override
  Future<void> deleteSynced() async {}

  @override
  Future<void> deleteConflicted() async {}

  @override
  Future<void> requeueFailed() async {
    requeueCalls++;
  }

  List<SyncOperation> _pending() => _operations
      .where((operation) => operation.status == SyncOperationStatus.pending)
      .toList(growable: false);

  void dispose() => _controller.close();
}

/// 假凭证存储：内存持有 token / workspaceId。
class _FakeCredentialStore implements SyncCredentialStore {
  _FakeCredentialStore({this.token, this.workspaceId});

  String? token;
  String? workspaceId;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> saveToken(String token) async => this.token = token;

  @override
  Future<String?> readWorkspaceId() async => workspaceId;

  @override
  Future<void> saveWorkspaceId(String workspaceId) async =>
      this.workspaceId = workspaceId;

  @override
  Future<void> clear() async {
    token = null;
    workspaceId = null;
  }
}

/// 构造一个待同步操作（仅 test 用）。
SyncOperation _pendingOperation(String id) => SyncOperation(
      id: id,
      userId: 'user-1',
      createdAt: DateTime(2024, 5, 1, 8, 0),
      updatedAt: DateTime(2024, 5, 1, 8, 0),
      version: 1,
      deviceId: 'device-1',
      entityType: 'task',
      entityId: 'task-$id',
      kind: SyncOperationKind.create,
    );

/// 组装被测页面（注入全部假依赖，绝不触网、不读平台存储）。
Widget _buildScreen({
  required SyncEngine engine,
  required SyncOperationRepository queue,
  required MemorySettingsStore settings,
  required _FakeCredentialStore credentials,
  MemoryIdentityStore? identity,
}) {
  return MaterialApp(
    home: SyncStatusScreen(
      engine: engine,
      queue: queue,
      settings: settings,
      credentials: credentials,
      identity: identity ?? MemoryIdentityStore(),
    ),
  );
}

void main() {
  late _FakeSyncEngine engine;
  late _FakeQueue queue;
  late MemorySettingsStore settings;
  late _FakeCredentialStore credentials;

  setUp(() {
    engine = _FakeSyncEngine();
    queue = _FakeQueue();
    settings = MemorySettingsStore();
    credentials = _FakeCredentialStore();
  });

  tearDown(() {
    engine.dispose();
    queue.dispose();
    settings.dispose();
  });

  testWidgets('未配置服务地址：提示文案 + 闲置状态 + 立即同步禁用', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('同步状态'), findsOneWidget);
    expect(find.text('填写同步服务地址后可用'), findsOneWidget);
    expect(find.text('闲置'), findsOneWidget);
    expect(find.text('尚未同步'), findsOneWidget);
    expect(find.text('待同步 0 条'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('立即同步'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('待同步条数来自 watchPending', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('待同步 0 条'), findsOneWidget);

    await queue.enqueue(_pendingOperation('a'));
    await queue.enqueue(_pendingOperation('b'));
    await tester.pumpAndSettle();
    expect(find.text('待同步 2 条'), findsOneWidget);
  });

  testWidgets('已配置时点击立即同步：调用 sync(manual: true) 并展示上次同步时间', (tester) async {
    engine = _FakeSyncEngine(
      report: SyncReport(
        pushed: 2,
        pulled: 1,
        failed: 0,
        at: DateTime(2024, 5, 1, 9, 30),
      ),
    );
    await settings.saveSyncBaseUrl('https://sync.example.com/');

    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('填写同步服务地址后可用'), findsNothing);

    await tester.tap(find.text('立即同步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.syncCalls, 1);
    expect(engine.lastManual, isTrue);
    expect(find.text('2024-05-01 09:30'), findsOneWidget);
    expect(find.textContaining('同步完成'), findsOneWidget);
  });

  testWidgets('同步失败时给出明确文案且不崩溃', (tester) async {
    engine = _FakeSyncEngine(error: StateError('boom'));
    await settings.saveSyncBaseUrl('https://sync.example.com');

    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即同步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('同步失败，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态文案随状态流变化（离线/失败/同步中）', (tester) async {
    // 状态经广播流异步送达：单次 pump 只 flush 微任务（事件送达发生在「是否建帧」
    // 判定之后），故第一次 pump 送达事件触发 setState，第二次 pump 渲染新帧。
    Future<void> pumpStatus() async {
      await tester.pump();
      await tester.pump();
    }

    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    engine.emit(const SyncStatus(state: SyncState.offline));
    await pumpStatus();
    expect(find.text('离线'), findsOneWidget);
    expect(find.text('闲置'), findsNothing);

    engine.emit(const SyncStatus(state: SyncState.failed));
    await pumpStatus();
    expect(find.text('失败'), findsOneWidget);

    engine.emit(const SyncStatus(state: SyncState.syncing));
    await pumpStatus();
    // 同步中禁用按钮并展示进度指示；用 pump 而非 pumpAndSettle（无限动画）。
    expect(find.text('同步中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('同步中…'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('失败/冲突摘要：展示失败计数与最近错误，并可重试失败项', (tester) async {
    engine = _FakeSyncEngine(
      initial: SyncStatus(
        state: SyncState.failed,
        lastReport: SyncReport(
          pushed: 0,
          pulled: 0,
          failed: 2,
          at: DateTime(2024, 5, 1, 10, 0),
        ),
        lastError: '版本落后，服务端已更新',
        lastSyncAt: DateTime(2024, 5, 1, 10, 0),
      ),
    );

    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('失败与冲突摘要'), findsOneWidget);
    expect(find.text('失败条数'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('版本落后，服务端已更新'), findsOneWidget);

    await tester.tap(find.text('重试失败项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(queue.requeueCalls, 1);
    expect(find.textContaining('重新排队'), findsOneWidget);
  });

  testWidgets('身份区脱敏显示且不泄露明文 token', (tester) async {
    credentials = _FakeCredentialStore(
      token: 'secret-token-must-not-appear',
      workspaceId: 'workspace-abcdef123456',
    );
    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
        identity: MemoryIdentityStore(userId: 'user-1234567890abcdef'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('user…cdef'), findsOneWidget);
    expect(find.text('work…3456'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.textContaining('secret-token-must-not-appear'), findsNothing);
  });

  testWidgets('无 token 时显示未连接，工作区未设置', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未连接'), findsOneWidget);
    // 工作区 ID 未设置；用户 ID 与非空默认身份一致（非明文全量）。
    expect(find.text('未设置'), findsOneWidget);
  });

  testWidgets('保存服务地址时去掉尾部斜杠', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        engine: engine,
        queue: queue,
        settings: settings,
        credentials: credentials,
      ),
    );
    await tester.pumpAndSettle();

    // 配置卡片在 800x600 测试视口下方，先滚动到可见区域再交互。
    final field = find.byType(TextField);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'https://sync.example.com///');
    final saveButton = find.text('保存');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(settings.syncBaseUrl, 'https://sync.example.com');
    expect(find.text('同步服务地址已保存'), findsOneWidget);
    // 保存后即视为已配置，提示消失。
    expect(find.text('填写同步服务地址后可用'), findsNothing);
  });

  testWidgets('设置页新增同步入口', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '同步'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
  });
}
