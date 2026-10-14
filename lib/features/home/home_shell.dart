import 'package:flutter/material.dart';

import '../calendar/calendar_screen.dart';
import '../health/health_screen.dart';
import '../settings/settings_screen.dart';
import '../tasks/tasks_screen.dart';
import 'home_screen.dart';

/// 主壳：底部导航五区，保持各 tab 状态。
class HomeShell extends StatefulWidget {
  /// 创建主壳。
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          HomeScreen(),
          TasksScreen(),
          CalendarScreen(),
          HealthScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _index,
        selectedItemColor: Colors.blue,
        onTap: (value) {
          setState(() => _index = value);
        },
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: '对话',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.checklist),
            label: '任务',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_month),
            label: '日历',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.favorite_border),
            label: '健康',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
