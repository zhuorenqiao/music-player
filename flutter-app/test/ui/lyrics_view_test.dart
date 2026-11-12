// test/ui/lyrics_view_test.dart
//
// 对表 src/App.tsx:241-318（React 的 LyricsView）与 src/styles/app.css 的
// `.lyrics` / `.lyrics--compact` / `.lyrics--full` / `.lyrics__line` / `.lyrics__trans`
// 一族（:1826-2027、:3039-3063）。两条主线：
//   * LyricsLinesView —— 纯展示，不吃任何状态层（本文件的主体）；
//   * LyricsView —— 真实入口，订阅 LyricsState / BilingualState / PlayerState。
//
// 规格断言全部对着 CSS 的数值写（容器左右 padding 4/8、行内边距 6 8 / 12 14、
// 字号 17/19、译文 13/14 + 上间距 1/3、行高 1.55/1.5、译文行高 1.45、past 不透明度
// .62/.5、译文 .85）。手动暂停那条用例刻意区分「用户拖动」与「程序化居中」：前者
// 必须暂停跟随，后者绝不能被自己触发的滚动当成手动（否则当前行永远停在旧位置）。
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lrc_parser.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_view.dart';
import 'package:provider/provider.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

List<LyricLine> cued(List<(double, String)> pairs) => [
  for (final p in pairs) LyricLine(time: p.$1, text: p.$2),
];

/// 行内边距：规格表的数值（CSS `.lyrics--compact .lyrics__line` / full）。
const _linePadCompact = EdgeInsets.symmetric(vertical: 6, horizontal: 8);
const _linePadFull = EdgeInsets.symmetric(vertical: 12, horizontal: 14);

