import 'package:flutter/material.dart';

import 'features/home/home_shell.dart';

/// 应用根组件。主题沿用 M0 之前的样式。
class ChatWithAliceApp extends StatelessWidget {
  /// 创建应用根组件。
  const ChatWithAliceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Chat with Alice',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
        ),
      ),
      home: const HomeShell(),
    );
  }
}
