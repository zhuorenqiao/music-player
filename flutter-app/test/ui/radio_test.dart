// test/ui/radio_test.dart
//
// 电台模块（T31）：顶栏入口按钮（在「更多」左侧）、电台状态层（换台 / 同台暂停、
// 开播前让音乐让位、离开时停流）、电台页（三大分组、点台开播、回音乐播放器）。
//
// 全部走 FakeRadioEngine：不开 media_kit 原生库、不打网络。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/radio/radio_engine.dart';
import 'package:light_music/radio/radio_station.dart';
import 'package:light_music/radio/radio_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/header.dart';
import 'package:light_music/ui/page_link_chip.dart';
import 'package:light_music/ui/radio_bar.dart';
import 'package:light_music/ui/radio_page.dart';
import 'package:light_music/ui/scroll_physics.dart';
import 'package:light_music/ui/sleep_moon.dart';
import 'package:light_music/ui/theme_drawer.dart';
import 'package:provider/provider.dart';

RadioStation _station(String id) => radioStationById(id)!;

/// 桌面 / 窄屏两种视口都从这里走：`AppHeader` 与 `RadioPage` 读的是窗口宽度。
void _setViewport(WidgetTester tester, Size size) {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

Widget _themed(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: child,
);

void main() {
  group('RadioState', () {
    test('换台：开流 → 播 → 在响，且先叫了一次「音乐让位」', () async {
      final engine = FakeRadioEngine();
      var tuned = 0;
      final radio = RadioState(
        engine: engine,
        onTuned: (_) {
          tuned++;
        },
      );
      addTearDown(radio.dispose);

      final station = _station('fm-beijing-music');
      await radio.tune(station);
      // 等一次微任务：playing 流是广播的，监听链路要走到 notifyListeners。
      await Future<void>.delayed(Duration.zero);

      expect(tuned, 1);
      expect(engine.calls, ['open:${station.streamUrl}', 'play']);
      expect(radio.current?.id, station.id);
      expect(radio.playing, isTrue);
      expect(radio.loading, isFalse);
    });

    test('同一台再点一次是暂停，不重新开流', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);
      final station = _station('fm-shanghai-101');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isTrue);

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isFalse);
      // 只开过一次流：第二次是 pause，不是 open
      expect(engine.calls.where((call) => call.startsWith('open:')).length, 1);
      expect(engine.calls.last, 'pause');
    });

    test('开流失败落回稳定态，并给一句人话错误', () async {
      final engine = FakeRadioEngine()..failNextOpen = true;
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);

      await radio.tune(_station('net-star'));
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isFalse);
      expect(radio.loading, isFalse);
      expect(radio.errorMessage(), contains('换一台'));
    });

    test('stop 清空当前台并停流', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);

      await radio.tune(_station('fm-guangdong-traffic'));
      await radio.stop();
      expect(radio.current, isNull);
      expect(radio.playing, isFalse);
      expect(engine.calls.last, 'stop');
    });

    test('音乐开声 → 电台让位，但当前台保留（迷你条还在）', () async {
      final engine = FakeRadioEngine();
      final music = ValueNotifier<bool>(false);
      addTearDown(music.dispose);
      final radio = RadioState(
        engine: engine,
        musicPlaying: music,
        isMusicPlaying: () => music.value,
      );
      addTearDown(radio.dispose);

      await radio.tune(_station('fm-beijing-music'));
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isTrue);

      music.value = true;
      await Future<void>.delayed(Duration.zero);

      expect(radio.playing, isFalse);
      expect(radio.current?.id, 'fm-beijing-music');
      expect(engine.calls.last, 'pause');
    });

    test('续播（音乐页点迷你条的播放键）也先让音乐让位', () async {
      final engine = FakeRadioEngine();
      final music = ValueNotifier<bool>(false);
      addTearDown(music.dispose);
      var tuned = 0;
      final radio = RadioState(
        engine: engine,
        // 与 app.dart 的装配一致：钩子负责把音乐暂停（这里直接翻状态位模拟）
        onTuned: (_) {
          tuned++;
          music.value = false;
        },
        musicPlaying: music,
        isMusicPlaying: () => music.value,
      );
      addTearDown(radio.dispose);
      final station = _station('fm-shanghai-101');

      // 开台：音乐让位一次
      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      expect(tuned, 1);

      // 音乐开声把电台挤停（用户回到音乐页按了播放）
      music.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isFalse);

      // 电台已在播 → 点播放键是「续播」：音乐必须再次让位，不能两路一起响
      await radio.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(tuned, 2, reason: '续播也必须走一遍「音乐让位」钩子');
      expect(music.value, isFalse);
      expect(radio.playing, isTrue);
      expect(engine.calls.last, 'play');
    });

    test('断流（playing 掉 false）会自动重连同一台，接上后仍在响', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        // 测试里不等真实退避（生产是 2/4/8/16 秒）
        reconnectDelay: (_) => Duration.zero,
      );
      addTearDown(radio.dispose);
      final station = _station('fm-beijing-traffic');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);

      // 上游掐连接：mpv 落 playing=false
      engine.emitPlaying(false);
      await Future<void>.delayed(Duration.zero);
      expect(radio.reconnecting, isTrue, reason: '断流后立刻进入「重连中」');
      expect(radio.playing, isFalse);

      // 定时器到点 → 重开同一条流 → 再 play
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.calls.sublist(engine.calls.length - 2), [
        'open:${station.streamUrl}',
        'play',
      ]);
      // Fake 的 play 会回一帧 playing=true
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isTrue);
      expect(radio.reconnecting, isFalse);
      expect(radio.current?.id, station.id, reason: '重连不换台');
    });

    test('流报 completed 也当断流处理（CDN 掐断常长这样）', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
      );
      addTearDown(radio.dispose);
      final station = _station('net-xiangsheng');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      final before = engine.calls.length;

      engine.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        engine.calls.length,
        greaterThan(before),
        reason: 'completed 之后要重开',
      );
      expect(
        engine.calls
            .where((call) => call == 'open:${station.streamUrl}')
            .length,
        2,
      );
    });

    test('用户自己按的暂停不触发重连', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
      );
      addTearDown(radio.dispose);
      final station = _station('fm-shanghai-101');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      await radio.toggle(); // 同台再点一次 = 暂停
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.calls.where((call) => call.startsWith('open:')).length, 1);
      expect(radio.reconnecting, isFalse);
      expect(radio.playing, isFalse);
    });

    test('pause：没在响也把待重连取消（定时结束后不许自己接回来）', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        // 给一个很长的退避：暂停必须在计时器到点之前把这一轮重连按掉
        reconnectDelay: (_) => const Duration(hours: 1),
      );
      addTearDown(radio.dispose);
      final station = _station('fm-beijing-traffic');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      // 断流：playing 掉 false，重连接下来才出声
      engine.emitPlaying(false);
      await Future<void>.delayed(Duration.zero);
      expect(radio.reconnecting, isTrue);

      // 睡眠定时器到点 / 音乐开声走的就是这个入口
      await radio.pause();

      expect(radio.reconnecting, isFalse, reason: '待重连必须被取消');
      expect(radio.playing, isFalse);
      expect(radio.current?.id, station.id, reason: '暂停保留当前台');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        1,
        reason: '暂停之后不许再开流',
      );
    });

    test('重连次数用尽落回「连不上」，不再无限重试', () async {
      final engine = FakeRadioEngine();
      var attempts = 0;
      final radio = RadioState(
        engine: engine,
        maxReconnects: 1,
        reconnectDelay: (_) {
          attempts++;
          return Duration.zero;
        },
      );
      addTearDown(radio.dispose);
      final station = _station('fm-guangdong-music');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);

      engine.failNextOpen = true;
      engine.emitPlaying(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(attempts, 1, reason: '只给一次额度');
      expect(radio.reconnecting, isFalse);
      expect(radio.error, isNotNull);
      expect(radio.errorMessage(), '这台暂时连不上，换一台试试');
    });

    test('卡在缓冲超过看门狗时限也会重开（不等 mpv 报错）', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
        // 生产是 12 秒；测试里压到毫秒级
        stallTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(radio.dispose);
      final station = _station('fm-beijing-music');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      final openedBefore = engine.calls
          .where((call) => call.startsWith('open:'))
          .length;

      // 上游把连接掐了，mpv 只停在 buffering 上，不给 error：
      // 先报 buffering 再落 playing=false —— `_loading` 会挡住常规重连路径，
      // 只有看门狗能把它捞起来。
      engine.emitLoading(true);
      engine.emitPlaying(false);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        openedBefore + 1,
        reason: '卡死的流要自己重开，不能一直转圈',
      );
      expect(radio.reconnecting, isFalse, reason: '重接连上就收掉「连接中」');
    });

    test('在播时 buffering 抖动不把播放键翻成转圈（播放头还在走）', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);

      await radio.tune(_station('fm-beijing-music'));
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isTrue);

      // 真出声了：播放头在走
      engine.emitPosition(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      // mpv 的 core-idle 在正常出声时也会报 buffering=true
      engine.emitLoading(true);
      await Future<void>.delayed(Duration.zero);
      expect(radio.loading, isFalse, reason: '声音还在往前走，播放键必须保持暂停图形，不能转圈');

      // 再抖一下也一样，直到真的没在响
      engine.emitLoading(false);
      engine.emitLoading(true);
      await Future<void>.delayed(Duration.zero);
      expect(radio.loading, isFalse);
    });

    test('播放头还没动时仍算「连接中」，位置一动就收掉', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);

      await radio.tune(_station('fm-shanghai-101'));
      await Future<void>.delayed(Duration.zero);

      // 起播后还没拿到第一帧位置：buffering 仍要交代「连接中」
      engine.emitLoading(true);
      await Future<void>.delayed(Duration.zero);
      expect(radio.loading, isTrue);

      engine.emitPosition(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(radio.loading, isFalse, reason: '位置一动就说明声音下来了');
    });

    test('在播时 buffering 抖动不会触发看门狗重开（播放头一直往前走）', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
        stallTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(radio.dispose);
      final station = _station('fm-beijing-music');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      final openedBefore = engine.calls
          .where((call) => call.startsWith('open:'))
          .length;

      engine.emitLoading(true);
      engine.emitPosition(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        openedBefore,
        reason: '播放头还在走就是活流，不能因为一条 buffering 就重开',
      );
    });

    test('真卡死（playing 仍为 true 但播放头不动）看门狗也会重开', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
        stallTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(radio.dispose);
      final station = _station('fm-guangdong-music');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      engine.emitPosition(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      final openedBefore = engine.calls
          .where((call) => call.startsWith('open:'))
          .length;

      // 上游断了：mpv 只停在 buffering 上，playing 还挂着 true
      engine.emitLoading(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        openedBefore + 1,
        reason: '播放头不动、只报 buffering 的流要自己重开',
      );
    });

    test('起播中按下暂停：连接中的转圈要收掉', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(engine: engine);
      addTearDown(radio.dispose);

      await radio.tune(_station('fm-jiangsu-classic'));
      await Future<void>.delayed(Duration.zero);
      engine.emitLoading(true);
      await Future<void>.delayed(Duration.zero);
      expect(radio.loading, isTrue);

      await radio.toggle(); // 暂停
      await Future<void>.delayed(Duration.zero);
      expect(radio.playing, isFalse);
      expect(radio.loading, isFalse, reason: '暂停后按钮该回到播放图形');
    });

    test('回到前台：没在响就立刻重接，不按退避等', () async {
      final engine = FakeRadioEngine();
      var delaysAsked = 0;
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) {
          delaysAsked++;
          // 故意给一个很长的退避：recover() 不该等它
          return const Duration(seconds: 30);
        },
      );
      addTearDown(radio.dispose);
      final station = _station('fm-shanghai-101');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);

      // 后台冻住：mpv 落 playing=false，同时还在 buffering（常规路径不重连）
      engine.emitLoading(true);
      engine.emitPlaying(false);
      await Future<void>.delayed(Duration.zero);

      radio.recover();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        2,
        reason: '回前台应立刻重开同一条流',
      );
      expect(delaysAsked, 0, reason: '不等退避，直接用 0 延时');
    });

    test('回到前台：用户自己按的暂停不该被重接推翻', () async {
      final engine = FakeRadioEngine();
      final radio = RadioState(
        engine: engine,
        reconnectDelay: (_) => Duration.zero,
      );
      addTearDown(radio.dispose);
      final station = _station('fm-guangdong-music');

      await radio.tune(station);
      await Future<void>.delayed(Duration.zero);
      await radio.toggle(); // 暂停

      radio.recover();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        engine.calls.where((call) => call.startsWith('open:')).length,
        1,
        reason: '用户按的暂停要留住',
      );
      expect(radio.playing, isFalse);
    });
  });

  group('迷你电台条', () {
    testWidgets('没有当前台时完全不占位', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: Scaffold(body: RadioBar(onOpen: () {})),
          ),
        ),
      );
      expect(find.byKey(const Key('radio-bar-open')), findsNothing);
    });

    testWidgets('后台在放时显示台名，三个动作各自生效', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await radio.tune(_station('fm-beijing-traffic'));
      await tester.pump();

      var opened = 0;
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: Scaffold(body: RadioBar(onOpen: () => opened++)),
          ),
        ),
      );

      expect(find.text('北京交通广播'), findsOneWidget);
      expect(find.text('FM103.9 · 北京'), findsOneWidget);

      // 点主体 → 回电台页
      await tester.tap(find.byKey(const Key('radio-bar-open')));
      expect(opened, 1);

      // 暂停
      await tester.tap(find.byKey(const Key('radio-bar-toggle')));
      await tester.pump();
      expect(radio.playing, isFalse);
      expect(radio.current?.id, 'fm-beijing-traffic');

      // 关闭
      await tester.tap(find.byKey(const Key('radio-bar-stop')));
      await tester.pump();
      expect(radio.current, isNull);
      expect(find.text('北京交通广播'), findsNothing);
    });
  });

  group('顶栏入口', () {
    testWidgets('桌面：电台按钮在「更多」左侧，点它进电台', (tester) async {
      _setViewport(tester, const Size(1200, 800));
      var opened = 0;
      await tester.pumpWidget(
        _themed(
          Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
              onOpenRadio: () => opened++,
            ),
          ),
        ),
      );

      expect(find.text('电台'), findsOneWidget);
      expect(find.text('更多'), findsOneWidget);
      // 位置：电台在更多左边
      final radioX = tester.getCenter(find.text('电台')).dx;
      final moreX = tester.getCenter(find.text('更多')).dx;
      expect(radioX, lessThan(moreX));

      await tester.tap(find.text('电台'));
      expect(opened, 1);
    });

    testWidgets('窄屏：只留图标，文案隐藏，按钮仍是 32×32 点击区', (tester) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        _themed(
          Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
              onOpenRadio: () {},
            ),
          ),
        ),
      );

      expect(find.text('电台'), findsNothing);
      final button = find.byKey(const Key('radio-button'));
      expect(button, findsOneWidget);
      expect(tester.getSize(button), const Size(32, 32));
    });
  });

  group('电台页', () {
    testWidgets('三个页签都在，缺省落在音乐台，卡片写着所属分类', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      // 页签：短名 + 台数
      for (final tab in radioTabs()) {
        final chip = find.byKey(
          Key('radio-tab-${tab.id.name}'),
          skipOffstage: false,
        );
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text(tab.label)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: chip,
            matching: find.text('${radioStationsOf(tab.id).length}'),
          ),
          findsOneWidget,
        );
      }

      // 缺省：音乐台 8 行，交通台的行不在
      expect(
        find.byKey(const Key('radio-row-fm-beijing-music')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('radio-row-fm-beijing-traffic')),
        findsNothing,
      );
      // 卡片上写的是第一台 + 它的所属分类
      expect(find.text('传统 FM · 音乐台'), findsOneWidget);
    });

    testWidgets('切到交通台：台表换掉，页签仍只有一行', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('radio-tab-traffic')));
      await tester.pump();

      expect(
        find.byKey(const Key('radio-row-fm-beijing-traffic')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('radio-row-fm-beijing-music')), findsNothing);
      expect(find.text('北京交通广播'), findsOneWidget);
    });

    testWidgets('左右滑页签：左滑翻到下一页，右滑退回，到头不动', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      // 音乐台是最左一页：右滑没有上一页，原地不动
      await tester.drag(
        find.byKey(const Key('radio-tab-music')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('radio-row-fm-beijing-music')),
        findsOneWidget,
      );

      // 左滑 → 交通台
      await tester.drag(
        find.byKey(const Key('radio-tab-music')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('radio-row-fm-beijing-traffic')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('radio-row-fm-beijing-music')), findsNothing);

      // 右滑 → 回音乐台
      await tester.drag(
        find.byKey(const Key('radio-tab-traffic')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('radio-row-fm-beijing-music')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('radio-row-fm-beijing-traffic')),
        findsNothing,
      );
    });

    testWidgets('竖滑只滚页面，不切页签', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      await tester.drag(
        find.byKey(const Key('radio-row-fm-beijing-music')),
        const Offset(0, 160),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('radio-row-fm-beijing-music')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('radio-row-fm-beijing-traffic')),
        findsNothing,
      );
    });

    testWidgets('页面上下滚动，右上角三颗跟着页头进出视口', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      final actions = find.byKey(const Key('radio-head-actions'));
      final back = find.byKey(const Key('radio-back-button'));
      expect(actions, findsOneWidget);
      expect(back.hitTestable(), findsOneWidget);

      // 页面滚动条走软回弹：触底那一跳被压浅、放慢（见 scroll_physics.dart）。
      expect(
        tester
            .widget<SingleChildScrollView>(
              find.byKey(const Key('radio-scroll')),
            )
            .physics,
        isA<SoftBouncingScrollPhysics>(),
      );

      // 往上滑：页头整行滚出视口，三颗跟着走 —— 它们是页头里的普通内容，
      // 不是浮在视口右上角的常驻工具条，也不做「上滑隐藏 / 下滑显示」。
      await tester.drag(
        find.byKey(const Key('radio-scroll')),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      expect(actions, findsOneWidget);
      expect(back.hitTestable(), findsNothing);

      // 往下滑：页头滚回来，三颗重新看得见
      await tester.drag(
        find.byKey(const Key('radio-scroll')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(back.hitTestable(), findsOneWidget);
    });

    testWidgets('点一行开播：卡片换成这台，所属分类跟着换', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('radio-tab-traffic')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('radio-row-fm-beijing-traffic')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(radio.current?.id, 'fm-beijing-traffic');
      expect(find.text('正在收听'), findsOneWidget);
      expect(find.text('传统 FM · 交通台'), findsOneWidget);
      expect(find.text('FM103.9 · 北京'), findsWidgets);
    });

    testWidgets('在播那一行的均衡柱原地律动：柱子变高，整颗图标不上下漂', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await radio.tune(_station('fm-beijing-traffic'));
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );
      await tester.pump();

      final eq = find.byKey(const Key('radio-eq'));
      // 只有在播那一行才有这根柱子
      expect(eq, findsOneWidget);
      final bars = find.descendant(of: eq, matching: find.byType(Container));
      expect(bars, findsNWidgets(3));

      // 连采几帧：柱子本身要还在起伏，图标外框的上下沿则一帧都不许动。
      final tops = <double>[];
      final bottoms = <double>[];
      final boxHeights = <double>[];
      final heights = <double>[];
      for (var frame = 0; frame < 6; frame++) {
        final box = tester.getRect(eq);
        tops.add(box.top);
        bottoms.add(box.bottom);
        boxHeights.add(box.height);
        heights.add(tester.getSize(bars.at(2)).height);
        await tester.pump(const Duration(milliseconds: 180));
      }

      double spread(List<double> values) =>
          values.reduce(math.max) - values.reduce(math.min);

      // 柱子仍在跳（不是一根静态柱子）
      expect(spread(heights), greaterThan(1.5));
      // 底边钉住、外框不跟着长高：律动只发生在原地，不带着整颗图标上下漂
      expect(spread(tops), lessThan(0.01));
      expect(spread(bottoms), lessThan(0.01));
      expect(spread(boxHeights), lessThan(0.01));
    });

    testWidgets('大卡水波：在播时一圈圈外扩，暂停就冻在原地', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      // 先切到交通台并等换页动画（240ms）走完：等下在播的是音乐台，
      // 那一行被筛掉，页面上就只剩大卡的扩散环还在跑。
      await tester.tap(find.byKey(const Key('radio-tab-traffic')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.binding.transientCallbackCount, 0);

      await radio.tune(_station('fm-beijing-music'));
      await tester.pump();
      // 环跑起来了：每秒都在请求下一帧
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      // 暂停：相位留在原地，不再有新帧。先让「静止环→水波」的 0.36s
      // 交替跑完，剩下的帧只可能来自还在循环的水波。
      await radio.toggle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: '暂停后水波要冻住，不能继续偷偷跑',
      );
    });

    testWidgets('窄屏：版式不溢出，切页签照常', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // 右上角「更多」：窄屏收成 32×32 的透明 ⋯（与顶栏那颗同一套规矩）
      expect(
        tester.getSize(find.byKey(const Key('menu-button'))),
        const Size(32, 32),
      );
      await tester.tap(find.byKey(const Key('radio-tab-net')));
      await tester.pump();
      expect(find.byKey(const Key('radio-row-net-classical')), findsOneWidget);
    });

    testWidgets('右上角「休眠」互跳：挨着「音乐」，点它去休眠页', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      var opened = 0;

      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}, onOpenSleep: () => opened++),
          ),
        ),
      );

      final sleepChip = find.byKey(const Key('radio-sleep-button'));
      expect(sleepChip, findsOneWidget);
      expect(find.text('助眠'), findsOneWidget);
      // 桌面：与「音乐」回退同一档 36px 胶囊，排它在左边
      expect(tester.getSize(sleepChip).height, 36);
      final tokens = tester.element(sleepChip).tokens;
      expect(tester.widget<Text>(find.text('助眠')).style?.color, tokens.text);
      expect(tester.widget<Text>(find.text('音乐')).style?.color, tokens.text);
      expect(
        tester.widget<SleepMoonIcon>(find.byType(SleepMoonIcon).first).color,
        tokens.text,
      );
      final note = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('radio-back-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((note.painter! as MusicNotePainter).color, tokens.text);
      expect(
        tester.getCenter(sleepChip).dx,
        lessThan(
          tester.getCenter(find.byKey(const Key('radio-back-button'))).dx,
        ),
      );

      await tester.tap(sleepChip);
      expect(opened, 1);
    });

    testWidgets('窄屏：休眠 / 音乐 / 更多三颗各 32×32，按 8px 自右向左排', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);

      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}, onOpenSleep: () {}),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // 与 Web 的 right: 90 / 50 / 10 同构（390 - 16 内缩 + 6 只挪绘制）
      // 纵向 = 三页统一口径：按钮上缘 12（图标中心 28）
      expect(
        tester.getRect(find.byKey(const Key('radio-sleep-button'))),
        const Rect.fromLTWH(268, 12, 32, 32),
      );
      expect(
        tester.getRect(find.byKey(const Key('radio-back-button'))),
        const Rect.fromLTWH(308, 12, 32, 32),
      );
      expect(
        tester.getRect(find.byKey(const Key('menu-button'))),
        const Rect.fromLTWH(348, 12, 32, 32),
      );
      final tokens = tester.element(find.byType(RadioPage)).tokens;
      expect(
        tester.widget<SleepMoonIcon>(find.byType(SleepMoonIcon).first).color,
        tokens.textDim,
      );
      final note = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('radio-back-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((note.painter! as MusicNotePainter).color, tokens.textDim);
    });

    testWidgets('窄屏：右上角三颗与音乐页顶栏同一条水平线（上缘 12、图标中心 28）', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () {}),
          ),
        ),
      );

      // 横向落位仍与音乐页顶栏同源：右内缩 10、点击区 32、两颗之间 8
      // （「音乐」落在 308，「更多」落在 348）。
      // 竖直方向不再跟品牌块居中（品牌中心 32），而是与音乐页、休眠页一样
      // 钉在**按钮上缘 12、图标中心 28** —— 三页切来切去这一排图标不上下跳。
      expect(
        tester.getRect(find.byKey(const Key('radio-back-button'))),
        const Rect.fromLTWH(308, 12, 32, 32),
      );
      expect(
        tester.getRect(find.byKey(const Key('menu-button'))),
        const Rect.fromLTWH(348, 12, 32, 32),
      );
      expect(
        tester.getCenter(find.byKey(const Key('radio-back-button'))).dy,
        28,
      );
    });

    testWidgets('右上角「更多」里能进换肤，不用回音乐页', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      final theme = await ThemeState.load(AppPrefs.inMemory());
      addTearDown(theme.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RadioState>.value(value: radio),
            ChangeNotifierProvider<ThemeState>.value(value: theme),
          ],
          child: MaterialApp(
            theme: buildTheme().copyWith(
              extensions: const [AppTokensData(tokens: AppTokens.dark)],
            ),
            home: RadioPage(onBack: () {}),
          ),
        ),
      );

      // 桌面：与「音乐」回退胶囊同档的 36px 胶囊
      final menu = find.byKey(const Key('menu-button'));
      expect(menu, findsOneWidget);
      expect(tester.getSize(menu).height, 36);
      expect(find.text('更多'), findsOneWidget);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.byType(DrawerMenu), findsOneWidget);
      expect(find.text('换肤'), findsOneWidget);
      // 电台页的「更多」不掺曲库操作：添加 / 清空两条都不出现
      expect(find.text('添加音乐'), findsNothing);
      expect(find.text('添加整个文件夹'), findsNothing);
      expect(find.text('清空播放列表'), findsNothing);

      // 换肤是二级抽屉：一级先收完再弹二级
      await tester.tap(find.text('换肤'));
      await tester.pumpAndSettle();
      expect(find.byType(ThemeDrawer), findsOneWidget);
      expect(find.text('主题色'), findsOneWidget);
      expect(find.byType(DrawerMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「音乐」按钮回音乐播放器', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final radio = RadioState(engine: FakeRadioEngine());
      addTearDown(radio.dispose);
      var back = 0;
      await tester.pumpWidget(
        _themed(
          ChangeNotifierProvider<RadioState>.value(
            value: radio,
            child: RadioPage(onBack: () => back++),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('radio-back-button')));
      expect(back, 1);
    });
  });
}