void main() {
  final lines = cued([for (var i = 0; i < 40; i++) (i.toDouble(), '第$i句')]);

  /// 第 [index] 行的外框容器（承载行内边距与圆角的那一层）。
  Container lineBox(WidgetTester tester, int index) => tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey('lyric-line-$index')),
          matching: find.byType(Container),
        )
        .first,
  );

  /// 第 [index] 行的整行不透明度（CSS 的 `li { opacity }`）。
  double rowOpacity(WidgetTester tester, int index) => tester
      .widget<Opacity>(
        find
            .descendant(
              of: find.byKey(ValueKey('lyric-line-$index')),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  group('当前行高亮', () {
    testWidgets('只换色 + 字重 650（取 w600），无底色无辉光', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 2,
            ),
          ),
        ),
      );
      final active = tester.widget<Text>(find.text('第2句'));
      expect(active.style!.color, AppTokens.dark.accentLight);
      // CSS 的 font-weight: 650 在 Flutter 没有对应枚举；Material 的 600 最接近
      // （brief Step 1 的裁定：选 w600，不用 FontWeight.lerp 造非标权重）。
      expect(active.style!.fontWeight, FontWeight.w600);
      // 当前行没有底色：容器 decoration 必须为空（不是「有但透明」）。
      expect(lineBox(tester, 2).decoration, isNull);
      // 也没有辉光：Text 不带 shadow。
      expect(active.style!.shadows, anyOf(isNull, isEmpty));
      // 当前行不透明度 1
      expect(rowOpacity(tester, 2), 1.0);
    });

    testWidgets('普通行 textFaint，唱过的行 textDim + 整行不透明度 .62 / .5', (tester) async {
      for (final variant in LyricsVariant.values) {
        await tester.pumpWidget(
          wrap(
            SizedBox(
              height: 300,
              child: LyricsLinesView(
                lines: lines,
                trans: const [],
                variant: variant,
                activeIndex: 5,
              ),
            ),
          ),
        );
        final normal = tester.widget<Text>(find.text('第10句'));
        expect(normal.style!.color, AppTokens.dark.textFaint);
        final past = tester.widget<Text>(find.text('第1句'));
        expect(past.style!.color, AppTokens.dark.textDim);
        // 不透明度是 CSS 的 `li { opacity: var(--past-opacity) }`：压整行，
        // 不是把 alpha 乘进颜色 —— compact 0.62、歌词页覆盖成 0.5。
        expect(
          rowOpacity(tester, 1),
          closeTo(variant == LyricsVariant.full ? 0.5 : 0.62, 0.01),
          reason: '$variant 的 past 不透明度',
        );
        // 颜色本身保持 token 原值（不被 alpha 污染）
        expect(past.style!.color!.a, 1.0);
      }
    });
  });

  group('规格表（一个数字都不许差）', () {
    testWidgets('compact：容器 4、行内边距 6 8、字号 17、行高 1.55', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.compact,
              activeIndex: 0,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<Padding>(find.byKey(const Key('lyrics-content-padding')))
            .padding,
        const EdgeInsets.symmetric(horizontal: 4),
      );
      expect(lineBox(tester, 1).padding, _linePadCompact);
      final text = tester.widget<Text>(find.text('第1句'));
      expect(text.style!.fontSize, 17);
      // `.lyrics__line` 是 line-height: 1.55；compact 不覆盖
      expect(text.style!.height, closeTo(1.55, 0.001));
    });

    testWidgets('full：容器 8、行内边距 12 14、字号 19、行高 1.5', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<Padding>(find.byKey(const Key('lyrics-content-padding')))
            .padding,
        const EdgeInsets.symmetric(horizontal: 8),
      );
      expect(lineBox(tester, 1).padding, _linePadFull);
      final text = tester.widget<Text>(find.text('第1句'));
      expect(text.style!.fontSize, 19);
      expect(text.style!.height, closeTo(1.5, 0.001));
    });

    testWidgets('译文：compact 13/上间距 1，full 14/上间距 3，行高都 1.45', (tester) async {
      for (final entry in const [
        (LyricsVariant.compact, 13.0, 1.0),
        (LyricsVariant.full, 14.0, 3.0),
      ]) {
        final variant = entry.$1;
        await tester.pumpWidget(
          wrap(
            SizedBox(
              height: 300,
              child: LyricsLinesView(
                lines: cued([(0, 'Hello')]),
                trans: const ['你好'],
                variant: variant,
                activeIndex: 0,
              ),
            ),
          ),
        );
        final trans = tester.widget<Text>(find.text('你好'));
        expect(trans.style!.fontSize, entry.$2, reason: '$variant 译文字号');
        expect(trans.style!.height, closeTo(1.45, 0.001));
        // 译文与原文的间距（CSS margin-top）
        expect(
          tester
              .widget<Container>(find.byKey(const ValueKey('lyric-trans-0')))
              .padding,
          EdgeInsets.only(top: entry.$3),
          reason: '$variant 译文上间距',
        );
        // 不透明度 .85
        expect(trans.style!.color!.a, closeTo(0.85, 0.01));
      }
    });

    testWidgets('当前行的译文保持 400，不跟着加粗', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(0, 'Hello')]),
              trans: const ['你好'],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('Hello')).style!.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester.widget<Text>(find.text('你好')).style!.fontWeight,
        FontWeight.w400,
      );
    });

    testWidgets('行容器圆角 10（无底色时也不裁切内容）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.compact,
              activeIndex: 0,
            ),
          ),
        ),
      );
      final box = lineBox(tester, 1);
      expect(box.decoration, isNull);
      expect(box.clipBehavior, Clip.none);
    });
  });

  group('seek 热区', () {
    testWidgets('点原文 seek；点行内左右留白不 seek', (tester) async {
      final seeks = <double>[];
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 400,
            height: 300,
            child: LyricsLinesView(
              lines: cued([(3, '短'), (5, '长')]),
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('短'));
      expect(seeks, [3]);
      // 行内左侧留白（文字居中，行宽 400）
      final row = tester.getRect(find.byKey(const ValueKey('lyric-line-0')));
      await tester.tapAt(Offset(row.left + 2, row.center.dy));
      expect(seeks.length, 1);
    });

    testWidgets('点译文也 seek 到同一时间（译文同样是文字热区）', (tester) async {
      final seeks = <double>[];
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(7, 'Hello')]),
              trans: const ['你好'],
              variant: LyricsVariant.full,
              activeIndex: 0,
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('你好'));
      expect(seeks, [7]);
    });

    testWidgets('onSeek 为 null 时不崩、也不可点', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(3, '短')]),
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.tap(find.text('短'));
      expect(tester.takeException(), isNull);
    });
  });

  group('纯文本 / 空行', () {
    testWidgets('纯文本不高亮、不可点，空行渲染成 ·', (tester) async {
      final seeks = <double>[];
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: [
                for (final t in ['甲', '', '乙'])
                  LyricLine(time: double.nan, text: t),
              ],
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      expect(find.text('·'), findsOneWidget);
      // 纯文本行一律不高亮：哪怕 activeIndex 指着第 0 行，颜色也是纯文本那档
      expect(
        tester.widget<Text>(find.text('甲')).style!.color,
        AppTokens.dark.textDim,
      );
      expect(
        tester.widget<Text>(find.text('甲')).style!.fontWeight,
        isNot(FontWeight.w600),
      );
      await tester.tap(find.text('甲'));
      await tester.tap(find.text('·'));
      expect(seeks, isEmpty);
    });

    testWidgets('gap 行（有时间的空文本）也渲染成 ·，且不可点', (tester) async {
      final seeks = <double>[];
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(0, '甲'), (1, ''), (2, '乙')]),
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 2,
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      expect(find.text('·'), findsOneWidget);
      await tester.tap(find.text('·'));
      expect(seeks, isEmpty);
    });

    testWidgets('空列表渲染 SizedBox.shrink，没有滚动视图', (tester) async {
      await tester.pumpWidget(
        wrap(
          const SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: [],
              trans: [],
              variant: LyricsVariant.full,
              activeIndex: -1,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('lyrics-scroll')), findsNothing);
      // 不画任何东西：宽度收缩到 0（外层 SizedBox 的高度约束仍在，宽度不受它影响）。
      expect(tester.getSize(find.byType(LyricsLinesView)).width, 0);
      expect(find.byType(SingleChildScrollView), findsNothing);
    });

    testWidgets('trans 与 lines 不等长时不崩', (tester) async {
      // 长于 lines
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(0, '甲')]),
              trans: const ['壹', '贰', '叁'],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('壹'), findsOneWidget);
      expect(find.text('贰'), findsNothing);
      // 短于 lines（缺的那几行没有译文行）
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(0, '甲'), (1, '乙'), (2, '丙')]),
              trans: const ['壹'],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('壹'), findsOneWidget);
    });

    testWidgets('空行上方不给译文（gap 行只有 ·）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 300,
            child: LyricsLinesView(
              lines: cued([(0, ''), (1, '乙')]),
              trans: const ['空行译文', '乙的译文'],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      // 空行即使有译文也不显示（与 React 的 `text || '·'` + trans[index] 一致：
      // 原版 gap 行确实会渲染译文，这里保持同样的行为以便对齐 —— 见下方断言）
      expect(find.text('·'), findsOneWidget);
    });
  });

  group('滚动与跟随', () {
    testWidgets('没有滚动条，也不占位', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      // Material 在 Windows 上默认把纵向滚动视图包进 Scrollbar（app.dart:864-869），
      // 所以「没有 Scrollbar」不是白给的，必须靠 ScrollConfiguration 显式关掉。
      expect(find.byType(Scrollbar), findsNothing);
      // 也不占位：滚动视图的横向尺寸等于容器宽度（没有 8px 槽位）。
      final outer = tester.getSize(find.byType(LyricsLinesView));
      expect(tester.getSize(find.byKey(const Key('lyrics-scroll'))).width, outer.width);
    });

    testWidgets('手动拖动后 2.6s 内不跟随，到点恢复', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
              manualHold: const Duration(milliseconds: 2600),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // 模拟用户拖动（真的拖动，不是程序化滚动）
      await tester.drag(find.byKey(const Key('lyrics-scroll')), const Offset(0, -300));
      await tester.pumpAndSettle();
      final afterManual = position.pixels;
      expect(afterManual, greaterThan(0));

      // 手动期间换高亮行：不应把视图拉回去
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 20,
              manualHold: const Duration(milliseconds: 2600),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(position.pixels, closeTo(afterManual, 1));

      // 到点后再换高亮：恢复跟随
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 30,
              manualHold: const Duration(milliseconds: 2600),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, isNot(closeTo(afterManual, 1)));
    });

    testWidgets('程序化居中不算手动：连续换高亮行每次都跟随', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final first = position.pixels;

      // 程序化居中会触发 ScrollStart/Update 通知，但它不是手动：
      // 若不把「dragDetails == null」当程序化，第一次居中就会把跟随暂停掉，
      // 第二次换行时视图不动 → 下面的断言失败。
      for (final index in [10, 20]) {
        await tester.pumpWidget(
          wrap(
            SizedBox(
              height: 200,
              child: LyricsLinesView(
                lines: lines,
                trans: const [],
                variant: LyricsVariant.full,
                activeIndex: index,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(position.pixels, greaterThan(first));
      // 第 20 行应该已经居中到可视区
      final lineRect = tester.getRect(
        find.byKey(const ValueKey('lyric-line-20')),
      );
      final viewRect = tester.getRect(find.byKey(const Key('lyrics-scroll')));
      expect(
        (lineRect.center.dy - viewRect.center.dy).abs(),
        lessThan(lineRect.height),
        reason: '当前行应滚到容器中间',
      );
    });

    testWidgets('activeIndex 为 -1（还没唱到）时不滚动', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: -1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        0,
      );
    });
  });

  group('切歌后回到最上方', () {
    /// 另一首歌的歌词：行数相同、内容不同（列表身份变了 → 判定为「内容换了」）。
    final otherLines = cued([
      for (var i = 0; i < 40; i++) (i.toDouble(), '别的第$i句'),
    ]);

    testWidgets('歌词内容换了：滚动位置回到最上方', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // 先滚到中间：模拟旧歌已经滚过去了
      await tester.drag(
        find.byKey(const Key('lyrics-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));

      // 换歌：歌词内容换了 → 回到最上方
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: otherLines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0, reason: '换歌后新歌的歌词应从最上方开始');
    });

    testWidgets('内容换了但高亮行没变（旧实现漏掉的那种）也回到顶部', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // 换到第 20 行：跟着居中，视图滚下去了
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 20,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));

      // 换歌，但高亮行号恰好相同（20 → 20）：靠 activeIndex 变化触发滚动的旧
      // 实现在这里完全不会动 —— 新歌就停在旧歌滚到的位置。
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: otherLines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 20,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0);
    });

    testWidgets('内容换了这一轮不做居中：停在顶部，下一行变化时恢复跟随', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // 换歌 + 高亮行换到 20：这一轮只回顶部，不把视图拉到第 20 行
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: otherLines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 20,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0, reason: '换歌这一轮先停在顶部');

      // 下一行变化：恢复跟随（第 21 行居中）
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: otherLines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 21,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
    });
  });

  group('滚动行为', () {
    testWidgets('滚轮能滚动，且算手动（暂停跟随）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 0,
              manualHold: const Duration(milliseconds: 2600),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, 0);
      final center = tester.getCenter(find.byKey(const Key('lyrics-scroll')));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
      await tester.pumpAndSettle();
      final afterWheel = position.pixels;
      expect(afterWheel, greaterThan(0));
      // 滚轮算手动：紧接着换高亮行，视图应保持不动
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 200,
            child: LyricsLinesView(
              lines: lines,
              trans: const [],
              variant: LyricsVariant.full,
              activeIndex: 25,
              manualHold: const Duration(milliseconds: 2600),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(afterWheel, 1));
    });

    testWidgets('减少动态效果时不走滚动动画（直接到位）', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: wrap(
            SizedBox(
              height: 200,
              child: LyricsLinesView(
                lines: lines,
                trans: const [],
                variant: LyricsVariant.full,
                activeIndex: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: wrap(
            SizedBox(
              height: 200,
              child: LyricsLinesView(
                lines: lines,
                trans: const [],
                variant: LyricsVariant.full,
                activeIndex: 20,
              ),
            ),
          ),
        ),
      );
      // 一帧就该到位：零时长动画不需要再等 300ms
      await tester.pump();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, greaterThan(0));
    });
  });

  group('LyricsView（真实入口，订阅状态层）', () {
    late _Harness harness;

    tearDown(() => harness.dispose());

    Future<void> pumpView(WidgetTester tester) async {
      // test/ui 的规矩：testWidgets 跑在 FakeAsync 里，`await Future.delayed(...)`
      // 会永远等不到头（见 autoplay_gate_test.dart 文件头）。所以装配全部同步，
      // 事件流靠下面一帧帧 pump 排干，绝不 await 真异步。
      harness = _Harness();
      harness.lyrics.attach(harness.track);
      await tester.pumpWidget(harness.build());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('按播放进度高亮当前行，并带上译文', (tester) async {
      await pumpView(tester);
      // 内核初始位置 0：第一句在 1s，容差 0.12s 内够不着 → 还没到第一行。
      // 这正是 findActiveCue 的语义（T2 已钉），推进到 1s 之后才高亮。
      harness.driver.emitPosition(1.5);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Hello')).style!.color,
        AppTokens.dark.accentLight,
      );
      // 译文来自 BilingualState.trans
      expect(find.text('你好'), findsOneWidget);
    });

    testWidgets('进度推进到第二句时高亮换行', (tester) async {
      await pumpView(tester);
      harness.driver.emitPosition(1.5);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Hello')).style!.color,
        AppTokens.dark.accentLight,
      );
      harness.driver.emitPosition(6);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Darkness')).style!.color,
        AppTokens.dark.accentLight,
      );
      expect(
        tester.widget<Text>(find.text('Hello')).style!.color,
        AppTokens.dark.textDim,
      );
    });

    testWidgets('点歌词 seek 到那句的时间', (tester) async {
      await pumpView(tester);
      await tester.tap(find.text('Darkness'));
      await tester.pumpAndSettle();
      // 内核收到了 seek:5.0（第二句的时间）
      expect(
        harness.driver.calls.where((c) => c == 'seek:5.0'),
        isNotEmpty,
        reason: '点了第二句应该 seek 到 5s，实际调用：${harness.driver.calls}',
      );
    });

    testWidgets('纯文本歌词：静态展示、不高亮、不可点', (tester) async {
      harness = _Harness();
      harness.lyrics.attach(harness.plainTrack);
      await tester.pumpWidget(harness.build());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('第一行'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('第一行')).style!.color,
        AppTokens.dark.textDim,
      );
      // 点它不该抛、也不该 seek
      final before = harness.driver.calls.length;
      await tester.tap(find.text('第一行'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(harness.driver.calls.length, before);
    });
  });
}

