// test/ui/vinyl_deck_test.dart
//
// 回归：播放中首次挂载 CoverDisc / Tonearm 不能红屏。
//
// 两者原先都在 initState() 里读 `MediaQuery.disableAnimationsOf(context)`，
// 而 InheritedModel 依赖在 initState 里取会触发框架断言：
//   dependOnInheritedWidgetOfExactType<MediaQuery>() or
//   dependOnInheritedElement() was called before _CoverDiscState.initState()
//   completed.
// 只在 `spinning: true` 时才走到那行（false 时 `&&` 短路），所以此前
// cover_image_test.dart 里的空态用例一直没暴露；真实播放时才复现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/tonearm.dart';
import 'package:light_music/ui/vinyl_deck.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: Center(child: child)),
);

/// 按 [spinning] 与 [reduced] 重建整棵树；[MediaQuery] 覆在 MaterialApp 内层，
/// 与真机上「系统减少动态效果」影响子树的方式一致。
Future<void> pumpDeck(
  WidgetTester tester, {
  required bool spinning,
  required bool reduced,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: wrap(
        Stack(
          alignment: Alignment.center,
          children: [
            CoverDisc(
              coverPath: '',
              size: 200,
              spinning: spinning,
              fallbackArtist: '陈奕迅',
              fallbackTitle: '十年',
            ),
            Tonearm(spinning: spinning, size: 200),
          ],
        ),
      ),
    ),
  );
  // 让 AnimatedBuilder / 动画首帧都跑一遍，别把异常藏在后续帧里。
  await tester.pump();
}

/// 某个节点**最近**的那个 Transform（盘面 / 标签的旋转就挂在上面）。
///
/// 找不到返回 null —— 反光那层刻意不在任何 Transform 里（灯不随唱片转）。
Transform? nearestTransform(WidgetTester tester, Finder node) {
  final ancestors = find.ancestor(of: node, matching: find.byType(Transform));
  if (ancestors.evaluate().isEmpty) return null;
  return tester.widget<Transform>(ancestors.first);
}

void main() {
  testWidgets('播放中首次挂载不抛 dependOnInherited 红屏', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);

    await pumpDeck(tester, spinning: true, reduced: false);

    expect(tester.takeException(), isNull);
    expect(find.byType(CoverDisc), findsOneWidget);
    expect(find.byType(Tonearm), findsOneWidget);
  });

  testWidgets('减少动态效果来回切换不抛、旋转状态跟着收放', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);

    for (final reduced in [false, true, false, true, false]) {
      await pumpDeck(tester, spinning: true, reduced: reduced);
      expect(
        tester.takeException(),
        isNull,
        reason: 'spinning=true, disableAnimations=$reduced',
      );
    }
  });

  testWidgets('播放/暂停切换不抛（暂停冻角、恢复接着转）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);

    for (final spinning in [false, true, false, true]) {
      await pumpDeck(tester, spinning: spinning, reduced: false);
      expect(tester.takeException(), isNull, reason: 'spinning=$spinning');
    }
  });

  group('黑胶外圈（与 React 的 .stage__vinyl 一致）', () {
    testWidgets('封面是唱片中间的标签位：占碟面 62%', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);

      await pumpDeck(tester, spinning: false, reduced: false);

      final label = tester.getSize(find.byKey(const Key('vinyl-label')));
      expect(label.width, closeTo(200 * 0.62, 0.5));
      expect(label.height, closeTo(200 * 0.62, 0.5));
      // 盘面铺满整张碟（标签之外那一圈）
      expect(
        tester.getSize(find.byKey(const Key('vinyl-disc-paint'))),
        const Size(200, 200),
      );
    });

    testWidgets('盘面与标签同一相位：两个 Transform 角度一致', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);

      await pumpDeck(tester, spinning: true, reduced: false);
      await tester.pump(const Duration(milliseconds: 1200));

      final disc = nearestTransform(
        tester,
        find.byKey(const Key('vinyl-disc-paint')),
      );
      final label = nearestTransform(
        tester,
        find.byKey(const Key('vinyl-label')),
      );
      expect(disc, isNotNull);
      expect(label, isNotNull);
      // 同一个控制器、同一次读取 → 角度逐字相同（不是"差不多"）
      expect(label!.transform, disc!.transform);
    });

    testWidgets('斜向反光固定不动：不在任何 Transform 里', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);

      await pumpDeck(tester, spinning: true, reduced: false);
      await tester.pump(const Duration(milliseconds: 1200));

      // 灯不随唱片转：反光那层没有旋转包裹（app.css:815 的注释）
      expect(
        nearestTransform(
          tester,
          find.byKey(const Key('vinyl-reflection-paint')),
        ),
        isNull,
      );
    });

    testWidgets('播放中盘面与标签的角度一起推进', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);

      await pumpDeck(tester, spinning: true, reduced: false);
      await tester.pump();
      final before = nearestTransform(
        tester,
        find.byKey(const Key('vinyl-label')),
      )!;
      await tester.pump(const Duration(seconds: 2));
      final after = nearestTransform(
        tester,
        find.byKey(const Key('vinyl-label')),
      )!;
      expect(after.transform, isNot(before.transform));
    });

    testWidgets('歌词页形态（vinyl: false）：没有外圈，封面铺满', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);

      await tester.pumpWidget(
        wrap(
          CoverDisc(
            coverPath: '',
            size: 200,
            spinning: false,
            vinyl: false,
            fallbackArtist: '陈奕迅',
            fallbackTitle: '十年',
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('vinyl-disc-paint')), findsNothing);
      expect(find.byKey(const Key('vinyl-reflection-paint')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('vinyl-label'))),
        const Size(200, 200),
      );
    });
  });
}
