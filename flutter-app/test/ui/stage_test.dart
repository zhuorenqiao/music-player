// test/ui/stage_test.dart
//
// 播放卡（T26）：圆碟封面、曲名 / 歌手 / 专辑、损坏角标、上下两条时间、
// 以及两块热区（信息区与封面各自独立，M2 分别接歌词页与灯箱）。
//
// 三处刻意的取舍：
//   - 尺寸用例改视口而不用 `SizedBox`：Scaffold 给 body 的约束是紧的，
//     `SizedBox(width: 360)` 会被压回窗口宽度（T24/T25 的用例同理）；
//   - 封面一律用空串或不存在的路径，测试不依赖任何真实图片文件；
//   - 进度用 `ValueNotifier` 直接推：这正是「只有时间行跟着 tick 重建」
//     那条约束的回归网。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/breakpoints.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/stage.dart';
import 'package:provider/provider.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

/// 按逻辑像素设视口再 pump：卡片读的是视口尺寸，不是父级的紧约束。
Future<void> pumpAt(
  WidgetTester tester,
  double width,
  double height,
  Widget child,
) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  await tester.pumpWidget(wrap(child));
}

const StagePreview fullStage = StagePreview(
  title: '白玫瑰',
  artist: '陈奕迅',
  album: 'Stranger Under My Skin',
  elapsed: '02:15',
  total: '03:46',
  coverPath: '',
);

