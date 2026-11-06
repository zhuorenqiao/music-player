// test/playback/audio_player_volume_test.dart
//
// 锁住原版 #lastVolume 的语义：音量 0 视为静音但不忘记忆值，
// 取消静音时恢复上一次（默认 0.7 而不是 0）。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';

void main() {
  test('setVolume(0) 判静音但保留记忆音量', () async {
    final player = AudioPlayer(FakeAudioDriver());
    await player.setVolume(0.4);
    expect(player.volume, 0.4);
    await player.setVolume(0);
    expect(player.muted, isTrue);
    expect(player.volume, 0);
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
  });
}
