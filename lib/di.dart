import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'core/errors/app_exception.dart';
import 'core/time/clock.dart';
import 'data/ai/openai_client.dart';
import 'data/local/ai_plan_repository_impl.dart';
import 'data/local/app_database.dart';
import 'data/local/conversation_repository_impl.dart';
import 'data/local/persistent_settings_store.dart';
import 'data/local/task_repository_impl.dart';
import 'data/memory/memory_ai_plan_repository.dart';
import 'data/memory/memory_conversation_repository.dart';
import 'data/memory/memory_settings_store.dart';
import 'data/memory/memory_task_repository.dart';
import 'data/storage/memory_secret_store.dart';
import 'data/storage/secret_store.dart';
import 'data/storage/secure_storage_secret_store.dart';
import 'domain/ai/ai_client.dart';
import 'domain/entities/ai_plan.dart';
import 'domain/entities/ai_provider.dart';
import 'domain/repositories/ai_plan_repository.dart';
import 'domain/repositories/conversation_repository.dart';
import 'domain/repositories/settings_store.dart';
import 'domain/repositories/task_repository.dart';

/// 全局依赖容器。
final GetIt getIt = GetIt.instance;

/// 注册生产依赖：Drift 仓储 + OpenAI 客户端 + 持久化设置存储。
///
/// 启动顺序：`await settingsStore.load()` 把持久化配置加载进内存缓存 →
/// `ensureDefaultConversation()` 保证存在默认会话（幂等）。除此之外不做其他启动工作。
Future<void> configureDependencies() async {
  // F9：以真正的数据库单例为幂等标志，避免依赖「先注册 MemorySettingsStore」
  // 这一偶然顺序；测试重置后该标志随 registerAppDatabase 一起消失，语义正确。
  if (getIt.isRegistered<AppDatabase>()) {
    return;
  }

  // 单例数据库：ConversationRepositoryImpl 与 AIPlanRepositoryImpl 必须共享它，
  // 否则 Drift 的嵌套事务无法复用外层，confirm 的原子性不成立（§7）。
  final database = AppDatabase.open();
  getIt.registerSingleton<AppDatabase>(database, dispose: (db) => db.close());

  // 平台安全存储。构造本身不读平台通道；平台访问只发生在 load / saveApiKey。
  getIt.registerLazySingleton<SecretStore>(() => SecureStorageSecretStore());

  const clock = SystemClock();

  getIt.registerLazySingleton<ConversationRepository>(
    () => ConversationRepositoryImpl(getIt<AppDatabase>(), clock),
  );

  final taskRepository = TaskRepositoryImpl(database, clock);
  getIt.registerSingleton<TaskRepository>(taskRepository);

  getIt.registerLazySingleton<AIPlanRepository>(
    () => AIPlanRepositoryImpl(
      getIt<AppDatabase>(),
      getIt<TaskRepository>(),
      clock,
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
}) async {
  await getIt.reset();

  final secrets = MemorySecretStore();
  getIt.registerSingleton<MemorySecretStore>(secrets);
  getIt.registerSingleton<SecretStore>(secrets);

  final settings = settingsStore ?? MemorySettingsStore();
  getIt.registerSingleton<MemorySettingsStore>(settings);
  getIt.registerSingleton<SettingsStore>(settings);

  getIt.registerSingleton<AIClient>(aiClient ?? const _StubAIClient());

  final conversation = conversationRepository ?? MemoryConversationRepository();
  // 预置默认会话，替代 HomeScreen 的 initState 引导（S12）。
  await conversation.ensureDefaultConversation();
  getIt.registerSingleton<ConversationRepository>(conversation);

  // 同一 MemoryTaskRepository 实例注入 MemoryAIPlanRepository，
  // 保证内存 confirm 的全或无语义（S2/S9）。
  final tasks = taskRepository ?? MemoryTaskRepository();
  getIt.registerSingleton<MemoryTaskRepository>(tasks);
  getIt.registerSingleton<TaskRepository>(tasks);

  getIt.registerSingleton<AIPlanRepository>(
    aiPlanRepository ?? MemoryAIPlanRepository(tasks),
  );
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
