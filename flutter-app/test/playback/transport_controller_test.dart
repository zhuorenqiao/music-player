// test/playback/transport_controller_test.dart
//
// 播放编排：对译 src/state/player.tsx 的「播放编排 + 播放器事件」两段。
// 所有延时都走注入的假时钟（`FakeClock`），测试里不用真实 Timer。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/play_error.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';

Track t(String id) => Track(id: id, src: '/$id.flac', title: '歌$id', duration: 100);

/// 广播流是异步投递：等两轮事件循环，让「驱动事件 -> AudioPlayer -> 控制器」跑完。
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class RecordingRecent implements RecentRecorder {
  final List<String> ids = [];
  final List<DateTime?> ats = [];

  @override
  void record(Track track, {DateTime? at}) {
    ids.add(track.id);
    ats.add(at);
  }
}

class RecordingToasts implements ToastSink {
  final List<String> messages = [];

  @override
  void show(String message, {String key = '', int durationMs = 3200}) =>
      messages.add(key.isEmpty ? message : '$message[$key]');

  @override
  void info(String message) => show(message);

  @override
  void error(String message) => show(message);
}

class _Scheduled {
  _Scheduled(this.callback);
  final void Function() callback;
}

/// 可手动推进的假时钟：实现 [DelayScheduler]，返回真能取消的句柄。
class FakeClock {
  final List<_Scheduled> _tasks = [];
  final List<int> scheduledMs = [];

  int get pendingCount => _tasks.length;

  CancelDelay schedule(Duration delay, void Function() callback) {
    scheduledMs.add(delay.inMilliseconds);
    final task = _Scheduled(callback);
    _tasks.add(task);
    return () => _tasks.remove(task);
  }

  /// 跑一批已排任务（新增的任务留到下一次 flush，便于断言「还会不会再排」）。
  void flush() {
    final batch = List<_Scheduled>.of(_tasks);
    _tasks.clear();
    for (final task in batch) {
      task.callback();
    }
  }
}

TransportController build({
  required Playlist playlist,
  required FakeAudioDriver driver,
  RecentRecorder? recent,
  RecordingToasts? toasts,
  int Function()? now,
}) => TransportController(
  player: AudioPlayer(driver, scheduler: (delay, callback) => callback()),
  recent: recent ?? RecordingRecent(),
  toasts: toasts ?? RecordingToasts(),
  playlist: playlist,
  now: now,
);

/// brief 约定的构造方式：控制器自带可注入时钟。
TransportController buildWithClock({
  required Playlist playlist,
  required FakeAudioDriver driver,
  required FakeClock clock,
  RecentRecorder? recent,
  RecordingToasts? toasts,
}) => TransportController(
  player: AudioPlayer(driver, scheduler: (delay, callback) => callback()),
  recent: recent ?? RecordingRecent(),
  toasts: toasts ?? RecordingToasts(),
  playlist: playlist,
  scheduler: clock.schedule,
);

