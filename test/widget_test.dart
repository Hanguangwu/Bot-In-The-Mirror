import 'package:chatwithalice/app.dart';
import 'package:chatwithalice/data/memory/memory_project_repository.dart';
import 'package:chatwithalice/data/memory/memory_task_repository.dart';
import 'package:chatwithalice/di.dart';
import 'package:chatwithalice/domain/entities/task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 页面标题断言：底部导航 label 与 AppBar 标题同名，须限定 AppBar 后代。
Finder appBarTitle(String title) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(title));

void main() {
  testWidgets('底部导航五 tab 可达', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    // 对话 tab 默认可见
    expect(find.text('Chat with Alice'), findsOneWidget);

    // 任务 tab
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pumpAndSettle();
    expect(appBarTitle('任务'), findsOneWidget);
    expect(find.text('还没有任务，点右下角按钮新建，或让 Alice 帮你拆解'), findsOneWidget);

    // 日历 tab
    await tester.tap(find.byIcon(Icons.calendar_month));
    await tester.pumpAndSettle();
    expect(appBarTitle('日历'), findsOneWidget);

    // 健康 tab
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(appBarTitle('健康'), findsOneWidget);

    // 设置 tab
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(appBarTitle('设置'), findsOneWidget);

    // 回到对话 tab
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(find.text('Chat with Alice'), findsOneWidget);
  });

  testWidgets('健康占位页渲染文案', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(find.text('健康功能将在后续版本提供'), findsOneWidget);
  });

  testWidgets('日历日视图空态', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.calendar_month));
    await tester.pumpAndSettle();
    // 默认即日视图；显式切一次确认切换可交互。
    await tester.tap(find.text('日'));
    await tester.pumpAndSettle();
    expect(find.text('这一天还没有安排，点右下角按钮添加'), findsOneWidget);
  });

  testWidgets('任务页项目分组本地过滤', (tester) async {
    await resetDependenciesForTest();
    final now = DateTime.now();
    final projects = getIt<MemoryProjectRepository>();
    final work = await projects.save(
      Project(
        id: 'p-work',
        userId: '',
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: '',
        name: '工作',
      ),
    );
    final life = await projects.save(
      Project(
        id: 'p-life',
        userId: '',
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: '',
        name: '生活',
      ),
    );
    final tasks = getIt<MemoryTaskRepository>();
    await tasks.save(
      Task(
        id: 't-work',
        userId: '',
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: '',
        projectId: work.id,
        title: '写周报',
      ),
    );
    await tasks.save(
      Task(
        id: 't-life',
        userId: '',
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: '',
        projectId: life.id,
        title: '买菜',
      ),
    );

    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pumpAndSettle();
    // 切到「待办」以显示无截止时间的任务。
    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();
    expect(find.text('写周报'), findsOneWidget);
    expect(find.text('买菜'), findsOneWidget);

    // 选中「工作」项目 → 本地过滤掉「生活」任务。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();
    expect(find.text('写周报'), findsOneWidget);
    expect(find.text('买菜'), findsNothing);
  });

  testWidgets('首页渲染默认会话', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();
    expect(find.text('AI助手'), findsOneWidget);
  });

  testWidgets('设置保存流程', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(appBarTitle('设置'), findsOneWidget);

    final saveButton = find.text('保存设置');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('API Key 已保存至安全存储'), findsOneWidget);
  });

  testWidgets('聊天页拆解按钮禁用态：无 user 消息的会话中按钮 onPressed == null', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    // 进入默认会话（尚无 user 消息）
    await tester.tap(find.text('AI助手'));
    await tester.pumpAndSettle();
    // byIcon 命中 Icon 而非 IconButton，用 widgetWithIcon 直接定位按钮。
    final checklistButton = find.widgetWithIcon(IconButton, Icons.checklist);
    expect(checklistButton, findsOneWidget);
    final button = tester.widget<IconButton>(checklistButton);
    expect(button.onPressed, isNull);
  });

  testWidgets('清空依赖后仍可渲染首页（隔离性）', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();
    expect(find.text('Chat with Alice'), findsOneWidget);
  });
}
