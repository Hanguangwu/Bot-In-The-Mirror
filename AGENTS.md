# AGENTS.md

Flutter app `chatwithalice` ("Chat with Alice" / repo `Bot-In-The-Mirror`). Android is the primary target; iOS/macOS/Windows/Linux/web scaffolding exists but is untargeted. **All UI strings and code comments are Chinese** — match that when adding UI.

## Commands

Standard Flutter CLI — no wrappers, FVM, or melos:

- `flutter pub get` — install deps (do this first; `pubspec.lock` is not committed)
- `flutter run` — run on device/emulator
- `flutter analyze` — lint (`analysis_options.yaml` = `flutter_lints` defaults)
- `flutter test` — run tests (see gotcha below)
- `flutter test test/widget_test.dart` — single test file
- `dart run build_runner build` — regenerate Drift codegen (`app_database.g.dart`) after changing tables in `lib/data/local/app_database.dart` (当前 build_runner 版本已移除 `--delete-conflicting-outputs`，无需传参)

`flutter`/`dart` were **not on PATH** in this environment's default shell. If commands report "not recognized", locate the Flutter SDK and add it to PATH.

## Gotchas

- **Windows 宿主上 Drift 测试需要 `sqlite3.dll`**（repo 根，gitignored）：`test/data/conversation_repository_test.dart` 用 `NativeDatabase.memory()`，没有该 DLL 会直接报错。若文件丢失，从本机任意 SQLite 发行版拷一份放回 repo 根。
- **`assets/images/` 仅含 `.gitkeep`**，`pubspec.yaml` 的 assets 声明依赖它存在——不要删目录。
- `pubspec.lock` is gitignored (via `*.lock`), so dependency resolution is not pinned.
- No CI, no formatter/typecheck config beyond `flutter_lints`; `dart format` is not enforced.
- **壳内多 FAB 的 Hero tag 冲突**：`HomeShell` 用 `IndexedStack` 同时构建三个 tab，HomeScreen 与 TasksScreen 各有一个 FAB（默认 `_DefaultHeroTag`）→ 同 route 子树内重复 Hero tag，push 新路由（如进聊天页）触发 hero 扫描即抛异常。新页面加 FAB 时要么 `heroTag: null`，要么给不同 tag。widget 测试最容易暴露此类问题。
- **widget 测试 finder 歧义**：底部导航 label「任务/设置」与各页 AppBar 标题同名，`find.text('任务')` 会双匹配；顶部要断言页面标题用 `find.descendant(of: find.byType(AppBar), matching: find.text('…'))`。`find.byIcon` 命中 `Icon` 而非 `IconButton`，取按钮用 `find.widgetWithIcon(IconButton, …)`。

## Architecture

Entrypoint: `lib/main.dart` → `configureDependencies()`（get_it，`lib/di.dart`，await 加载持久化设置）→ `ChatWithAliceApp`（`lib/app.dart`）→ `HomeShell`（`lib/features/home/home_shell.dart`，底部导航三区：对话/任务/设置，`IndexedStack` 保各 tab 状态）→ `HomeScreen` / `TasksScreen` / `ChatScreen` / `SettingsScreen`（`lib/features/{home,tasks,chat,settings}/`）。页面通过仓储的 watch 流（StreamBuilder）取数，**不持有业务状态**。