void main() {
  group('模式与选曲', () {
    test('播第 0 首：driver 收到 open 与 play，最近播放记下', () async {
      final driver = FakeAudioDriver();
      final recent = RecordingRecent();
      final toasts = RecordingToasts();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        recent: recent,
        toasts: toasts,
      );

      await c.playTrack('1');
      await settle();

      expect(driver.calls, ['open:/1.flac', 'volume:0.70', 'play']);
      expect(c.current!.id, '1');
      expect(c.view.value.current!.id, '1');
      expect(c.playing, isTrue);
      // 没出声（没有 position>0 的 timeupdate）之前不许记最近播放
      expect(recent.ids, isEmpty);
      expect(toasts.messages, isEmpty);
    });

    test('未知 id：不碰驱动、不弹提示、不动当前曲目', () async {
      final driver = FakeAudioDriver();
      final toasts = RecordingToasts();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
        toasts: toasts,
      );

      await c.playTrack('nope');
      await settle();

      expect(driver.calls, isEmpty);
      expect(toasts.messages, isEmpty);
      expect(c.current!.id, '1');
    });

    test('模式循环顺序与标签同步给 view', () async {
      final toasts = RecordingToasts();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: FakeAudioDriver(),
        toasts: toasts,
      );

      expect(c.view.value.mode, PlayMode.list);
      expect(c.cycleMode(), PlayMode.one);
      expect(c.view.value.mode, PlayMode.one);
      expect(playModeLabel(c.cycleMode()), '随机播放');
      expect(c.view.value.mode, PlayMode.shuffle);
      // 模式切换会原地改文案，不叠新条（原版 key = 'play-mode'）
      expect(toasts.messages.last, '播放模式：随机播放[play-mode]');
    });

    test('单曲循环下自动下一首是原地重播', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks(
          [t('1'), t('2')],
          mode: PlayMode.one,
          currentIndex: 0,
        ),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      driver.calls.clear();

      await c.next(auto: true);
      await settle();

      expect(c.current!.id, '1');
      expect(driver.calls, contains('open:/1.flac'));
    });

    test('曲目播完自动开到下一首（列表模式）', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      driver.calls.clear();

      // 原版 `ended` -> playNext({auto: true})（player.tsx:441）
      driver.emitCompleted();
      await settle();

      expect(c.current!.id, '2');
      expect(c.view.value.current!.id, '2');
      expect(driver.calls, contains('open:/2.flac'));
    });

    test('曲目播完在单曲循环下原地重播，不前进', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks(
          [t('1'), t('2')],
          mode: PlayMode.one,
          currentIndex: 0,
        ),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      driver.calls.clear();

      driver.emitCompleted();
      await settle();

      // next(auto: true) 在单曲循环下返回当前索引：重开同一首，而不是第 2 首
      expect(c.current!.id, '1');
      expect(
        driver.calls.where((call) => call.startsWith('open:')).toList(),
        ['open:/1.flac'],
      );
    });
  });

  group('上一首的三秒规则', () {
    test('已播放超过 3 秒回到本曲开头，否则切上一曲', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2'), t('3')], currentIndex: 1),
        driver: driver,
      );

      await c.playTrack('2');
      await settle();

      driver.emitPosition(10);
      await settle();
      await c.previous();
      expect(c.current!.id, '2');
      expect(driver.calls.last, 'seek:0.0');

      driver.emitPosition(1);
      await settle();
      await c.previous();
      await settle();
      expect(c.current!.id, '1');
    });

    test('刚好 3 秒不算「超过」，按切上一首处理', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2')], currentIndex: 1),
        driver: driver,
      );

      await c.playTrack('2');
      await settle();
      driver.emitPosition(3);
      await settle();

      await c.previous();
      await settle();
      expect(c.current!.id, '1');
    });
  });

  group('损坏曲目', () {
    test('打角标、1400ms 后自动跳下一首', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..failNext(kind: PlayErrorKind.decode);
      final toasts = RecordingToasts();
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
        toasts: toasts,
      );

      await c.playTrack('1');
      await settle();

      expect(c.playlist.byId('1')!.broken, isTrue);
      expect(c.consecutiveFailures, 1);
      expect(clock.scheduledMs, [1400]);
      expect(clock.pendingCount, 1);
      // 提示要带曲名，且用逐字文案
      expect(
        toasts.messages,
        ['${errorMessageFor(PlayErrorKind.decode)}（歌1）[broken-1]'],
      );

      clock.flush();
      await settle();

      expect(c.current!.id, '2');
      expect(c.view.value.current!.id, '2');
      // 第二首正常可播：canplay 是唯一的清零时机
      expect(c.consecutiveFailures, 0);
    });

    test('连续出错只留一个待跳定时器（后一次取消前一次）', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..alwaysFail = true;
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2'), t('3')]),
        driver: driver,
        clock: clock,
      );

      await c.playTrack('1');
      await settle();
      expect(clock.pendingCount, 1);

      // 还没跳就再报一次错：必须把上一个定时器取消掉，不能排两条
      await c.playTrack('1');
      await settle();
      expect(clock.pendingCount, 1);
      expect(clock.scheduledMs, [1400, 1400]);
      expect(c.consecutiveFailures, 2);
    });

    test('手动切歌会取消待跳定时器', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..failNext();
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
      );

      await c.playTrack('1');
      await settle();
      expect(clock.pendingCount, 1);

      await c.playTrack('2');
      await settle();

      expect(clock.pendingCount, 0);
      expect(c.current!.id, '2');
    });
  });

  group('熔断', () {
    test('连续失败达到列表长度即停手：暂停、常驻提示、不再排定时器', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..alwaysFail = true;
      final toasts = RecordingToasts();
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
        toasts: toasts,
      );

      await c.playTrack('1');
      await settle();
      expect(c.consecutiveFailures, 1);

      clock.flush();
      await settle();

      expect(c.circuitOpen, isTrue);
      expect(c.view.value.circuitOpen, isTrue);
      expect(c.consecutiveFailures, 2);
      expect(driver.calls, contains('pause'));
      expect(clock.pendingCount, 0);
      // 只排过一次自动跳（第 2 首失败后就熔断了）
      expect(clock.scheduledMs, [1400]);
      expect(toasts.messages.any((m) => m.contains('已停止自动跳转')), isTrue);

      // 熔断后用户再点：照旧打角标，但绝不再排自动跳
      await c.playTrack('1');
      await settle();
      expect(c.circuitOpen, isTrue);
      expect(clock.pendingCount, 0);
      expect(clock.scheduledMs.length, 1);
    });

    test('失败计数只在 canplay 清零，位置/播放态不能洗掉它', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..alwaysFail = true;
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
      );

      await c.playTrack('1');
      await settle();
      expect(c.consecutiveFailures, 1);

      // 坏文件先出了一点声：timeupdate + playing 都不许清零
      driver.emitPosition(5);
      driver.emitPlaying(true);
      await settle();
      expect(c.consecutiveFailures, 1);

      // 真能播了（canplay）才清零
      driver.alwaysFail = false;
      await c.playTrack('1');
      await settle();
      expect(c.consecutiveFailures, 0);
      // 恢复可播后熔断也解开
      expect(c.circuitOpen, isFalse);
    });

    test('熔断后曲目播完不再自动续播', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..alwaysFail = true;
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
      );

      await c.playTrack('1');
      await settle();
      clock.flush();
      await settle();
      expect(c.circuitOpen, isTrue);
      driver.calls.clear();

      driver.emitCompleted();
      await settle();

      expect(c.circuitOpen, isTrue);
      expect(driver.calls.where((call) => call.startsWith('open:')), isEmpty);
    });
  });

  group('最近播放', () {
    test('真正出声才记；同一首 500ms 内重复不记；过窗再记一次', () async {
      var tick = 0;
      final driver = FakeAudioDriver();
      final recent = RecordingRecent();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        recent: recent,
        now: () => tick,
      );

      await c.playTrack('1');
      await settle();
      // 只有 0 位置的 timeupdate（还有别的初始化事件）不记
      expect(recent.ids, isEmpty);

      tick = 600;
      driver.emitPosition(2);
      await settle();
      expect(recent.ids, ['1']);

      await c.playTrack('1');
      await settle();
      tick = 700;
      driver.emitPosition(3);
      await settle();
      expect(recent.ids.length, 1);

      tick = 2000;
      await c.playTrack('1');
      await settle();
      driver.emitPosition(4);
      await settle();
      expect(recent.ids, ['1', '1']);
    });

    test('记的是当前曲目 id，时间戳按注入的时钟走', () async {
      var tick = 0;
      final driver = FakeAudioDriver();
      final recent = RecordingRecent();
      final c = build(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        recent: recent,
        now: () => tick,
      );

      await c.playTrack('2');
      await settle();
      tick = 1234;
      driver.emitPosition(1);
      await settle();

      expect(recent.ids, ['2']);
      expect(recent.ats.single, DateTime.fromMillisecondsSinceEpoch(1234));
    });

    test('位置推进不触发 view 通知（进度走独立 notifier）', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();

      var notices = 0;
      c.view.addListener(() => notices += 1);
      for (var i = 1; i <= 5; i++) {
        driver.emitPosition(i.toDouble());
      }
      await settle();

      expect(c.position.value, 5);
      expect(notices, 0);
    });

    test('buffered / duration 同步到独立 notifier', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      expect(c.duration.value, 100);

      driver.emitBuffered(42);
      driver.emitPosition(7);
      await settle();
      expect(c.position.value, 7);
      // progress 的 bufferedEnd 要真的落到 notifier 上，不能停在换曲时的 0
      expect(c.buffered.value, 42);
      expect(c.duration.value, 100);
    });
  });

  group('被拦的自动播放', () {
    test('blocked 状态暴露给界面并可重试，重试最多 3 次', () async {
      final driver = FakeAudioDriver()
        ..playThrows = StateError('NotAllowedError: play blocked');
      final toasts = RecordingToasts();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
        toasts: toasts,
      );

      await c.playTrack('1', autoplay: true);
      await settle();

      expect(c.blockedMessage, kAutoplayBlockedMessage);
      expect(c.view.value.blocked, kAutoplayBlockedMessage);
      expect(toasts.messages, [kAutoplayBlockedMessage]);

      for (var i = 0; i < 5; i++) {
        await c.userGesture();
        await settle();
      }

      // 首次 + 最多 3 次重试
      expect(driver.calls.where((call) => call == 'play').length, 1 + 3);
      // 用完了也不会假装好了：提示还在
      expect(c.blockedMessage, isNotNull);
    });

    test('没有被拦时 userGesture 不动播放器', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      driver.calls.clear();

      await c.userGesture();
      await settle();

      expect(driver.calls, isEmpty);
    });
  });

  group('播放控制透传', () {
    test('togglePlay 暂停后原位恢复，seek/volume 走驱动', () async {
      final driver = FakeAudioDriver();
      final c = build(
        playlist: Playlist.fromTracks([t('1')]),
        driver: driver,
      );

      await c.playTrack('1');
      await settle();
      expect(c.view.value.playing, isTrue);

      await c.togglePlay();
      await settle();
      expect(c.view.value.playing, isFalse);

      driver.emitPosition(12);
      await settle();
      driver.calls.clear();

      await c.togglePlay();
      await settle();
      // 暂停恢复不该从 0 开始
      expect(driver.calls, contains('seek:12.0'));

      await c.seekTo(30);
      expect(driver.calls.last, 'seek:30.0');
      expect(await c.seekBy(-5), isTrue);
      expect(driver.calls.last, 'seek:25.0');

      await c.setVolume(0.4);
      expect(driver.calls.last, 'volume:0.40');
      expect(c.view.value.volume, 0.4);

      await c.toggleMute();
      expect(c.view.value.muted, isTrue);
    });

    test('空列表时 togglePlay 只提示，不碰驱动', () async {
      final driver = FakeAudioDriver();
      final toasts = RecordingToasts();
      final c = TransportController(
        player: AudioPlayer(driver),
        recent: RecordingRecent(),
        toasts: toasts,
        scheduler: (delay, callback) => () {},
      );

      await c.togglePlay();
      await settle();

      expect(driver.calls, isEmpty);
      expect(toasts.messages.single, contains('播放列表为空'));
    });
  });

  group('生命周期', () {
    test('dispose 取消待跳定时器并停掉播放器', () async {
      final clock = FakeClock();
      final driver = FakeAudioDriver()..failNext();
      final c = buildWithClock(
        playlist: Playlist.fromTracks([t('1'), t('2')]),
        driver: driver,
        clock: clock,
      );

      await c.playTrack('1');
      await settle();
      expect(clock.pendingCount, 1);

      await c.dispose();

      expect(clock.pendingCount, 0);
      expect(driver.calls, contains('dispose'));
    });
  });
}
