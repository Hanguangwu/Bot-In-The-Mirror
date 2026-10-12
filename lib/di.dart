import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'core/errors/app_exception.dart';
import 'core/time/clock.dart';
import 'data/ai/openai_client.dart';
import 'data/local/app_database.dart';
import 'data/local/conversation_repository_impl.dart';
import 'data/memory/memory_conversation_repository.dart';
import 'data/memory/memory_settings_store.dart';
import 'domain/ai/ai_client.dart';
import 'domain/entities/ai_plan.dart';
import 'domain/entities/ai_provider.dart';
import 'domain/repositories/conversation_repository.dart';
import 'domain/repositories/settings_store.dart';

/// 全局依赖容器。
final GetIt getIt = GetIt.instance;

/// 注册生产依赖：Drift 仓储 + OpenAI 客户端 + 内存设置存储。
Future<void> configureDependencies() async {
  // F9：以真正的数据库单例为幂等标志，避免依赖「先注册 MemorySettingsStore」
  // 这一偶然顺序；测试重置后该标志随 registerAppDatabase 一起消失，语义正确。
  if (getIt.isRegistered<AppDatabase>()) {
    return;
  }

  final settingsStore = MemorySettingsStore();
  getIt.registerSingleton<MemorySettingsStore>(settingsStore);
  getIt.registerSingleton<SettingsStore>(settingsStore);

  // F8：API Key 通过 SettingsStore 接口读取，不再依赖具体实现类型。
  getIt.registerLazySingleton<AIClient>(
    () => OpenAIClient(apiKeyProvider: () => getIt<SettingsStore>().apiKey),
  );
  getIt.registerLazySingleton<AppDatabase>(
    AppDatabase.open,
    dispose: (database) => database.close(),
  );
  getIt.registerLazySingleton<ConversationRepository>(
    () => ConversationRepositoryImpl(
      getIt<AppDatabase>(),
      const SystemClock(),
    ),
  );

  // 首次启动保证存在默认会话（幂等）。
  await getIt<ConversationRepository>().ensureDefaultConversation();
}

/// 测试用：重置容器并注册全内存、无网络的实现。
///
/// 说明：get_it 9 的 `reset()` 为异步，必须先 await 再注册，否则注册会被
/// 随后的异步清理抹掉。因此本函数返回 `Future<void>`（相对契约的 `void`
/// 小幅偏离，仅为正确性）。
@visibleForTesting
Future<void> resetDependenciesForTest({
  AIClient? aiClient,
  ConversationRepository? conversationRepository,
  MemorySettingsStore? settingsStore,
}) async {
  await getIt.reset();

  final settings = settingsStore ?? MemorySettingsStore();
  getIt.registerSingleton<MemorySettingsStore>(settings);
  getIt.registerSingleton<SettingsStore>(settings);
  getIt.registerSingleton<AIClient>(aiClient ?? const _StubAIClient());
  getIt.registerSingleton<ConversationRepository>(
    conversationRepository ?? MemoryConversationRepository(),
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
