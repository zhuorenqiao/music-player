// test/core/shortcuts_test.dart
//
// 桌面快捷键层（T30 + 终审 I5）：对译 `src/App.tsx:1582-1655` 的键盘 effect 与
// README 的「快捷键」表（空格播放/暂停、←→ ±5 秒、↑↓ ±5%、M 静音、
// N 下一首、P 上一首）。
//
// 四条规则各占一条用例，全程用**记录型假回调**断言，不碰音频内核也不建真播放器
// （真 PlayerState 的接线在 test/integration/m1_smoke_test.dart 里跑）：
//   1. 八组键各自触发正确的动作与正确的步长；
//   2. 输入框聚焦时整套让位（原版 `tag === 'INPUT' || 'TEXTAREA' || 'SELECT'`，
//      N / P 靠的就是这一条：搜索框里打 n 不该切歌）；
//   3. 滑块聚焦时方向键由滑块自己处理，绝不双触发（原版 `isRange` 分支）；
//   4. 空格被本层消费 —— 等价于原版的 `preventDefault()`，所以列表不会被顶下去。
//
// 媒体键（Play/Pause、NextTrack、PrevTrack）由 MediaSessionBridge 负责
// （T21/T22），这里不重复注册；`L` / `Escape` 属歌词页（M2），也不在表内 ——
// 第 1 条用例把这两件事一起钉住，免得后人「顺手加回来」。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/shortcuts.dart';

/// 记录用的假回调：`name` 或 `name:arg`，顺序即调用顺序。
void Function(String name, [Object? arg]) recorder(List<String> sink) =>
    (String name, [Object? arg]) => sink.add(arg == null ? name : '$name:$arg');

/// 把 [child] 装进「快捷键层 + MaterialApp」的最小宿主。
Future<void> pumpHost(
  WidgetTester tester,
  List<String> calls,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: withAppShortcuts(
        playerCallback: recorder(calls),
        child: Scaffold(body: child),
      ),
    ),
  );
  // 一帧：快捷键宿主把自己设为焦点（宿主自聚焦，才不依赖「恰好有控件被点到」）
  await tester.pump();
}

/// 表里某个键映射到的 Intent（没有则 null）。
Intent? intentOf(LogicalKeyboardKey key) {
  for (final entry in kLightMusicShortcuts.entries) {
    final activator = entry.key;
    if (activator is SingleActivator && activator.trigger == key) {
      return entry.value;
    }
  }
  return null;
}