Live AI path:
- `lib/domain/ai/ai_client.dart` — `AIClient` 接口；`lib/data/ai/openai_client.dart` — OpenAI 兼容实现（`POST /chat/completions`，默认 base URL `https://api.chatanywhere.tech/v1`）。`proposePlan` 已实现（promptVersion `m1-plan-v1`，`_parsePlan` 按契约 §6.2 校验非空变更；`_StubAIClient.proposePlan` 仍抛 `UnsupportedException`，仅供测试桩）。
- 任务拆解链路：聊天页「拆解为任务」按钮（最近一条 user 消息）→ `ProposeTaskPlan`（`lib/features/tasks/application/propose_task_plan.dart`，空变更返回 null = 未能拆解）→ 待确认 `AIPlan` 落库 → 任务页「待确认的 AI 拆解」卡片 → `ConfirmTaskPlan`（confirm 原子：仓储层 Drift 嵌套事务一个事务内物化任务→applyChanges→置 applied）或 `RejectTaskPlan`。
- 配置持久化（M1 起）：`lib/data/local/persistent_settings_store.dart`（shared_preferences）实现 `SettingsStore`；API Key 经 `lib/data/storage/` 的 `SecretStore`（生产 `SecureStorageSecretStore` = flutter_secure_storage；测试 `MemorySecretStore`）保存，**不入数据库**。`SettingsStore.saveApiKey` 与 `saveProfile` 分离；`AIProviderProfile.apiKeyRef` 恒 null（M1 起废除该字段）。
- 本地持久化：`lib/data/local/app_database.dart`（Drift，schemaVersion=2：`Conversations`/`Messages` + M1 新增 `Tasks`/`AiPlans`，枚举列存 TEXT `.name`，含 onUpgrade 与索引）+ `lib/data/local/{conversation_repository_impl,task_repository_impl,ai_plan_repository_impl}.dart`；会话/消息/任务/计划一律经 `lib/domain/repositories/*.dart` 接口访问。任务查询只下推单值 status/due 区间/LIKE，集合过滤（今日/待办/已完成）在 UI 本地做。
- 测试缝：`resetDependenciesForTest()`（返回 `Future<void>`，get_it 异步 reset）注册全内存仓储（同一 `MemoryTaskRepository` 实例注入 `MemoryAIPlanRepository`）+ 无网络 stub `AIClient` + `MemorySecretStore`；可注入自定义 fake（`aiClient`/`taskRepository` 等具名参数）。**测试不得调用生产 `configureDependencies()`**（触发平台插件 MissingPluginException）。

Legacy / dead code: M0 已物理删除旧的 `lib/screens`、`lib/services`、`lib/models`、`gemini_ai.dart`、`openai_service.dart`、`model.dart`、`secrets.dart`。不要重建这些路径；用 `core/domain/data/features` 结构。

## Docs drift

`README.md` 仍按旧架构写（`lib/secrets.dart` / `ai_service.dart` 均已删除）。实际配置入口是 Settings 页（`SettingsStore`）；M1 起设置已持久化（shared_preferences），API key 入平台安全存储（flutter_secure_storage），设置页保存后即生效。README 的任务/AI 拆解描述同样滞后——以 `docs/M1-实施说明.md` 为准。Treat README as partially stale.

Android packaging defaults: `applicationId`/namespace `com.example.chatwithalice`; release builds are currently signed with debug keys (`android/app/build.gradle.kts`).

## Product and architecture direction

- The approved design baseline is [docs/产品与技术设计方案.md](docs/产品与技术设计方案.md); domain terms are recorded in [GLOSSARY.md](GLOSSARY.md).
- Product direction: local-first single-user multi-platform sync, with `userId`/`workspaceId` retained for future multi-user support. Cloudflare Worker is the only remote entry point; D1 is never accessed directly by Flutter.
- Core data must move out of widget-local state into local persistent storage with a sync queue. `shared_preferences` is for simple preferences only, not chats/tasks/health records.
- Keep domain interfaces small and deep. UI must not directly depend on HTTP, SQLite, or a specific LLM provider. Use adapters for local storage, Worker sync, user-configured OpenAI-compatible LLMs, speech recognition, and vision.
- AI-generated task plans are proposals. Validate structured output, show a preview, and require explicit user confirmation before writing formal tasks or calendar entries.
- **copyWith 约定（M1 定案）**：全部领域实体的 `copyWith` 无法把可空字段置回 null（`copyWith(deletedAt: null)` 会静默保留旧值）。**统一用命名 `bool clearX` 参数**（如 `clearDueAt`/`clearDescription`，静态类型保留，不用 `Object? = _sentinel`）。新增可清空字段时照此扩展。
- API keys belong in platform secure storage and must not be logged or written to D1. Health images/audio are opt-in, editable/deletable, and must not be treated as medical advice.
- New UI strings and code comments must remain Chinese. Add tests at the domain/module interfaces so real network or model access is not required for ordinary tests.
