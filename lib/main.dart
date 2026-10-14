import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'di.dart';
import 'domain/entities/sync.dart';
import 'domain/sync/sync_engine.dart';

/// 应用入口：初始化绑定 → 装配依赖 → 启动自动同步 → 启动 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();

  // 启动自动同步（§9.4）：fire-and-forget，不阻塞启动流程；
  // 未配置同步基址时引擎内部空转、不触网。
  unawaited(
    getIt<SyncEngine>().sync().catchError((Object e) {
      debugPrint('启动同步失败：$e');
      return SyncReport(pushed: 0, pulled: 0, failed: 0, at: DateTime.now());
    }),
  );

  runApp(const ChatWithAliceApp());
}