void main() {
  testWidgets('显示曲名、歌手、专辑与时长', (tester) async {
    await pumpAt(tester, 1000, 700, fullStage);

    expect(find.text('白玫瑰'), findsOneWidget);
    expect(find.text('陈奕迅'), findsOneWidget);
    expect(find.text('Stranger Under My Skin'), findsOneWidget);
    expect(find.text('02:15 / 03:46'), findsOneWidget);
  });

  testWidgets('长曲名省略号截断，不换行不撑宽', (tester) async {
    const title = '一首名字长到必须截断的曲目用来验证省略号与不撑宽的行为';
    await pumpAt(
      tester,
      360,
      700,
      const StagePreview(
        title: title,
        artist: '陈奕迅',
        album: '',
        elapsed: '00:00',
        total: '--:--',
      ),
    );

    final line = tester.widget<Text>(find.text(title));
    expect(line.maxLines, 1);
    expect(line.overflow, TextOverflow.ellipsis);
    // 卡片 360 宽、左右各 16 内边距：文字行永远撑不满窗口
    expect(tester.getRect(find.text(title)).width, lessThan(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有真封面时显示占位碟而不是空白', (tester) async {
    await pumpAt(tester, 800, 700, fullStage);

    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
  });

  testWidgets('封面文件读不到时同样退回占位碟', (tester) async {
    await pumpAt(
      tester,
      800,
      700,
      const StagePreview(
        title: 'A',
        artist: '',
        album: '',
        elapsed: '--:--',
        total: '--:--',
        coverPath: 'C:/__no_such_dir__/no_such_cover.png',
      ),
    );

    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
  });

  testWidgets('损坏态显示状态而不是清空标题', (tester) async {
    await pumpAt(
      tester,
      800,
      700,
      const StagePreview(
        title: '坏文件',
        artist: '某人',
        album: '',
        elapsed: '--:--',
        total: '--:--',
        broken: true,
      ),
    );

    expect(find.text('坏文件'), findsOneWidget);
    expect(find.text('损坏'), findsOneWidget);
  });

  testWidgets('曲目信息区整体是一个可点热区，封面单独一块且都有读屏名', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpAt(
        tester,
        800,
        700,
        const StagePreview(
          title: 'A',
          artist: 'B',
          album: '',
          elapsed: '00:00',
          total: '00:10',
          coverPath: '',
        ),
      );

      expect(find.byKey(const Key('stage-hit-area')), findsOneWidget);
      expect(find.byKey(const Key('cover-disc')), findsOneWidget);

      final hit = tester
          .getSemantics(find.byKey(const Key('stage-hit-area')))
          .getSemanticsData();
      expect(hit.flagsCollection.isButton, isTrue);
      expect(hit.label, contains('歌词'));

      final cover = tester
          .getSemantics(find.byKey(const Key('cover-disc')))
          .getSemanticsData();
      expect(cover.flagsCollection.isButton, isTrue);
      expect(cover.label, contains('封面'));

      // M1 的点击是空实现：点两下不该抛异常，也不该改动任何状态
      await tester.tap(find.byKey(const Key('stage-hit-area')));
      await tester.tap(find.byKey(const Key('cover-disc')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('封面尺寸跟随三档断点', (tester) async {
    for (final width in [360.0, 1000.0, 1300.0]) {
      await pumpAt(
        tester,
        width,
        900,
        const StagePreview(
          title: 'A',
          artist: '',
          album: '',
          elapsed: '',
          total: '',
          coverPath: '',
        ),
      );

      final disc = tester.getRect(find.byKey(const Key('cover-disc')));
      final expected = kCoverSize(width, viewportHeight: 900);
      expect(disc.width, closeTo(expected, 1.0), reason: 'width=$width');
      expect(disc.height, closeTo(expected, 1.0), reason: 'width=$width');
    }
  });

  testWidgets('时间行跟着 position 走，卡片其余部分不参与', (tester) async {
    final position = ValueNotifier<double>(45);
    addTearDown(position.dispose);
    await pumpAt(
      tester,
      800,
      700,
      StagePreview(
        title: 'A',
        artist: 'B',
        album: '',
        total: '03:46',
        position: position,
      ),
    );

    expect(find.text('00:45 / 03:46'), findsOneWidget);

    position.value = 135;
    await tester.pump();
    expect(find.text('02:15 / 03:46'), findsOneWidget);
  });

  testWidgets('没有当前曲目时给空态引导', (tester) async {
    final state = PlayerState.fake(Playlist());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerState>.value(
        value: state,
        child: wrap(const Stage()),
      ),
    );

    expect(find.text('未选择曲目'), findsOneWidget);
    expect(find.text('从播放列表选一首开始'), findsOneWidget);
  });

  /// 终审 minor 3 的缺陷复现（改前红）：这里从前只写 `total: formatTime(track?.duration)`，
  /// 注释还声称「内核报的 duration 可能比标签值晚到，卡片先按标签值显示」——
  /// 标签根本没有时长（ID3v1-only、无标签文件）时，内核早就把时长报上来了，
  /// 卡片仍然一直挂着 `--:--`（ledger T26 那条 deferred minor）。
  testWidgets('标签没时长时回退内核报的时长；两处都未知才是 --:--', (tester) async {
    final track = Track(id: '1', src: '/1.flac', title: '无标签曲');
    expect(track.hasDuration, isFalse);
    final state = PlayerState.fake(Playlist.fromTracks([track]));
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerState>.value(
        value: state,
        child: wrap(const Stage()),
      ),
    );

    // 两处都不知道：总长给 --:--（当前位置照常是 00:00），不许瞎猜时长
    expect(find.text('00:00 / --:--'), findsOneWidget);

    // 内核 load 完回报时长（transport.duration 那个 ValueNotifier）
    state.duration.value = 200;
    await tester.pump();
    expect(
      find.text('00:00 / 03:20'),
      findsOneWidget,
      reason: '标签没有时长时要用内核报的，不能再卡在 --:--',
    );

    // 标签回填出时长之后以标签为准（元数据优先，与 TransportBar 的两级取值同源）。
    // 回填改的是列表里的活对象，靠 minor 2 的展示快照 + syncView 才会刷到界面。
    track.duration = 300;
    state.transport.syncView();
    await tester.pump();
    expect(find.text('00:00 / 05:00'), findsOneWidget);
  });

  testWidgets('时长行只订阅那两片叶子，position 走动不重建整卡', (tester) async {
    final track = Track(id: '1', src: '/1.flac', title: '有标签曲', duration: 120);
    final state = PlayerState.fake(Playlist.fromTracks([track]));
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerState>.value(
        value: state,
        child: wrap(const Stage()),
      ),
    );

    // 标签有时长：内核报的别的值不许盖掉它
    state.duration.value = 999;
    await tester.pump();
    expect(find.text('00:00 / 02:00'), findsOneWidget);

    state.position.value = 30;
    await tester.pump();
    expect(find.text('00:30 / 02:00'), findsOneWidget);
  });
}
