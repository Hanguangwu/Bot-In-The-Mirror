import 'package:flutter/material.dart';

import 'app.dart';
import 'di.dart';

/// 应用入口：初始化绑定 → 装配依赖 → 启动 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  runApp(const ChatWithAliceApp());
}
