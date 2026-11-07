// test/ui/track_row_test.dart
//
// 播放列表行与最近播放行（T27）：对译 `src/App.tsx:726-824` 与
// `src/styles/app.css` 的 `.track*` / `.recent*`。
//
// 四处刻意的取舍：
//   - 缩略图一律用空串或写死的坏路径：测试不依赖任何真实图片文件，
//     也顺带钉住「路径读不出来不许抛」这条；
//   - 语义用例各自 `ensureSemantics()`：`find.bySemanticsLabel` 要求语义树已开，
//     handle 必须在用例体内销毁（与 header_test 一致）；
//   - 音柱的静止高度直接量 `SizedBox`：`bar-0/1/2` 对应 CSS 的
//     `.track__bars i:nth-child(n)` 的 5 / 9 / 6；
//   - 减少动态效果那条只断言「不建动画对象 + 三根静止」，不碰时长。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/cover_thumb.dart';
import 'package:light_music/ui/recent_row.dart';
import 'package:light_music/ui/track_row.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(body: SizedBox(width: 420, child: child)),
    ),
  );

  testWidgets('行内显示标题、歌手·专辑与时长', (tester) async {
    var played = 0;
    await pump(
      tester,
      TrackRow(
        title: '白玫瑰',
        artistLine: '陈奕迅 · Stranger Under My Skin',
        duration: '03:46',
        active: false,
        playing: false,
        broken: false,
        onPlay: () => played++,
        onRemove: () {},
      ),
    );
    expect(find.text('白玫瑰'), findsOneWidget);
    expect(find.text('陈奕迅 · Stranger Under My Skin'), findsOneWidget);
    expect(find.text('03:46'), findsOneWidget);
    await tester.tap(find.text('白玫瑰'));
    expect(played, 1);
  });

  testWidgets('删除按钮点击不冒泡到播放', (tester) async {
    var played = 0;
    var removed = 0;
    await pump(
      tester,
      TrackRow(
        title: 'A',
        artistLine: 'B',
        duration: '00:10',
        active: false,
        playing: false,
        broken: false,
        onPlay: () => played++,
        onRemove: () => removed++,
      ),
    );
    await tester.tap(find.byKey(const Key('track-remove')));
    expect(removed, 1);
    expect(played, 0);
  });

  testWidgets('删除按钮视觉 34、热区不小于 44', (tester) async {
    await pump(
      tester,
      TrackRow(
        title: 'A',
        artistLine: 'B',
        duration: '',
        active: false,
        playing: false,
        broken: false,
        onPlay: () {},
        onRemove: () {},
      ),
    );
    expect(
      tester.getRect(find.byKey(const Key('track-remove'))).width,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getRect(find.byKey(const Key('track-remove-visual'))).width,
      34,
    );
  });

  testWidgets('当前项显示音柱，非当前项不显示', (tester) async {
    await pump(
      tester,
      Column(
        children: [
          TrackRow(
            title: '当前',
            artistLine: '',
            duration: '',
            active: true,
            playing: true,
            broken: false,
            onPlay: () {},
            onRemove: () {},
          ),
          TrackRow(
            title: '其他',
            artistLine: '',
            duration: '',
            active: false,
            playing: false,
            broken: false,
            onPlay: () {},
            onRemove: () {},
          ),
        ],
      ),
    );
    expect(find.byKey(const Key('bars-indicator')), findsOneWidget);
  });

  testWidgets('播放中才起舞；暂停时音柱回到静止高度', (tester) async {
    await pump(tester, const BarsIndicator(playing: true));
    expect(find.byKey(const Key('bars-animation')), findsOneWidget);

    await pump(tester, const BarsIndicator(playing: false));
    expect(find.byKey(const Key('bars-animation')), findsNothing);
    expect(
      [
        for (var i = 0; i < 3; i++)
          tester.getSize(find.byKey(Key('bar-$i'))).height,
      ],
      [5.0, 9.0, 6.0],
    );
  });

  testWidgets('减少动态效果时音柱不建动画，直接静止', (tester) async {
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(disableAnimations: true),
          child: const Scaffold(body: BarsIndicator(playing: true)),
        ),
      ),
    );

    expect(find.byKey(const Key('bars-indicator')), findsOneWidget);
    expect(find.byKey(const Key('bars-animation')), findsNothing);
    expect(
      [
        for (var i = 0; i < 3; i++)
          tester.getSize(find.byKey(Key('bar-$i'))).height,
      ],
      [5.0, 9.0, 6.0],
    );
  });

  testWidgets('损坏项有角标且文案不裁；封面路径读不出也不抛', (tester) async {
    await pump(
      tester,
      TrackRow(
        title: '坏文件',
        artistLine: '',
        duration: '--:--',
        active: false,
        playing: false,
        broken: true,
        onPlay: () {},
        onRemove: () {},
        coverPath: 'C:/__no_such_dir__/no_such_cover.png',
      ),
    );
    expect(find.text('损坏'), findsOneWidget);
    expect(find.text('坏文件'), findsOneWidget);
    expect(find.byKey(const Key('track-thumb')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('语义标签逐字对齐原版', (tester) async {
    // handle 必须在用例体内销毁：addTearDown 跑在框架收尾校验之后，会被判泄漏
    final semantics = tester.ensureSemantics();
    try {
      await pump(
        tester,
        TrackRow(
          title: '十年',
          artistLine: '陈奕迅',
          duration: '03:46',
          active: false,
          playing: false,
          broken: false,
          onPlay: () {},
          onRemove: () {},
        ),
      );
      expect(find.bySemanticsLabel('播放《十年》'), findsOneWidget);
      expect(find.bySemanticsLabel('从播放列表移除《十年》'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('最近行显示相对时间与时长', (tester) async {
    await pump(
      tester,
      RecentRow(
        title: '孤勇者',
        artist: '陈奕迅',
        relativeTime: '3 分钟前',
        duration: '04:12',
        inPlaylist: true,
        active: false,
        onTap: () {},
      ),
    );
    expect(find.text('孤勇者'), findsOneWidget);
    expect(find.text('3 分钟前'), findsOneWidget);
    expect(find.text('04:12'), findsOneWidget);
  });

  testWidgets('失效条目变暗并给出提示而不是静默失败', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var taps = 0;
      await pump(
        tester,
        RecentRow(
          title: '已删',
          artist: 'X',
          relativeTime: '昨天',
          duration: '',
          inPlaylist: false,
          active: false,
          onTap: () => taps++,
        ),
      );
      final opacity = tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .opacity;
      expect(opacity, closeTo(0.55, 0.01));
      expect(find.text('已不在列表'), findsOneWidget);
      expect(find.bySemanticsLabel('已删（已不在播放列表中）'), findsOneWidget);
      // 条目失效时点击仍然交给面板处理（由面板提示），行本身不许静默吞掉
      await tester.tap(find.text('已删'));
      expect(taps, 1);
    } finally {
      semantics.dispose();
    }
  });
}
