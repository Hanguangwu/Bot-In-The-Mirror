import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'core/errors/app_exception.dart';
import 'core/time/clock.dart';
import 'data/ai/openai_client.dart';
import 'data/local/ai_plan_repository_impl.dart';
import 'data/local/app_database.dart';
import 'data/local/calendar_entry_repository_impl.dart';
import 'data/local/conversation_repository_impl.dart';
import 'data/local/identity_store.dart';
import 'data/local/memory_identity_store.dart';
import 'data/local/persistent_settings_store.dart';
import 'data/local/project_repository_impl.dart';
import 'data/local/sync_operation_repository_impl.dart';
import 'data/local/task_repository_impl.dart';
import 'data/memory/memory_ai_plan_repository.dart';
import 'data/memory/memory_calendar_entry_repository.dart';
import 'data/memory/memory_conversation_repository.dart';
import 'data/memory/memory_project_repository.dart';
import 'data/memory/memory_settings_store.dart';
import 'data/memory/memory_store.dart';
import 'data/memory/memory_sync_operation_repository.dart';
import 'data/memory/memory_task_repository.dart';
import 'data/storage/memory_secret_store.dart';
import 'data/storage/secret_store.dart';
import 'data/storage/secure_storage_secret_store.dart';
import 'domain/ai/ai_client.dart';
import 'domain/entities/ai_plan.dart';
import 'domain/entities/ai_provider.dart';
import 'domain/repositories/ai_plan_repository.dart';
import 'domain/repositories/calendar_entry_repository.dart';
import 'domain/repositories/conversation_repository.dart';
import 'domain/repositories/project_repository.dart';
import 'domain/repositories/settings_store.dart';
import 'domain/repositories/sync_operation_repository.dart';
import 'domain/repositories/task_repository.dart';

/// 全局依赖容器。
final GetIt getIt = GetIt.instance;

/// 注册生产依赖：Drift 仓储 + OpenAI 客户端 + 持久化设置存储。
///
/// 启动顺序：加载匿名身份（首启生成并持久化，B1）→ 用同一 `userId`/`deviceId`
/// 构造全部仓储 → `await settingsStore.load()` 加载持久化配置 →
/// `ensureDefaultConversation()` 保证存在默认会话（幂等）。除此之外不做其他启动工作。
Future<void> configureDependencies() async {
  // F9：以真正的数据库单例为幂等标志，避免依赖「先注册 MemorySettingsStore」
  // 这一偶然顺序；测试重置后该标志随 registerAppDatabase 一起消失，语义正确。
  if (getIt.isRegistered<AppDatabase>()) {
    return;
  }

  // 单例数据库：全部 Drift 仓储必须共享它，否则 Drift 的嵌套事务无法复用外层，
  // confirm/markExpired 的原子性不成立（§7）。
  final database = AppDatabase.open();
  getIt.registerSingleton<AppDatabase>(database, dispose: (db) => db.close());

  // 平台安全存储。构造本身不读平台通道；平台访问只发生在 load / saveApiKey。
  getIt.registerLazySingleton<SecretStore>(() => SecureStorageSecretStore());

  // 稳定匿名身份：首启生成并持久化，之后恒定；注入全部仓储（B1/§5.4）。
  final identity = PersistentIdentityStore();
  await identity.load();
  getIt.registerSingleton<IdentityStore>(identity);
  final userId = identity.userId;
  final deviceId = identity.deviceId;

  const clock = SystemClock();

  // 同步队列：单例，注入全部写路径仓储（会话/任务/计划/日历/项目），
  // 使「实体写入 + 入队」复用同一事务（§7.1）。
  final syncOperationRepository = SyncOperationRepositoryImpl(
    database,
    clock,
    userId: userId,
    deviceId: deviceId,
  );
  getIt.registerSingleton<SyncOperationRepository>(syncOperationRepository);

  getIt.registerLazySingleton<ConversationRepository>(
    () => ConversationRepositoryImpl(
      getIt<AppDatabase>(),
      clock,
      syncOperationRepository: syncOperationRepository,
      userId: userId,
      deviceId: deviceId,
    ),
  );

  final taskRepository = TaskRepositoryImpl(
    database,
    clock,
    syncOperationRepository: syncOperationRepository,
    userId: userId,
    deviceId: deviceId,
  );
  getIt.registerSingleton<TaskRepository>(taskRepository);

  getIt.registerLazySingleton<CalendarEntryRepository>(
    () => CalendarEntryRepositoryImpl(
      getIt<AppDatabase>(),
      clock,
      syncOperationRepository: syncOperationRepository,
      userId: userId,
      deviceId: deviceId,
    ),
  );

  getIt.registerLazySingleton<AIPlanRepository>(
    () => AIPlanRepositoryImpl(
      getIt<AppDatabase>(),
      getIt<TaskRepository>(),
      clock,
      syncOperationRepository: syncOperationRepository,
      calendarEntryRepository: getIt<CalendarEntryRepository>(),
      userId: userId,
      deviceId: deviceId,
    ),
  );

  getIt.registerLazySingleton<ProjectRepository>(
    () => ProjectRepositoryImpl(
      getIt<AppDatabase>(),
      clock,
      syncOperationRepository: syncOperationRepository,
      userId: userId,
      deviceId: deviceId,
    ),
  );

  final settingsStore = PersistentSettingsStore(
    secretStore: getIt<SecretStore>(),
  );
  getIt.registerSingleton<SettingsStore>(settingsStore);

  // F8：API Key 通过 SettingsStore 接口读取，不再依赖具体实现类型。
  getIt.registerLazySingleton<AIClient>(
    () => OpenAIClient(apiKeyProvider: () => getIt<SettingsStore>().apiKey),
  );

  // 启动时加载持久化配置进内存缓存，再保证默认会话存在（幂等）。
  await settingsStore.load();
  await getIt<ConversationRepository>().ensureDefaultConversation();
}

