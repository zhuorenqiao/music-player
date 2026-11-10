// test/ui/transport_test.dart
//
// 控制条（T29）：进度三层、音量、五个 40px 按钮与窄屏列表弹层。
//
// 装配风格沿用 T23/T28：只挂状态层 + 内存 prefs + 假播放内核（`FakeAudioDriver`），
// 测试不碰任何音频 IO；面板那一侧复用 `panel_harness.dart` 的假数据。
//
// 四条测试规则：
//   - 宽度用例改视口，不用 `SizedBox`：Scaffold 给 body 的约束是紧的，
//     `SizedBox(width: …)` 会被压回窗口宽度，而控制条读的正是视口宽度（断点）；
//   - `find.bySemanticsLabel` 要求语义树已开启，handle 必须在用例体**内**销毁；
//   - 全程不 `pumpAndSettle`：拖拽中的滑轨、加载中的转圈都可能永远 settle 不了；
//   - 控制条自己没有 ticker（进度条是静态绘制），所以 `pump(Duration)` 就够。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/state/cover_state.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/panel_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/panel.dart';
import 'package:light_music/ui/progress_slider.dart';
import 'package:light_music/ui/transport.dart';
import 'package:light_music/ui/volume_slider.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'panel_harness.dart';

/// 窄屏控制行的五个按钮（模式 / 上一首 / 播放 / 下一首 / 播放列表）。
const List<Key> kButtonKeys = <Key>[
  Key('btn-mode'),
  Key('btn-prev'),
  Key('btn-play'),
  Key('btn-next'),
  Key('btn-queue'),
];