/// `LyricsView` 的装配壳：真状态层 + 假内核，不碰网络、不碰 prefs 之外的 IO。
class _Harness {
  _Harness() {
    final prefs = AppPrefs.inMemory();
    driver = FakeAudioDriver();
    transport = TransportController(
      // 注入 no-op scheduler：seek 成功会 _armSeekGuard 排一个真 Timer，
      // 而 testWidgets 的 FakeAsync 在用例结束时要求「没有 pending Timer」。
      // 这些用例只验「点歌词 → 内核收到 seek」，守卫定时器本身不参与断言。
      player: AudioPlayer(driver, scheduler: (_, _) {}),
      recent: const _NoRecent(),
      toasts: const _NoToasts(),
      playlist: Playlist.fromTracks([track, plainTrack]),
    );
    player = PlayerState(prefs: prefs, transport: transport);
    lyrics = LyricsState(source: _NoMatchSource());
    bilingual = BilingualState(lyrics: lyrics, source: _NoTranslation());
    // 同步把内核时长塞进去：AudioPlayer.seek 在时长未知时只把位置暂存在
    // _pendingSeek（audio_player.dart:193-196），内核里不会出现 `seek:`，
    // 「点歌词 seek」那条用例就观测不到。原先这里用 `transport.playTrack()`
    // + `await Future.delayed(Duration.zero)` 装配，但 testWidgets 跑在
    // FakeAsync 里，真异步永远等不到头 —— 整份文件会挂死（见
    // autoplay_gate_test.dart 文件头的同一条规矩）。直接 emitDuration 等价
    // 于内核回报了一次 durationchange，且完全同步。
    driver.emitDuration(125);
  }

