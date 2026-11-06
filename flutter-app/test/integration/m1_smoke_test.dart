// test/integration/m1_smoke_test.dart
//
// M1 端到端冒烟（T30）：装的是**真的应用根** [LightMusicApp]，只假三样 ——
// 内存 prefs、临时目录仓储、`FakeAudioDriver` 的播放内核（它只记调用，不开任何
// 文件）。这条用例存在的意义就是「装配本身被验过」：
//
//   1. 快捷键层确实包在 HomePage 外面，空格 / ←→ / ↑↓ / M 落到真 [PlayerState]
//      的四个动作上（shortcuts 那份用例只验到回调名，验不到接线）；
//   2. T25-T29 造的每一颗控件都带读屏名 —— 按语义节点找，不按视觉找；
//   3. Tab 能从头走到控制条，播放 / 暂停那颗可达，控制行顺序与视觉顺序一致；
//   4. 加上快捷键宿主之后，[ToastsHost] 的 liveRegion 仍然生效；
//   5. 抽屉这类模态路由开着时，快捷键不往背后的播放器穿透。
//
// 全程不 `pumpAndSettle`：当前行「播放中 + 音柱」是个永远不结束的 ticker，
// 推帧只能一段一段 `pump(Duration)`（`settle` 在这里等价于卡死）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/shortcuts.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/home_page.dart';
import 'package:light_music/ui/toasts.dart';

Track track(String id, String title) =>
    Track(id: id, src: '/m/$id.flac', title: title, duration: 61);

/// 语义审计表：控件的 Key → 读屏必须念出的那段文字。
///
/// 键用现成的（T25-T29 就打好了），文案与 README「无障碍」一节一致。
const Map<String, String> kLabeledControls = <String, String>{
  'menu-button': '更多', // T25 头部菜单
  'cover-disc': '十年 封面', // T26 播放卡：封面热区
  'stage-hit-area': '查看歌词：十年', // T26 播放卡：信息热区
  'btn-mode': '播放模式：列表循环', // T29 四个 40 钮
  'btn-prev': '上一首',
  'btn-play': '播放',
  'btn-next': '下一首',
  'progress-slider': '播放进度', // T29 进度条
  'volume-input': '音量', // T29 音量滑轨
  'volume-mute': '静音', // T29 静音钮
  'panel-tab-playlist': '播放列表', // T28 两个 tab
  'panel-tab-recent': '最近',
  'panel-search': '搜索歌名', // T28 搜索框
  'track-thumb': '播放《十年》', // T27 行的主热区
  'track-remove': '从播放列表移除《十年》', // T27 行的删除
};

/// 只有「按一下就触发」这一类才要求 button 语义；滑轨与文本框不算。
const Set<String> kButtons = <String>{
  'menu-button',
  'cover-disc',
  'stage-hit-area',
  'btn-mode',
  'btn-prev',
  'btn-play',
  'btn-next',
  'volume-mute',
  'panel-tab-playlist',
  'panel-tab-recent',
  'track-thumb',
  'track-remove',
};

/// 当前焦点落到的那颗控件的 Key 值（往上找第一个带 Key 的祖先）。
///
/// Tab 顺序断言要的是「焦点在谁身上」，而这些 Key 就是它们的稳定名字。
String? focusedKey() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  String? found;
  context.visitAncestorElements((element) {
    final Key? key = element.widget.key;
    if (key is ValueKey<String>) {
      found = key.value;
      return false;
    }
    return true;
  });
  return found;
}

/// 一帧一帧把假时钟推 [ms] 毫秒：既跑完 transport 的计时器，又不会像
/// `pumpAndSettle` 那样被音柱的常驻 ticker 卡住。
Future<void> tick(WidgetTester tester, {int frames = 6, int ms = 100}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(Duration(milliseconds: ms));
  }
}

/// 按一个键并把状态跑完。
///
/// 装配是在 `tester.runAsync` 里做的（要读真实存档），于是 `AudioPlayer` /
/// `TransportController` 的事件流都挂在**真**异步区上：光推假时钟，微任务不会
/// 被排干，`view` 会停在旧值上（现象是按了空格、界面还写着「播放」）。所以每次
/// 按键后面都补一次 `runAsync(pumpEventQueue)`，再出一帧让语义跟上。
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.runAsync(pumpEventQueue);
  await tick(tester, frames: 2);
}

