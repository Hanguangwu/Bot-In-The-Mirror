import 'package:chatwithalice/app.dart';
import 'package:chatwithalice/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('底部导航三 tab 可达', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    // 对话 tab 默认可见
    expect(find.text('Chat with Alice'), findsOneWidget);

    // 切换到任务 tab
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pumpAndSettle();
    // 底部导航 label 与页面 AppBar 标题同名，用 AppBar 后代限定避免双匹配。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('任务')),
      findsOneWidget,
    );
    expect(find.text('还没有任务，点右下角按钮新建，或让 Alice 帮你拆解'), findsOneWidget);

    // 切换到设置 tab
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    // 底部导航 label 与页面 AppBar 标题同名，用 AppBar 后代限定避免双匹配。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('设置')),
      findsOneWidget,
    );

    // 回到对话 tab
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(find.text('Chat with Alice'), findsOneWidget);
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
    // 底部导航 label 与页面 AppBar 标题同名，用 AppBar 后代限定避免双匹配。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('设置')),
      findsOneWidget,
    );

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
