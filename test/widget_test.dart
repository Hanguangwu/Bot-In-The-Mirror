import 'package:chatwithalice/app.dart';
import 'package:chatwithalice/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首页渲染默认会话 → 进入设置 → 保存设置', (tester) async {
    // 全程使用内存适配器与假 AIClient，不触网、不建真实数据库。
    await resetDependenciesForTest();

    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();

    // 首页应通过 ensureDefaultConversation 展示默认会话。
    expect(find.text('AI助手'), findsOneWidget);

    // 进入设置页。
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);

    // 保存设置并检查 SnackBar（按钮在竖屏下方，先滚动到可见处）。
    final saveButton = find.text('保存设置');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('设置已保存'), findsOneWidget);
  });

  testWidgets('清空依赖后仍可渲染首页（隔离性）', (tester) async {
    await resetDependenciesForTest();
    await tester.pumpWidget(const ChatWithAliceApp());
    await tester.pumpAndSettle();
    expect(find.text('Chat with Alice'), findsOneWidget);
  });
}
