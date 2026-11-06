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
import 'package:light_music/ui/autoplay_gate.dart';
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

/// 把网关宿主装进最小应用：网关在快捷键层之上（与 `app.dart` 的装配同序），
/// 于是按键既走快捷键表，也一定冒泡到网关。
Future<void> pumpGate(
  WidgetTester tester,
  PlayerState player, {
  Widget child = const SizedBox(width: 400, height: 300),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<PlayerState>.value(
        value: player,
        child: AutoplayGestureGate(
          child: withAppShortcuts(
            playerCallback: (name, [arg]) {},
            child: Scaffold(body: Center(child: child)),
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