/// 按逻辑像素设视口，把控制条贴在页面底部。
Future<void> pump(
  WidgetTester tester,
  Widget child, {
  double width = 1200,
  double height = 320,
  List<SingleChildWidget> providers = const <SingleChildWidget>[],
}) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  final Widget app = MaterialApp(
    theme: buildTheme().copyWith(
      extensions: const [AppTokensData(tokens: AppTokens.dark)],
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
  await tester.pumpWidget(
    providers.isEmpty
        ? app
        : MultiProvider(providers: providers, child: app),
  );
}

/// 点窄屏的列表按钮并把入场动画走完。
///
/// 三帧缺一不可，而且绝不 `pumpAndSettle`（弹层里若是「当前行 + 播放中」，音柱
/// 永远 settle 不了）：第一帧才把路由插进 Overlay 并启动动画，第二帧用 320ms
/// 把动画推到终点（`pump(Duration)` 只出一帧，同一帧里动画还停在 0），第三帧
/// 让弹层按量到的内容高度重新贴底 —— 少一帧就会看到卡片整块悬在屏幕下方。
Future<void> openQueue(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('btn-queue')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump();
}

/// 退场：同样是「一帧启动 + 一帧推进 + 一帧收尾」，只是时长给到 400ms。
Future<void> settleOut(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  testWidgets('五个按钮同尺寸 40px 且等距', (tester) async {
    await pump(
      tester,
      TransportBar.preview(
        playing: false,
        modeLabel: '列表循环',
        positionSeconds: 0,
        totalSeconds: 100,
      ),
      width: 420,
    );

    for (final key in kButtonKeys) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.width, 40, reason: '$key 宽');
      expect(rect.height, 40, reason: '$key 高');
    }
    // space-between 均分：四段间距相等，且真的摊开（不是挤成一团）
    final gaps = <double>[
      for (var i = 1; i < kButtonKeys.length; i++)
        tester.getRect(find.byKey(kButtonKeys[i])).left -
            tester.getRect(find.byKey(kButtonKeys[i - 1])).right,
    ];
    for (final gap in gaps) {
      expect(gap, closeTo(gaps.first, 0.6));
    }
    expect(gaps.first, greaterThan(0));
    // 窄屏不摆音量块（原版 .volume 在 <900 隐藏）
    expect(find.byKey(const Key('volume-slider')), findsNothing);
  });

  testWidgets('窄屏隐藏音量，桌面显示', (tester) async {
    await pump(
      tester,
      TransportBar.preview(
        playing: true,
        modeLabel: '列表循环',
        positionSeconds: 10,
        totalSeconds: 100,
      ),
      width: 420,
    );
    expect(find.byKey(const Key('volume-slider')), findsNothing);

    await pump(
      tester,
      TransportBar.preview(
        playing: true,
        modeLabel: '列表循环',
        positionSeconds: 10,
        totalSeconds: 100,
      ),
      width: 1100,
    );
    expect(find.byKey(const Key('volume-slider')), findsOneWidget);
    expect(find.byKey(const Key('volume-input')), findsOneWidget);
    // 桌面右栏常驻列表，列表入口不在控制条上重复出现
    expect(find.byKey(const Key('btn-queue')), findsNothing);
  });

  testWidgets('播放按钮语义在播放/暂停间切换，模式文案跟着 cycleMode 走', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(
        tester,
        TransportBar.preview(
          playing: false,
          modeLabel: '列表循环',
          positionSeconds: 0,
          totalSeconds: 100,
        ),
      );
      expect(find.bySemanticsLabel('播放'), findsOneWidget);
      expect(find.bySemanticsLabel('暂停'), findsNothing);

      await pump(
        tester,
        TransportBar.preview(
          playing: true,
          modeLabel: '随机播放',
          positionSeconds: 0,
          totalSeconds: 100,
        ),
      );
      expect(find.bySemanticsLabel('暂停'), findsOneWidget);
      expect(find.bySemanticsLabel('播放'), findsNothing);
      expect(find.bySemanticsLabel('播放模式：随机播放'), findsOneWidget);
      expect(find.bySemanticsLabel('上一首'), findsOneWidget);
      expect(find.bySemanticsLabel('下一首'), findsOneWidget);
    } finally {
      semantics.dispose();
    }

    // 真接线：点模式按钮 = player.cycleMode()，文案随之换
    final player = PlayerState.fake(Playlist());
    addTearDown(player.dispose);
    await pump(
      tester,
      const TransportBar(),
      providers: [ChangeNotifierProvider<PlayerState>.value(value: player)],
    );
    expect(find.bySemanticsLabel('播放模式：列表循环'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-mode')));
    await tester.pump();
    expect(player.view.value.mode, PlayMode.one);
    expect(find.bySemanticsLabel('播放模式：单曲循环'), findsOneWidget);
  });

  testWidgets('拖拽期间不跟随播放进度，松手才 seek', (tester) async {
    final seeks = <double>[];
    final updates = <double>[];

    Widget slider(double position) => ProgressSlider(
      position: position,
      buffered: 40,
      duration: 100,
      onSeekStart: () {},
      onSeekUpdate: updates.add,
      onSeekEnd: seeks.add,
    );

    await pump(tester, slider(10), width: 600, height: 120);
    final track = tester.getSize(find.byKey(const Key('progress-slider')));
    final fill = find.byKey(const Key('progress-fill'));
    final before = tester.getRect(fill);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('progress-slider'))),
    );
    await gesture.moveBy(Offset(track.width * 0.5, 0));
    await tester.pump();

    // 拖拽中：只报进度，绝不 seek（原版 scrub 态直到 change 才落）
    expect(seeks, isEmpty);
    expect(updates, isNotEmpty);
    expect(updates.last, closeTo(60, 2)); // 起点 10s + 半条 50s
    final during = tester.getRect(fill);
    expect(during.right, greaterThan(before.right)); // 填充跟着手指走

    // 拖拽期间播放进度继续 tick：滑块不许被拽回播放位置
    await pump(tester, slider(95), width: 600, height: 120);
    await tester.pump();
    expect(tester.getRect(fill), during);

    await gesture.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, closeTo(60, 2));
  });

  testWidgets('缓冲层宽度不大于填充层以外区域', (tester) async {
    await pump(
      tester,
      ProgressSlider(
        position: 20,
        buffered: 60,
        duration: 100,
        onSeekStart: () {},
        onSeekUpdate: (_) {},
        onSeekEnd: (_) {},
      ),
      width: 600,
      height: 120,
    );
    final fill = tester.getRect(find.byKey(const Key('progress-fill')));
    final buffer = tester.getRect(find.byKey(const Key('progress-buffer')));
    expect(buffer.right, greaterThan(fill.right));
    expect(buffer.width, lessThanOrEqualTo(600));
  });

  testWidgets('时长未知显示 --:--，进度按 0 处理', (tester) async {
    await pump(
      tester,
      ProgressSlider(
        position: 0,
        buffered: null,
        duration: null,
        onSeekStart: () {},
        onSeekUpdate: (_) {},
        onSeekEnd: (_) {},
      ),
      width: 600,
      height: 120,
    );
    expect(find.text('--:--'), findsWidgets);
    expect(tester.getRect(find.byKey(const Key('progress-fill'))).width, 0);
    expect(tester.getRect(find.byKey(const Key('progress-buffer'))).width, 0);
  });

  testWidgets('音量滑块拖动改变音量，静音按钮可切换', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final values = <double>[];
      var mutes = 0;
      await pump(
        tester,
        VolumeSlider(
          value: 0.5,
          muted: false,
          onChanged: values.add,
          onToggleMute: () => mutes++,
        ),
        width: 220,
        height: 120,
      );

      expect(find.bySemanticsLabel('静音'), findsOneWidget);
      expect(find.bySemanticsLabel('音量'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const Key('volume-input'))).value, '50%');

      await tester.drag(find.byKey(const Key('volume-input')), const Offset(60, 0));
      await tester.pump();
      expect(values, isNotEmpty);
      expect(values.last, greaterThan(0.5));

      await tester.tap(find.byKey(const Key('volume-mute')));
      await tester.pump();
      expect(mutes, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('减少动态效果时加载转圈不走动画，也不留常驻 ticker', (tester) async {
    // 视口设窄一点：桌面档的控制行还要放音量，420 那档只有一排按钮，转圈看得见
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 320);

    Future<void> pumpLoading(bool reduceMotion) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(disableAnimations: reduceMotion),
          child: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 420,
                child: TransportBar.preview(
                  playing: false,
                  loading: true,
                  modeLabel: '列表循环',
                  positionSeconds: 0,
                  totalSeconds: 100,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 常态：不确定态的转圈（value 为 null）+ 一个一直在跑的 ticker
    await pumpLoading(false);
    await tester.pump();
    expect(
      tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      ).value,
      isNull,
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // 减少动态效果：换成静止的 1/4 弧（给了 value 就不起 AnimationController），
    // 并且一帧都没有排下去 —— 装饰动画全部关掉，读屏与省电都受益。
    await pumpLoading(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      ).value,
      isNotNull,
    );
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏列表按钮打开与侧栏同一个面板弹层', (tester) async {
    final harness = PanelHarness(titles: <String>['十年']);
    addTearDown(harness.dispose);
    await pump(
      tester,
      const TransportBar(),
      width: 420,
      height: 700,
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<LibraryState>.value(value: harness.library),
        ChangeNotifierProvider<PlayerState>.value(value: harness.player),
        ChangeNotifierProvider<RecentState>.value(value: harness.recent),
        // M2b T10：面板的封面 resolver 也要在位（弹层里的 Panel 会 watch）。
        ChangeNotifierProvider<CoverState>.value(value: harness.cover),
        ChangeNotifierProvider<PanelController>(create: (_) => PanelController()),
      ],
    );

    await openQueue(tester);

    expect(find.byType(Panel), findsOneWidget);
    expect(find.text('十年'), findsOneWidget);
    final sheet = tester.getRect(find.byType(Panel));
    expect(sheet.height, lessThanOrEqualTo(700 * 0.72 + 1));
    expect(sheet.height, greaterThan(300));
    // 贴底：卡片底边就是视口底边，顶边留出遮罩缝隙
    expect(sheet.bottom, closeTo(700, 1));
    // 弹层里的面板带可见的收起按钮（侧栏里那颗没有）
    expect(find.byKey(const Key('panel-close')), findsOneWidget);

    // 出口一：点遮罩（弹层上方）关闭
    await tester.tapAt(const Offset(10, 10));
    await settleOut(tester);
    expect(find.byType(Panel), findsNothing);
    expect(tester.takeException(), isNull);

    // 出口二：再开一次，点收起按钮关闭
    await openQueue(tester);
    expect(find.byType(Panel), findsOneWidget);
    expect(tester.getRect(find.byType(Panel)).bottom, closeTo(700, 1));
    await tester.tap(find.byKey(const Key('panel-close')));
    await settleOut(tester);
    expect(find.byType(Panel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
