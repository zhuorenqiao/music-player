// test/playback/audio_player_seek_guard_test.dart
//
// 锁住对译自 src/lib/player.js 的 seek 守卫三件套：
// arm 900ms / 补做容差 0.75s / playing 里 400ms 复核且 corrected 只补一次。
// 守卫用注入的假调度器驱动，不依赖真实等待。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/track.dart';

/// 立即触发、可手动 flush 的假调度器。
class FakeScheduler {
  final List<void Function()> _pending = [];
  Duration? lastDelay;

  void schedule(Duration delay, void Function() callback) {
    lastDelay = delay;
    _pending.add(callback);
  }

  void flush() {
    final pending = List.of(_pending);
    _pending.clear();
    for (final cb in pending) {
      cb();
    }
  }

  int get pendingCount => _pending.length;
}

Track trackAt(double duration) =>
    Track(id: '1', src: '/a.flac', title: 'A', duration: duration);

/// 广播流是异步投递：等一轮微任务让已 add 的事件跑完。
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('seek 后 arm 守卫：900ms 内位置没跟上就补做一次', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));

    await player.seek(50);
    expect(scheduler.lastDelay, const Duration(milliseconds: 900));

    // 内核只走到 40（落后超过 0.75s）：flush 应把它补到 50
    driver.emitPosition(40);
    scheduler.flush();
    expect(driver.calls, contains('seek:50.0'));
  });

  test('容差内（差 0.5s）不补做，避免打断正常推进', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(50);
    driver.emitPosition(49.5);
    scheduler.flush();
    expect(driver.calls.where((c) => c == 'seek:50.0').length, 1);
  });

  test('playing 事件里补做一次后即标记 corrected，不再自激', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(60);
    // 模拟内核回到起点后上报 playing
    driver.emitPosition(0);
    driver.emitPlaying(true);
    await settle();
    final seekCalls = driver.calls.where((c) => c.startsWith('seek:')).length;
    expect(seekCalls, 2); // 原始一次 + 补做一次，不多不少
    expect(scheduler.lastDelay, const Duration(milliseconds: 400));
  });

  test('守卫只补做向前：当前位置超过目标时不回拉', () async {
    final driver = FakeAudioDriver();
    final scheduler = FakeScheduler();
    final player = AudioPlayer(driver, scheduler: scheduler.schedule);
    await player.load(trackAt(100));
    await player.seek(30);
    driver.emitPosition(80);
    scheduler.flush();
    expect(driver.calls.where((c) => c == 'seek:30.0').length, 1);
  });

  test('时长未知时先记 pendingSeek，拿到时长后补做', () async {
    final driver = FakeAudioDriver()..blockOpen = true;
    final player = AudioPlayer(driver, scheduler: (d, cb) => cb());
    await player.load(Track(id: '1', src: '/a.flac', title: 'A'));
    expect(await player.seek(20), isTrue);
    driver.emitDuration(120);
    await settle();
    expect(driver.calls, contains('seek:20.0'));
  });
}
