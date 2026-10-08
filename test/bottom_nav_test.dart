/// 底部导航栏回归测试
///
/// 背景：新增「影库」（私人影库）入口后底栏从 6 项变成 7 项，
/// 在 320px 窄屏手机上原本会 RenderFlex overflow。本测试锁定：
/// 1. 含「影库」的 7 项在窄屏下不溢出（能滚动而不是报错）
/// 2. 未配置 Emby 时不显示「影库」，索引与页面数保持一致
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selene/services/theme_service.dart';
import 'package:selene/widgets/main_layout.dart';

void main() {
  /// 在指定逻辑宽度下挂载 [MainLayout]
  Future<void> mount(
    WidgetTester tester,
    double width, {
    required bool showLibraryNav,
  }) async {
    tester.view.physicalSize = Size(width * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeService>.value(
        value: ThemeService(),
        child: MaterialApp(
          home: MainLayout(
            content: const SizedBox.expand(),
            currentBottomNavIndex: 0,
            onBottomNavChanged: (_) {},
            selectedTopTab: '首页',
            onTopTabChanged: (_) {},
            showLibraryNav: showLibraryNav,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // 320 = iPhone SE / 老款安卓；360/411 = 主流手机
  for (final width in [320.0, 360.0, 411.0, 480.0]) {
    testWidgets('未配置影库：6 项 @${width.toInt()}px 不溢出', (tester) async {
      await mount(tester, width, showLibraryNav: false);

      expect(tester.takeException(), isNull);
      expect(find.text('影库'), findsNothing,
          reason: '后端未配置私人影库时不应出现「影库」入口');
      // 原有 6 个入口必须保持不变
      for (final label in ['首页', '电影', '剧集', '动漫', '综艺', '直播']) {
        expect(find.text(label), findsOneWidget, reason: '缺少「$label」入口');
      }
    });

    testWidgets('配置影库后：7 项 @${width.toInt()}px 不溢出', (tester) async {
      await mount(tester, width, showLibraryNav: true);

      final error = tester.takeException();
      expect(error, isNull,
          reason: '7 项在 ${width.toInt()}px 溢出（新增入口不应破坏原有布局）: $error');
      expect(find.text('影库'), findsOneWidget);
    });
  }

  testWidgets('点击「影库」回调的索引为 6（与 PageView 页数一致）', (tester) async {
    tester.view.physicalSize = const Size(411 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    int? tapped;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeService>.value(
        value: ThemeService(),
        child: MaterialApp(
          home: MainLayout(
            content: const SizedBox.expand(),
            currentBottomNavIndex: 0,
            onBottomNavChanged: (index) => tapped = index,
            selectedTopTab: '首页',
            onTopTabChanged: (_) {},
            showLibraryNav: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('影库'));
    await tester.pump();

    expect(tapped, 6,
        reason: '「影库」必须是第 7 项（索引 6），'
            '否则 HomeScreen 的 PageView 会切到错误的页面');
  });
}