  late final FakeAudioDriver driver;
  late final TransportController transport;
  late final PlayerState player;
  late final LyricsState lyrics;
  late final BilingualState bilingual;

  Track get track => Track(
    id: 't1',
    src: '/m/t1.flac',
    title: 'Yesterday',
    artist: 'The Beatles',
    duration: 125,
    isLocal: true,
    lyrics: '[00:01]Hello\n[00:05]Darkness',
    lyricsSource: 'auto',
  );

  /// 纯文本曲目：没有带时间轴的歌词。
  Track get plainTrack => Track(
    id: 't2',
    src: '/m/t2.flac',
    title: 'Plain',
    artist: 'Someone',
    duration: 100,
    isLocal: true,
    lyricsPlain: '第一行\n第二行',
    lyricsSource: 'auto',
  );

  Widget build() => MultiProvider(
    providers: [
      ChangeNotifierProvider<LyricsState>.value(value: lyrics),
      ChangeNotifierProvider<BilingualState>.value(value: bilingual),
      ChangeNotifierProvider<PlayerState>.value(value: player),
    ],
    child: wrap(
      const SizedBox(height: 400, child: LyricsView(variant: LyricsVariant.full)),
    ),
  );

  void dispose() {
    player.dispose();
    bilingual.dispose();
    lyrics.dispose();
  }
}

/// 永远匹配不到歌词（歌词已经在曲目上，不会真的发请求）。
class _NoMatchSource implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async => const LyricsMatch(status: 'not-found');
}

/// 译文不需要：纯文本路径与「只验高亮」都不依赖它。
class _NoTranslation implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async => const TranslationResult(
    status: 'ok',
    translatedLyrics: '[00:01]你好\n[00:05]黑暗',
    originalLyrics: '[00:01]Hello\n[00:05]Darkness',
    source: '网易云译文库（人工翻译）',
  );
}

class _NoRecent implements RecentRecorder {
  const _NoRecent();

  @override
  void record(Track track, {DateTime? at}) {}
}

class _NoToasts implements ToastSink {
  const _NoToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message, {int durationMs = 3200}) {}
}
