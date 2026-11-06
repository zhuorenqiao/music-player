// test/playback/audio_player_volume_test.dart
//
// 锁住原版 #lastVolume 的语义：音量 0 视为静音但不忘记忆值，
// 取消静音时恢复上一次（默认 0.7 而不是 0）。
// 并对齐 player.js:315-324：setVolume 的**两个分支都清 muted**（终审 R5），
// 只有 v > 0 那支额外记 lastVolume。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';

void main() {
  test('音量拖到 0 不改静音标志，读数仍是 0；静音往返恢复记忆音量', () async {
    final player = AudioPlayer(FakeAudioDriver());
    await player.setVolume(0.42);
    expect(player.volume, closeTo(0.42, 0.001));
    // 原版 setVolume(0) 的 else 分支只是 muted = false，不动「静音态」语义
    await player.setVolume(0);
    expect(player.muted, isFalse);
    expect(player.volume, 0);
    // UI 判图标只看 volume：0 就是静音外观，与 muted 标志无关
    expect(player.volume == 0, isTrue);
    // 静音一次再取消：恢复记忆值 0.42，而不是默认 0.7
    expect(await player.toggleMute(), isTrue);
    expect(player.volume, 0);
    expect(await player.toggleMute(), isFalse);
    expect(player.volume, closeTo(0.42, 0.001));
  });

  test('toggleMute 往返恢复原音量', () async {
    final driver = FakeAudioDriver();
    final player = AudioPlayer(driver);
    await player.setVolume(0.62);
    expect(await player.toggleMute(), isTrue);
    expect(player.muted, isTrue);
    expect(await player.toggleMute(), isFalse);
    expect(player.volume, closeTo(0.62, 0.001));
    expect(driver.calls, contains('volume:0.62'));
  });

  test('默认音量 0.7，静音后取消恢复默认而非 0', () async {
    final player = AudioPlayer(FakeAudioDriver());
    expect(player.volume, 0.7);
    await player.setMuted(true);
    await player.setMuted(false);
    expect(player.volume, greaterThan(0));

    // 记忆值 0.42：静音往返不该回落到默认 0.7
    await player.setVolume(0.42);
    await player.toggleMute();
    await player.toggleMute();
    expect(player.volume, closeTo(0.42, 0.001));

    // 真走到 `_volume == 0` 的恢复分支：setVolume(0) 后静音再取消
    await player.setVolume(0);
    expect(player.muted, isFalse);
    await player.toggleMute();
    expect(player.muted, isTrue);
    await player.toggleMute();
    expect(player.volume, closeTo(0.42, 0.001));
  });

  /// 终审 R5：原版的 else 分支同样写 `muted = false`（`src/lib/player.js:322`），
  /// 所以「静音中拖到 0」出来就是「音量 0、没静音」，而记忆音量仍然留着。
  /// 上面那条用例走的是未静音的状态，看不见这一支。
  test('静音中拖到 0：muted 清掉、音量留 0、记忆值不动', () async {
    final player = AudioPlayer(FakeAudioDriver());
    await player.setVolume(0.42);
    expect(await player.toggleMute(), isTrue);
    expect(player.muted, isTrue);
    expect(player.volume, 0);

    await player.setVolume(0);
    expect(player.muted, isFalse, reason: 'player.js:322 的 else 分支也清静音');
    expect(player.volume, 0);

    // lastVolume 只在 v > 0 那支更新：静音往返仍回到 0.42
    await player.toggleMute();
    await player.toggleMute();
    expect(player.volume, closeTo(0.42, 0.001));
  });

  test('从未设过音量时静音往返回落到默认 0.7', () async {
    final player = AudioPlayer(FakeAudioDriver());
    await player.toggleMute();
    await player.toggleMute();
    expect(player.volume, closeTo(0.7, 0.001));
  });
}
