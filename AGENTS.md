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

## Architecture

Entrypoint: `lib/main.dart` → `configureDependencies()`（get_it，`lib/di.dart`）→ `ChatWithAliceApp`（`lib/app.dart`）→ `HomeScreen` / `ChatScreen` / `SettingsScreen`（`lib/features/{home,chat,settings}/`）。页面通过仓储的 watch 流（StreamBuilder）取数，**不持有业务状态**。

Live AI path:
- `lib/domain/ai/ai_client.dart` — `AIClient` 接口；`lib/data/ai/openai_client.dart` — OpenAI 兼容实现（`POST /chat/completions`，默认 base URL `https://api.chatanywhere.tech/v1`）。`proposePlan` 目前抛 `UnsupportedException`（M1 实现任务拆解）。
- `lib/domain/repositories/settings_store.dart` + `lib/data/memory/memory_settings_store.dart` — 配置（apiKey 等）M0 仅存内存、未持久化；M1 起入平台安全存储。
- 本地持久化：`lib/data/local/app_database.dart`（Drift，schemaVersion=1，`Conversations`/`Messages` 表）+ `lib/data/local/conversation_repository_impl.dart`；会话/消息一律经 `lib/domain/repositories/conversation_repository.dart` 接口访问。
- 测试缝：`resetDependenciesForTest()`（返回 `Future<void>`，get_it 异步 reset）注册全内存仓储 + 无网络 stub `AIClient`。

Legacy / dead code: M0 已物理删除旧的 `lib/screens`、`lib/services`、`lib/models`、`gemini_ai.dart`、`openai_service.dart`、`model.dart`、`secrets.dart`。不要重建这些路径；用 `core/domain/data/features` 结构。

## Docs drift

`README.md` 仍按旧架构写（`lib/secrets.dart` / `ai_service.dart` 均已删除）。实际配置入口是 Settings 页（`SettingsStore`，M0 仅内存）；API key 在 M0 不持久化。Treat README as partially stale.

Android packaging defaults: `applicationId`/namespace `com.example.chatwithalice`; release builds are currently signed with debug keys (`android/app/build.gradle.kts`).

## Product and architecture direction

- The approved design baseline is [docs/产品与技术设计方案.md](docs/产品与技术设计方案.md); domain terms are recorded in [GLOSSARY.md](GLOSSARY.md).
- Product direction: local-first single-user multi-platform sync, with `userId`/`workspaceId` retained for future multi-user support. Cloudflare Worker is the only remote entry point; D1 is never accessed directly by Flutter.
- Core data must move out of widget-local state into local persistent storage with a sync queue. `shared_preferences` is for simple preferences only, not chats/tasks/health records.
- Keep domain interfaces small and deep. UI must not directly depend on HTTP, SQLite, or a specific LLM provider. Use adapters for local storage, Worker sync, user-configured OpenAI-compatible LLMs, speech recognition, and vision.
- AI-generated task plans are proposals. Validate structured output, show a preview, and require explicit user confirmation before writing formal tasks or calendar entries.
- **copyWith 约定**：全部领域实体的 `copyWith` 无法把可空字段置回 null（`copyWith(deletedAt: null)` 会静默保留旧值）。M1 改动任务/日历字段前须先统一方案（`Object? = _sentinel` 或 `bool clearX` 参数），避免各写各的。
- API keys belong in platform secure storage and must not be logged or written to D1. Health images/audio are opt-in, editable/deletable, and must not be treated as medical advice.
- New UI strings and code comments must remain Chinese. Add tests at the domain/module interfaces so real network or model access is not required for ordinary tests.