/// 测试用：重置容器并注册全内存、无网络的实现。
///
/// 说明：get_it 9 的 `reset()` 为异步，必须先 await 再注册，否则注册会被
/// 随后的异步清理抹掉。因此本函数返回 `Future<void>`（相对契约的 `void`
/// 小幅偏离，仅为正确性）。
///
/// **测试不得调用生产 `configureDependencies()`**：它会触发
/// `FlutterSecureStorage.read → MissingPluginException`（无真实平台通道）。
@visibleForTesting
Future<void> resetDependenciesForTest({
  AIClient? aiClient,
  ConversationRepository? conversationRepository,
  MemoryTaskRepository? taskRepository,
  MemoryAIPlanRepository? aiPlanRepository,
  MemorySettingsStore? settingsStore,
  MemorySyncOperationRepository? syncOperationRepository,
  MemoryCalendarEntryRepository? calendarEntryRepository,
  MemoryProjectRepository? projectRepository,
}) async {
  await getIt.reset();

  final secrets = MemorySecretStore();
  getIt.registerSingleton<MemorySecretStore>(secrets);
  getIt.registerSingleton<SecretStore>(secrets);

  final settings = settingsStore ?? MemorySettingsStore();
  getIt.registerSingleton<MemorySettingsStore>(settings);
  getIt.registerSingleton<SettingsStore>(settings);

  getIt.registerSingleton<AIClient>(aiClient ?? const _StubAIClient());

  // 固定身份，替代生产持久化身份；全部内存仓储共享同一 userId/deviceId（B1）。
  final identity = MemoryIdentityStore();
  await identity.load();
  getIt.registerSingleton<MemoryIdentityStore>(identity);
  getIt.registerSingleton<IdentityStore>(identity);

  const clock = SystemClock();

  // 全或无接缝：会话/任务/计划/日历/项目内存仓储 + 同步队列注册到同一
  // MemoryStore，使跨仓储写（含 confirm/markExpired）可回滚（§7.2）。
  final memoryStore = MemoryStore();

  final syncOps = syncOperationRepository ??
      MemorySyncOperationRepository(
        clock: clock,
        userId: identity.userId,
        deviceId: identity.deviceId,
        store: memoryStore,
      );
  getIt.registerSingleton<MemorySyncOperationRepository>(syncOps);
  getIt.registerSingleton<SyncOperationRepository>(syncOps);

  final conversation = conversationRepository ??
      MemoryConversationRepository(
        syncOperationRepository: syncOps,
        userId: identity.userId,
        deviceId: identity.deviceId,
        store: memoryStore,
      );
  // 预置默认会话，替代 HomeScreen 的 initState 引导（S12）。
  await conversation.ensureDefaultConversation();
  getIt.registerSingleton<ConversationRepository>(conversation);

  // 同一 MemoryTaskRepository 实例注入 MemoryAIPlanRepository，
  // 保证内存 confirm 的全或无语义（S2/S9）。
  final tasks = taskRepository ??
      MemoryTaskRepository(
        syncOperationRepository: syncOps,
        userId: identity.userId,
        deviceId: identity.deviceId,
        store: memoryStore,
      );
  getIt.registerSingleton<MemoryTaskRepository>(tasks);
  getIt.registerSingleton<TaskRepository>(tasks);

  // 先装配日历仓储，再把同一实例注入 MemoryAIPlanRepository，
  // 使 confirm 物化日程与计划/任务/队列共享同一原子接缝（§7.2/§10）。
  final calendar = calendarEntryRepository ??
      MemoryCalendarEntryRepository(
        syncOperationRepository: syncOps,
        clock: clock,
        userId: identity.userId,
        deviceId: identity.deviceId,
        store: memoryStore,
      );
  getIt.registerSingleton<MemoryCalendarEntryRepository>(calendar);
  getIt.registerSingleton<CalendarEntryRepository>(calendar);

  getIt.registerSingleton<AIPlanRepository>(
    aiPlanRepository ??
        MemoryAIPlanRepository(
          tasks,
          syncOperationRepository: syncOps,
          calendarEntryRepository: calendar,
          memoryStore: memoryStore,
          userId: identity.userId,
          deviceId: identity.deviceId,
        ),
  );

  final projects = projectRepository ??
      MemoryProjectRepository(
        syncOperationRepository: syncOps,
        clock: clock,
        userId: identity.userId,
        deviceId: identity.deviceId,
        store: memoryStore,
      );
  getIt.registerSingleton<MemoryProjectRepository>(projects);
  getIt.registerSingleton<ProjectRepository>(projects);
}

/// 测试用假客户端：绝不触网。
class _StubAIClient implements AIClient {
  const _StubAIClient();

  @override
  Future<AIResult> complete(AIRequest request) async =>
      AIResult(content: '（测试回复）你好', model: request.profile.model);

  @override
  Future<AIResult> testConnection(AIProviderProfile profile) async =>
      AIResult(content: 'pong', model: profile.model);

  @override
  Future<AIPlan> proposePlan(PlanRequest request) async =>
      throw const UnsupportedException('任务拆解将在下一阶段（M1）提供');
}