void main() {
  test('快捷键表覆盖十组键，且不抢媒体键（L / Esc 已由 T19 接上）', () {
    final pressed = kLightMusicShortcuts.keys
        .map(
          (activator) =>
              activator is SingleActivator ? activator.trigger : null,
        )
        .toSet();

    expect(
      pressed,
      <LogicalKeyboardKey>{
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.keyM,
        // 终审 I5：原版 `src/App.tsx:1639-1645` 的 N / P 两张牌此前漏移植
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyP,
        // T19（parity 校正）：M1 时这里断言「不注册」，理由是「歌词页两个键属
        // M2，注册了就会和未来的歌词页抢按键」。M2a 的歌词页落地后该理由不再
        // 成立，原版确实把两张牌都吃在同一张表里：
        //   * `src/App.tsx:1646-1648` `case 'KeyL': setLyricsPage(v => !v)`；
        //   * `src/App.tsx:1600-1604` `event.key === 'Escape' && lyricsPage`
        //     → `setLyricsPage(false)`。
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.escape,
      },
    );
    // 播放/上下曲由系统媒体会话（T21/T22）负责，不在键盘层重复
    expect(pressed, isNot(contains(LogicalKeyboardKey.mediaPlayPause)));
    expect(pressed, isNot(contains(LogicalKeyboardKey.mediaTrackNext)));
    expect(pressed, isNot(contains(LogicalKeyboardKey.mediaTrackPrevious)));
    // N / P 与静音的 M 不冲突：三张牌各指各的动作
    expect(intentOf(LogicalKeyboardKey.keyM), isA<ToggleMuteIntent>());
    expect(intentOf(LogicalKeyboardKey.keyN), isNot(intentOf(LogicalKeyboardKey.keyM)));
    // T19：L 开合歌词页、Esc 关层，两者是**不同的** Intent（Esc 不 toggle）
    expect(intentOf(LogicalKeyboardKey.keyL), isA<ToggleLyricsPageIntent>());
    expect(intentOf(LogicalKeyboardKey.escape), isA<CloseOverlayIntent>());
    expect(
      intentOf(LogicalKeyboardKey.escape),
      isNot(intentOf(LogicalKeyboardKey.keyL)),
    );
  });

  test('八个 Intent 的步长与 README 一致：±5 秒 / ±5%', () {
    expect(kSeekStep, 5);
    expect(kVolumeStep, 0.05);
    expect(intentOf(LogicalKeyboardKey.space), isA<TogglePlayIntent>());
    expect(intentOf(LogicalKeyboardKey.keyM), isA<ToggleMuteIntent>());
    expect(intentOf(LogicalKeyboardKey.keyN), isA<PlayNextIntent>());
    expect(intentOf(LogicalKeyboardKey.keyP), isA<PlayPrevIntent>());
    expect((intentOf(LogicalKeyboardKey.arrowLeft)! as SeekByIntent).delta, -5);
    expect((intentOf(LogicalKeyboardKey.arrowRight)! as SeekByIntent).delta, 5);
    expect(
      (intentOf(LogicalKeyboardKey.arrowUp)! as VolumeByIntent).delta,
      closeTo(0.05, 1e-12),
    );
    expect(
      (intentOf(LogicalKeyboardKey.arrowDown)! as VolumeByIntent).delta,
      closeTo(-0.05, 1e-12),
    );
  });

  testWidgets('空格切播放、左右 ±5 秒、上下 ±5%、M 静音', (tester) async {
    final calls = <String>[];
    //  body 里没有任何可聚焦控件：能触发就说明宿主自己接住了焦点
    await pumpHost(tester, calls, const Text('x'));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);

    expect(calls, [
      'togglePlay',
      'seekBy:5.0',
      'seekBy:-5.0',
      'volumeBy:0.05',
      'volumeBy:-0.05',
      'toggleMute',
    ]);
  });

  // 终审 I5：N = 下一首、P = 上一首（原版 `case 'KeyN': playNext()` /
  // `case 'KeyP': playPrev()`）。名字与界面层派发给 PlayerState 的动作一致。
  testWidgets('N 下一首、P 上一首', (tester) async {
    final calls = <String>[];
    await pumpHost(tester, calls, const Text('x'));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);

    expect(calls, ['playNext', 'playPrev', 'playNext']);
  });

  testWidgets('输入框聚焦时快捷键全部让位', (tester) async {
    final calls = <String>[];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pumpHost(tester, calls, TextField(controller: controller));

    // 点进去 = 真焦点落在文本框上（与原版 event.target 是 INPUT 同一情形）
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    // 终审 I5 那条硬要求：面板搜索框正在输入 n / p 时不许切歌
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);

    expect(calls, isEmpty);
  });

  testWidgets('滑块聚焦时方向键交回原生，不双触发', (tester) async {
    final calls = <String>[];
    var sliderValue = 0.3;
    final captured = <double>[];
    await pumpHost(
      tester,
      calls,
      StatefulBuilder(
        builder:
            (context, setState) => Slider(
              value: sliderValue,
              onChanged: (next) {
                captured.add(next);
                setState(() => sliderValue = next);
              },
            ),
      ),
    );

    // Tab 进滑块 = 键盘焦点落在 Slider 里（原版 target 是 input[type=range] 那格）
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    // 滑块自己走了一步（原生方向键生效），而我们的音量快捷键一次都没触发：
    // Slider 自带的 Shortcuts 在焦点链的更下游，事件根本传不到这一层。
    expect(captured, isNotEmpty);
    expect(sliderValue, greaterThan(0.3));
    expect(calls, isEmpty);
  });

  testWidgets('空格被快捷键层消费，列表不滚动', (tester) async {
    final calls = <String>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pumpHost(
      tester,
      calls,
      ListView(
        controller: scroll,
        shrinkWrap: true,
        children: [
          for (var i = 0; i < 40; i++)
            SizedBox(height: 200, child: Text('行 $i', key: Key('row-$i'))),
        ],
      ),
    );

    // sendKeyEvent 返回 true = 事件被吃掉，正是原版 preventDefault 的等价物
    for (var i = 0; i < 3; i++) {
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isTrue);
      await tester.pump();
    }

    expect(calls, ['togglePlay', 'togglePlay', 'togglePlay']);
    expect(scroll.offset, 0);
  });

  testWidgets('焦点在按钮上时空格交给按钮本身（与原版 BUTTON/A 分支一致）', (
    tester,
  ) async {
    final calls = <String>[];
    var activations = 0;
    await pumpHost(
      tester,
      calls,
      Center(
        child: InkWell(
          key: const Key('probe-button'),
          onTap: () => activations++,
          child: const SizedBox(width: 80, height: 40, child: Text('按钮')),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(activations, 0);

    // 空格不再走我们的快捷键，而是激活那颗聚焦中的按钮（原生 ActivateIntent）
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(calls, isEmpty);
    expect(activations, 1);
  });
}
