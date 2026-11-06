// test/ui/autoplay_gate_test.dart
//
// 被自动播放策略拦住后的「任意手势重试」（终审 I5）。
//
// 原版有两条 document 级监听（`src/App.tsx:1557-1579`，捕获阶段）：一次
// pointerdown 或一次非空格/回车的 keydown 都调 `resumeAutoplay()` —— 浏览器只
// 要用户真实交互过一次就肯再让播放。我们此前只在面板那条「继续播放」按钮上接
// 了 `userGesture()`，用户在空白处点半天也不会恢复。
//
// 这里的宿主是真的 [PlayerState] + [TransportController] + [FakeAudioDriver]：
// 先用 `playThrows` 把播放打成 blocked，再验「点一下 / 按一下」真的补了一次
// 原地续播，并且重试次数仍受 `kMaxAutoplayRetries` 约束。
//
// 沿用 test/ui 的规矩：不 `pumpAndSettle`、不 `pumpEventQueue`（testWidgets 跑在
// FakeAsync 里，后者会永远等不到头），推帧用 `pump(Duration)`。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/shortcuts.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/autoplay_gate.dart';
import 'package:light_music/ui/transport.dart';
import 'package:provider/provider.dart';

Track t(String id) =>
    Track(id: id, src: '/$id.flac', title: '歌$id', duration: 100);

/// 每次 play() 都抛 NotAllowedError 的内核：等价浏览器的 autoplay block。
FakeAudioDriver blockedDriver() =>
    FakeAudioDriver()..playThrows = StateError('NotAllowedError: play blocked');

PlayerState buildPlayer(FakeAudioDriver driver, Playlist playlist) =>
    PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(driver),
        recent: const _NoRecent(),
        toasts: const _NoToasts(),
        playlist: playlist,
      ),
    );

/// 快捷键动作的默认去向：什么都不做（与原有用例一致）。
void _discardAction(String name, [Object? arg]) {}