void main() {
  late Directory dir;
  late AppPrefs prefs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('light-m1-smoke');
    prefs = AppPrefs.inMemory();
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [track('a', '十年'), track('b', '孤勇者')],
        order: ['a', 'b'],
        currentId: 'a',
        mode: PlayMode.list,
      ),
    );
    await prefs.writeNumber(StorageKeys.volume, 0.25);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('M1 冒烟：快捷键接到播放器、语义齐全、Tab 走得通', (tester) async {
    final semantics = tester.ensureSemantics();
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    // 桌面档：两栏都在，面板与控制条同时可见（窄屏那一档 T29 另有用例）
    tester.view.physicalSize = const Size(1280, 900);

    final driver = FakeAudioDriver();
    // 组合根要读真实文件，假时钟里得借 runAsync 跑真异步
    final bootstrap = (await tester.runAsync(
      () => buildBootstrap(
        prefs: prefs,
        dataDirectory: dir.path,
        driver: driver,
        bridge: FakeMediaSessionBridge(),
      ),
    ))!;
    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);
    addTearDown(bootstrap.recent.dispose);
    addTearDown(bootstrap.toasts.dispose);

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));
    await tester.pump();

    // 1) 接线位置：快捷键层在 HomePage 之上、路由之内
    expect(find.byType(AppShortcuts), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppShortcuts),
        matching: find.byType(HomePage),
      ),
      findsOneWidget,
    );

    // 2) 语义审计：每颗控件都要有读屏名，按钮还得带 button 标志
    for (final entry in kLabeledControls.entries) {
      final data = tester
          .getSemantics(find.byKey(Key(entry.key)).first)
          .getSemanticsData();
      expect(data.label, contains(entry.value), reason: entry.key);
      if (kButtons.contains(entry.key)) {
        expect(data.flagsCollection.isButton, isTrue, reason: entry.key);
      }
    }

    final player = bootstrap.player;
    expect(player.volume, closeTo(0.25, 1e-9));

    // 3) 空格 = togglePlay：暂停态起步，按一下真的把当前曲目放起来
    await press(tester, LogicalKeyboardKey.space);
    expect(player.playing, isTrue);
    expect(player.view.value.playing, isTrue);
    expect(driver.calls, contains('play'));
    expect(
      tester
          .getSemantics(find.byKey(const Key('btn-play')))
          .getSemanticsData()
          .label,
      contains('暂停'),
      reason: '播放中那颗按钮要念「暂停」',
    );

    // 4) → = seekBy(+5)：位置真的动了，不是只改了显示
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(player.position.value, closeTo(5, 0.5));

    // 5) ↑ = 音量 +5%
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volume, closeTo(0.30, 1e-6));

    // 6) M = 静音
    await press(tester, LogicalKeyboardKey.keyM);
    expect(player.muted, isTrue);

    // 7) 再按空格回到暂停
    await press(tester, LogicalKeyboardKey.space);
    expect(player.playing, isFalse);
    expect(driver.calls, contains('pause'));

    // 8) Tab 走得通：从头一直到控制条，播放那颗可达
    final visited = <String>[];
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final key = focusedKey();
      if (key != null && !visited.contains(key)) visited.add(key);
    }
    // 列表行的可聚焦节点是整行（TrackRow 的 key 就是曲目 id）：按原版语义，
    // 一行 = 一个「播放」目标；删除那颗是 GestureDetector，只带语义动作不带
    // 焦点（见 track_row.dart 的注释），所以这里不进 Tab 序列。
    for (final key in <String>[
      'menu-button',
      'panel-search',
      'a',
      'btn-play',
      'volume-mute',
    ]) {
      expect(visited, contains(key), reason: 'Tab 走不到 $key（已走：$visited）');
    }
    final traversalOrder = <int>[
      visited.indexOf('menu-button'),
      visited.indexOf('panel-search'),
      visited.indexOf('a'),
      visited.indexOf('btn-mode'),
      visited.indexOf('btn-prev'),
      visited.indexOf('btn-play'),
      visited.indexOf('btn-next'),
      visited.indexOf('volume-mute'),
    ];
    expect(
      traversalOrder,
      orderedEquals(<int>[...traversalOrder]..sort()),
      reason: 'Tab 顺序应为 菜单→搜索→列表行→模式→上一首→播放→下一首→静音，实际：$visited',
    );

    // 9) 抽屉开着时快捷键不穿透：模态路由在 Overlay 上，不在快捷键层的子树里，
    //    所以背后的播放器不该被空格/方向键偷偷改动（原版「弹层开着只认 Esc」
    //    的那道闸，M1 靠路由焦点域天然成立）。
    await tester.tap(find.byKey(const Key('menu-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DrawerMenu), findsOneWidget);
    final callsBefore = driver.calls.length;
    await press(tester, LogicalKeyboardKey.space);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(driver.calls.length, callsBefore, reason: '抽屉开着时快捷键该全部停手');
    expect(player.playing, isFalse);
    expect(player.position.value, closeTo(5, 0.5));
    // 遮罩点掉，收好这层路由再走最后一步
    await tester.tapAt(const Offset(10, 880));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DrawerMenu), findsNothing);

    // 10) liveRegion 在快捷键层加上之后仍然生效
    bootstrap.toasts.show('这首歌已经不在播放列表里了', durationMs: 100);
    await tester.pump();
    expect(find.text('这首歌已经不在播放列表里了'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byType(ToastsHost))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    // 计时走完，别把 pending timer 留给下一个用例
    await tester.pump(const Duration(milliseconds: 200));
    // 语义句柄必须在用例体**内**交回：flutter_test 在体末就检查句柄，
    // addTearDown 的时机太晚（transport_test 同一套写法）。
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
}
