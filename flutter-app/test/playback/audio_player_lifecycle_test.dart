// test/playback/audio_player_lifecycle_test.dart
//
// 加载态去重与自动播放被拦的路径：这两条在原版里分别是
// #setLoading 的同值短路、play() 抛 NotAllowedError 转 playblocked。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/play_error.dart';
import 'package:light_music/playback/track.dart';

Track aTrack() => Track(id: '1', src: '/a.flac', title: 'A', duration: 100);

/// 广播流是异步投递：等一轮微任务让已 add 的事件跑完。
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('加载态去重：同一个值不重复发事件，canplay 时清加载', () async {
    final driver = FakeAudioDriver();
    final player = AudioPlayer(driver);
    final loadings = <bool>[];
    final sub = player.events.listen((event) {
      if (event is LoadingEvent) loadings.add(event.loading);
    });

    driver.emitLoading(true);
    driver.emitLoading(true);
    await settle();
    expect(loadings, [true]);

    driver.emitCanplay();
    await settle();
    expect(loadings, [true, false]);

    await sub.cancel();
    await player.dispose();
  });

  test('自动播放被拦：play 抛出转成 BlockedEvent 并带原版文案', () async {
    final driver = FakeAudioDriver()
      ..playThrows = StateError('NotAllowedError: play blocked');
    final player = AudioPlayer(driver);
    final blocked = <String>[];
    final sub = player.events.listen((event) {
      if (event is BlockedEvent) blocked.add(event.message);
    });

    expect(await player.load(aTrack(), autoplay: true), isTrue);
    await settle();
    await settle();

    expect(blocked, [kAutoplayBlockedMessage]);

    await sub.cancel();
    await player.dispose();
  });

  test('stop 清空曲目并清掉加载态', () async {
    final driver = FakeAudioDriver();
    final player = AudioPlayer(driver);
    await player.load(aTrack());
    await player.stop();
    expect(player.track, isNull);
    expect(driver.calls, contains('stop'));
  });
}