/// 把网关宿主装进最小应用：网关包住快捷键层（与 `app.dart` 的装配同序），
/// 于是按键既走快捷键表，也一定被网关记一次。
///
/// [onAction] 用来观察「快捷键表有没有真的收到这一键」——网关只许旁听，
/// 不许把键吃掉。
Future<void> pumpGate(
  WidgetTester tester,
  PlayerState player, {
  Widget child = const SizedBox(width: 400, height: 300),
  ShortcutCallback onAction = _discardAction,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<PlayerState>.value(
        value: player,
        child: AutoplayGestureGate(
          child: withAppShortcuts(
            playerCallback: onAction,
            child: Scaffold(body: Center(child: child)),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
}

/// 与 [pumpGate] 同一套装配，但视口给到桌面档、内容换成真控制条 / 输入框，
/// 并且主题里挂上 `AppTokensData`（`TransportBar` 读 `context.tokens`）。
Future<void> pumpGateApp(
  WidgetTester tester,
  PlayerState player, {
  required Widget child,
  ShortcutCallback onAction = _discardAction,
}) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 400);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: ChangeNotifierProvider<PlayerState>.value(
        value: player,
        child: AutoplayGestureGate(
          child: withAppShortcuts(
            playerCallback: onAction,
            child: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
}

/// 一帧一帧推假时钟：驱动事件是微任务，`pump` 之间自然被排干。
Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 把播放器真的打成 blocked。
Future<void> enterBlocked(WidgetTester tester, PlayerState player) async {
  await player.playTrack('1');
  await settle(tester);
  expect(player.blockedMessage, isNotNull);
}

void main() {
  testWidgets('blocked 状态下点一下空白就重试一次', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1'), t('2')]));
    addTearDown(player.dispose);
    await pumpGate(tester, player);
    await enterBlocked(tester, player);

    driver.calls.clear();
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);

    expect(driver.calls, contains('play'), reason: '手势要真的再拉一次播放');
    expect(
      driver.calls.where((call) => call.startsWith('open:')),
      isEmpty,
      reason: '重试是原地续播，不许重新换源',
    );
  });

  testWidgets('没被拦时点空白什么都不做', (tester) async {
    final driver = FakeAudioDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1')]));
    addTearDown(player.dispose);
    await pumpGate(tester, player);

    await player.playTrack('1');
    await settle(tester);
    expect(player.blockedMessage, isNull);
    driver.calls.clear();

    await tester.tapAt(const Offset(20, 20));
    await settle(tester);

    expect(driver.calls, isEmpty);
  });

  testWidgets('重试仍受上限约束：用完 3 次就不再碰内核', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1')]));
    addTearDown(player.dispose);
    await pumpGate(tester, player);
    await enterBlocked(tester, player);

    driver.calls.clear();
    for (var i = 0; i < 6; i++) {
      await tester.tapAt(const Offset(20, 20));
      await settle(tester);
    }

    expect(
      driver.calls.where((call) => call == 'play').length,
      kMaxAutoplayRetries,
      reason: '任意手势也不许无限打转（原版 MAX_AUTOPLAY_RETRIES 同一档）',
    );
    expect(player.blockedMessage, isNotNull);
  });

  /// 终审 R3：第 1 轮那批用例全用「永远抛错的驱动」，所以看不见另一半 ——
  /// **重试成功**的那一次。原版 `resumeAutoplay()`（`src/state/player.tsx:193-215`）
  /// 在 `player.play()` 返回真值时 `clearPendingAutoplay()` + `hideNotice()`，
  /// 于是「用户点了一下空白，歌响了，横幅还挂着」这个画面在原版是不存在的。
  testWidgets('空白手势成功出声后提示条消失', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1')]));
    addTearDown(player.dispose);
    await pumpGate(tester, player);
    await enterBlocked(tester, player);

    // 「第一次 blocked、第二次成功」：把驱动恢复正常，等价浏览器在真实交互
    // 之后放行自动播放。
    driver.playThrows = null;
    driver.calls.clear();

    var viewNotifications = 0;
    player.view.addListener(() => viewNotifications++);

    await tester.tapAt(const Offset(20, 20));
    await settle(tester);

    expect(driver.calls, contains('play'), reason: '手势真的重试了一次');
    expect(player.playing, isTrue, reason: '这一次出声了');
    expect(
      player.blockedMessage,
      isNull,
      reason: '成功出声即 hideNotice：横幅文案不能留着（终审 R3）',
    );
    expect(
      player.view.value.blocked,
      isNull,
      reason: '界面读的是视图快照，快照里的 blocked 也要一起收掉',
    );
    expect(
      viewNotifications,
      greaterThan(0),
      reason: '收横幅是一次语义变化，必须 publish 给订阅了 view 的界面',
    );

    // 额度跟着复位（原版同一句 `clearPendingAutoplay()` 里连
    // `autoplayAttempts = 0` 一起做掉）。这里没有可观察的第二次「被拦」：
    // 所有能重新置上 blocked 的路径（playTrack / resume）自己就先复位了，
    // 所以这条只能验「成功之后不再有新的重试」——空白手势从此是空转。
    driver.calls.clear();
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    expect(
      driver.calls,
      isEmpty,
      reason: '横幅已收，后续手势不该再碰内核（userGesture 的前置判据就是它）',
    );
  });

  /// 终审 R7 之一（真正红的那条）：原版的两条监听挂在 `document` 上而且是
  /// **捕获阶段**（`src/App.tsx:1573-1574`），先记一次手势再让下层处理。
  /// 第 1 轮的网关只是焦点树的**祖先**，而按键是自下而上写的：位于它下游的
  /// `AppShortcuts` 一旦消费掉这一下，网关一次也收不到。
  ///
  /// 这里用 `M`（静音）：快捷键表真的把它消费掉了，而静音不碰播放，所以
  /// 「有没有记这一次手势」只能从内核有没有被再拉一次看出来。
  testWidgets('按键被快捷键层消费时仍算一次手势', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1')]));
    addTearDown(player.dispose);
    final actions = <String>[];
    await pumpGate(
      tester,
      player,
      onAction: (name, [arg]) => actions.add(name),
    );
    await enterBlocked(tester, player);

    driver.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await settle(tester);

    expect(
      actions,
      ['toggleMute'],
      reason: '静音照常生效：网关只旁听，绝不把这一下抢走',
    );
    expect(
      driver.calls,
      contains('play'),
      reason: '被快捷键层吃掉的按键同样是一次真实交互（原版 document 捕获阶段）',
    );
  });

  /// 终审 R7 的另一半，也是原版注释点名的场景：搜索框里打字母时快捷键整套让位
  /// （`tag === 'INPUT'`），这一键归文本输入。网关换成全局按键入口之后两种
  /// 情况都照样记一次手势 —— 这条同时把「输入框确实吃掉了这一下」钉住。
  testWidgets('快捷键被输入框吃掉时仍算一次手势', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1'), t('2')]));
    addTearDown(player.dispose);
    final controller = TextEditingController(text: '周杰')
      ..selection = const TextSelection.collapsed(offset: 2);
    addTearDown(controller.dispose);
    await pumpGateApp(tester, player, child: TextField(controller: controller));

    // 先把焦点真的落进输入框（与用户点搜索框同一动作），再让首播被拦
    await tester.tap(find.byType(TextField));
    await settle(tester);
    await enterBlocked(tester, player);

    driver.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await settle(tester);

    expect(
      driver.calls.where((call) => call.startsWith('open:')),
      isEmpty,
      reason: '搜索框里打 n 不切歌：快捷键表在文本焦点里整套让位',
    );
    expect(
      driver.calls,
      contains('play'),
      reason: '但这一次交互照样算一次手势，被拦的播放要能因此被拉起来',
    );
    expect(controller.text, '周杰', reason: '网关只旁听：输入框一个字没变');
  });

  /// 终审 R7 之二：原版 pointerdown 里那句
  /// `if (target.closest('.btn--play, .panel__list')) return;`（`src/App.tsx:1562`）
  /// 排除的就是「自己就会发起播放的那两块」——注释写得很清楚：
  /// 「交给它们，别互相打断」。移植时把这块判据丢了，于是点一次播放按钮
  /// 花掉两格：pointer-down 一次重试、pointer-up 后按钮自己再一次。
  testWidgets('点播放按钮只花一次重试额度', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1'), t('2')]));
    addTearDown(player.dispose);
    await pumpGateApp(tester, player, child: const TransportBar());
    await enterBlocked(tester, player);

    driver.calls.clear();
    await tester.tap(find.byKey(const Key('btn-play')));
    await settle(tester);

    expect(
      driver.calls.where((call) => call == 'play').length,
      1,
      reason: '只有按钮那一次真的播放；pointer-down 那一下不该再补一次重试',
    );
    expect(
      driver.calls.where((call) => call.startsWith('open:')),
      isEmpty,
      reason: '两条路都是原地续播，谁都不许重新换源',
    );
    // `PlayerState.togglePlay` 会排一次 400ms 防抖落盘：等它自己跑完，
    // 别把定时器留给下一个用例（fake 时钟会报「still pending」）。
    await tester.pump(const Duration(milliseconds: kPersistDebounceMs + 100));
  });

  testWidgets('键盘也算一次手势，但空格与回车让给按钮本身', (tester) async {
    final driver = blockedDriver();
    final player = buildPlayer(driver, Playlist.fromTracks([t('1')]));
    addTearDown(player.dispose);
    await pumpGate(tester, player);
    await enterBlocked(tester, player);

    driver.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await settle(tester);
    expect(driver.calls, contains('play'), reason: '任意按键都算真实交互');

    driver.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(
      driver.calls.where((call) => call == 'play').length,
      0,
      reason: '空格会触发按钮自己的 click，原版明确让开，这里不许双触发',
    );

    driver.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(
      driver.calls.where((call) => call == 'play').length,
      0,
      reason: '同空格：回车属于聚焦中的控件',
    );
  });
}

/// 不记最近播放。
class _NoRecent implements RecentRecorder {
  const _NoRecent();

  @override
  void record(Track track, {DateTime? at}) {}
}

/// 吞掉全部提示：这条链路只关心内核有没有被碰（也才不给测试留常驻计时器）。
class _NoToasts implements ToastSink {
  const _NoToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message) {}
}
