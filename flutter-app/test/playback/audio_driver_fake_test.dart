// test/playback/audio_driver_fake_test.dart
//
// 锁住测试替身的可脚本化行为：所有订阅一律「先订阅、后动作」——
// AudioDriver 的八条流都是广播流，订阅之后的事件才会到达。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/play_error.dart';
import 'package:light_music/playback/track.dart';

Track aTrack() => Track(id: '1', src: '/a.flac', title: 'A', duration: 100);

/// 广播流是异步投递：等一轮微任务让已 add 的事件跑完。
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('open 记录调用并回报时长、缓冲与 canplay', () async {
    final driver = FakeAudioDriver();
    // 先订阅再 open：广播流不重放历史。
    final durationFuture = driver.durationStream.first;
    final canplayFuture = driver.canplayStream.first;
    expect(await driver.open(aTrack()), isTrue);
    expect(driver.calls, ['open:/a.flac']);
    expect(await durationFuture, 100);
    await canplayFuture;
    expect(driver.durationOrNull, 100);
    expect(driver.bufferedOrNull, 100);
    expect(driver.isLoading, isFalse);
    expect(driver.isPlaying, isFalse);
  });

  test('open 切歌把位置归零，未知时长回退 100', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    driver.emitPosition(30);
    expect(driver.position, 30);
    expect(await driver.open(Track(id: '2', src: '/b.mp3', title: 'B')), isTrue);
    expect(driver.position, 0);
    expect(driver.durationOrNull, 100);
    expect(driver.calls, ['open:/a.flac', 'open:/b.mp3']);
  });

  test('failNext 让 open 返回 false 并推送错误', () async {
    final driver = FakeAudioDriver()
      ..failNext(kind: PlayErrorKind.decode, message: 'broken stream');
    final errorFuture = driver.errorStream.first;
    expect(await driver.open(aTrack()), isFalse);
    final error = await errorFuture;
    expect(error.kind, PlayErrorKind.decode);
    expect(error.rawMessage, 'broken stream');
    // 只影响一次：第二次 open 正常成功。
    expect(await driver.open(aTrack()), isTrue);
    expect(driver.calls, ['open:/a.flac', 'open:/a.flac']);
    expect(driver.durationOrNull, 100);
  });

  test('alwaysFail 每次 open 都失败并推 decode 错误', () async {
    final driver = FakeAudioDriver()..alwaysFail = true;
    final errors = <DriverError>[];
    final sub = driver.errorStream.listen(errors.add);
    expect(await driver.open(aTrack()), isFalse);
    expect(await driver.open(aTrack()), isFalse);
    await settle();
    await sub.cancel();
    expect(errors.map((e) => e.kind), [
      PlayErrorKind.decode,
      PlayErrorKind.decode,
    ]);
    expect(errors.first.rawMessage, 'decoding failed');
    expect(driver.calls, ['open:/a.flac', 'open:/a.flac']);
    expect(driver.isLoading, isFalse);
  });

  test('blockOpen 返回 true 但不发时长与 canplay', () async {
    final driver = FakeAudioDriver()..blockOpen = true;
    final durations = <double?>[];
    final durationSub = driver.durationStream.listen(durations.add);
    var canplayCount = 0;
    final canplaySub = driver.canplayStream.listen((_) => canplayCount += 1);
    expect(await driver.open(aTrack()), isTrue);
    await settle();
    expect(durations, isEmpty);
    expect(canplayCount, 0);
    expect(driver.durationOrNull, isNull);
    expect(driver.bufferedOrNull, isNull);
    expect(driver.isLoading, isTrue);
    expect(driver.calls, ['open:/a.flac']);
    // 加载完成由测试自己推（替身不替调用方做状态推导）。
    driver.emitDuration(100);
    driver.emitBuffered(60);
    driver.emitCanplay();
    driver.emitLoading(false);
    await settle();
    expect(durations, [100]);
    expect(canplayCount, 1);
    expect(driver.bufferedOrNull, 60);
    expect(driver.isLoading, isFalse);
    await durationSub.cancel();
    await canplaySub.cancel();
  });

  test('blockPlayWithBlocked 不发 playing，只推 aborted 错误', () async {
    final driver = FakeAudioDriver()..blockPlayWithBlocked = true;
    await driver.open(aTrack());
    final errors = <DriverError>[];
    final plays = <bool>[];
    final errorSub = driver.errorStream.listen(errors.add);
    final playSub = driver.playingStream.listen(plays.add);
    await driver.play();
    await settle();
    await errorSub.cancel();
    await playSub.cancel();
    expect(plays, isEmpty);
    expect(driver.isPlaying, isFalse);
    expect(errors.single.kind, PlayErrorKind.aborted);
    expect(errors.single.rawMessage, FakeAudioDriver.blockedPlayMessage);
    expect(driver.calls, ['open:/a.flac', 'play']);
  });

  test('playThrows 让 play() 直接抛异常', () async {
    final driver = FakeAudioDriver()
      ..playThrows = Exception('NotAllowedError: play blocked');
    await driver.open(aTrack());
    await expectLater(driver.play(), throwsA(isA<Exception>()));
    expect(driver.isPlaying, isFalse);
    expect(driver.calls, ['open:/a.flac', 'play']);
  });

  test('seek 越界夹到时长内并返回是否成功', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    expect(await driver.seekTo(999), isTrue);
    expect(driver.position, 100);
    expect(await driver.seekTo(-5), isTrue);
    expect(driver.position, 0);
    expect(driver.calls, ['open:/a.flac', 'seek:100.0', 'seek:0.0']);
  });

  test('play/pause 驱动 playingStream', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    final states = <bool>[];
    final sub = driver.playingStream.listen(states.add);
    await driver.play();
    await driver.pause();
    await settle();
    await sub.cancel();
    expect(states, [true, false]);
    expect(driver.isPlaying, isFalse);
    expect(driver.calls, ['open:/a.flac', 'play', 'pause']);
  });

  test('emitPlaying 直达流与同步取值', () async {
    final driver = FakeAudioDriver();
    final states = <bool>[];
    final sub = driver.playingStream.listen(states.add);
    driver.emitPlaying(true);
    expect(driver.isPlaying, isTrue);
    driver.emitPlaying(false);
    expect(driver.isPlaying, isFalse);
    await settle();
    await sub.cancel();
    expect(states, [true, false]);
  });

  test('emitBuffered 更新缓冲点，null 表示未知', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    final buffered = <double?>[];
    final sub = driver.bufferedStream.listen(buffered.add);
    driver.emitBuffered(42.5);
    expect(driver.bufferedOrNull, 42.5);
    driver.emitBuffered(null);
    expect(driver.bufferedOrNull, isNull);
    await settle();
    await sub.cancel();
    expect(buffered, [42.5, null]);
    expect(driver.calls, ['open:/a.flac']);
  });

  test('emitError 推送任意 DriverError', () async {
    final driver = FakeAudioDriver();
    const injected = DriverError(PlayErrorKind.network, 'socket closed');
    final errorFuture = driver.errorStream.first;
    driver.emitError(injected);
    final error = await errorFuture;
    expect(error.kind, PlayErrorKind.network);
    expect(error.rawMessage, 'socket closed');
    expect(driver.calls, isEmpty);
  });

  test('emitCompleted 推结束事件并清掉播放态', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    await driver.play();
    var completions = 0;
    final sub = driver.completedStream.listen((_) => completions += 1);
    driver.emitCompleted();
    await settle();
    await sub.cancel();
    expect(completions, 1);
    expect(driver.isPlaying, isFalse);
    expect(driver.calls, ['open:/a.flac', 'play']);
  });

  test('setVolume / stop / dispose 记录调用，stop 归零位置', () async {
    final driver = FakeAudioDriver();
    await driver.open(aTrack());
    driver.emitPosition(12.5);
    await driver.setVolume(0.7);
    await driver.setVolume(1);
    await driver.play();
    await driver.stop();
    expect(driver.isPlaying, isFalse);
    expect(driver.position, 0);
    await driver.dispose();
    expect(driver.calls, [
      'open:/a.flac',
      'volume:0.70',
      'volume:1.00',
      'play',
      'stop',
      'dispose',
    ]);
    // 销毁后继续注入不抛（迟到的事件不应炸测试）。
    driver.emitPosition(1);
    expect(driver.position, 1);
  });

  test('广播流：订阅之前发出的事件不会重放', () async {
    final driver = FakeAudioDriver();
    driver.emitPosition(3);
    final got = <double>[];
    final sub = driver.positionStream.listen(got.add);
    await settle();
    expect(got, isEmpty);
    driver.emitPosition(4);
    await settle();
    expect(got, [4]);
    await sub.cancel();
    expect(driver.calls, isEmpty);
  });
}
