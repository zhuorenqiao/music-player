// lib/playback/audio_player.dart
//
// 播放层门面：把 T12 的 AudioDriver 包成原版 Player 的用法
// （src/lib/player.js），并一比一对译其中的 seek 守卫与音量记忆规则。
//
// 三条守卫数值逐字对齐原版：
//   armSeekGuard      -> 900ms 后复核位置（player.js:506）
//   verifySeekGuard   -> 容差 0.75s，只向前补做（player.js:526-）
//   applySeekGuardOnPlay -> playing 里补做一次后 400ms 再复核
//                           （player.js:551-，corrected 先置真再补做）
//
// 时间源全部可注入：`scheduler` 默认真实 Timer，测试注入可 flush 的假调度。
// 本文件是纯逻辑，不引 Flutter widget 层。
import 'dart:async';

import 'audio_driver.dart';
import 'play_error.dart';
import 'track.dart';

/// 播放层对外事件。全部由驱动事件派生，UI 只订阅这一条流。
sealed class PlayerEvent {
  const PlayerEvent();
}

class LoadingEvent extends PlayerEvent {
  const LoadingEvent(this.loading);
  final bool loading;
}

class CanplayEvent extends PlayerEvent {
  const CanplayEvent(this.duration);
  final double? duration;
}

class TimeUpdateEvent extends PlayerEvent {
  const TimeUpdateEvent(this.position, this.duration);
  final double position;
  final double? duration;
}

class StateChangedEvent extends PlayerEvent {
  const StateChangedEvent(this.playing);
  final bool playing;
}

/// 曲目自然播完（原版 `ended`，player.js:466-469）。
///
/// 必须与 [StateChangedEvent] 分开：原版 `ended` 先补一条 `statechange(false)`
/// 再发 `ended`，装配层只有靠后者才能区分「暂停」与「播完」
/// （player.tsx:441 的 `playNext({ auto: true })` 只认这一条）。
class CompletedEvent extends PlayerEvent {
  const CompletedEvent();
}

/// 已缓冲进度，对译原版 `progress` 事件的 `bufferedEnd`（player.tsx:433-435）。
/// [end] 是已缓冲到的秒数；内核还没报过时可为 null。
class BufferedEvent extends PlayerEvent {
  const BufferedEvent(this.end);
  final double? end;
}

class VolumeEvent extends PlayerEvent {
  const VolumeEvent(this.volume, this.muted);
  final double volume;
  final bool muted;
}

class ErrorEvent extends PlayerEvent {
  const ErrorEvent(this.kind, this.message);
  final PlayErrorKind kind;
  final String message;
}

/// 自动播放/音频焦点被拦：与 ErrorEvent 分开，因为原版这是
/// `playblocked` 而非 `error`，UI 不该弹「播放失败」。
class BlockedEvent extends PlayerEvent {
  const BlockedEvent(this.message);
  final String message;
}

/// 延时调度入口。默认 `Timer(delay, cb)`；测试注入可手动 flush 的假实现。
typedef ScheduleFn = void Function(Duration delay, void Function() callback);

/// 守卫数值（原版硬编码，见 player.js:506 / 551 / 532）。
const int kSeekGuardVerifyMs = 900;
const int kSeekGuardAfterPlayMs = 400;
const double kSeekGuardTolerance = 0.75;

/// 默认音量（原版 `#lastVolume = 0.7`，player.js:55）。
const double kDefaultVolume = 0.7;

/// 一次待复核的跳转。
///
/// 注入的调度器拿不到可 cancel 的句柄，所以失效靠 [_AudioPlayer] 侧的
/// `identical(guard, _guard)` 判定：新一次 seek 会把 `_guard` 换成新对象，
/// 旧回调回来时对不上就自行退出（等价于 clearTimeout）。
class SeekGuard {
  SeekGuard(this.target);

  final double target;
  bool corrected = false;
}

class AudioPlayer {
  AudioPlayer(this._driver, {double initialVolume = kDefaultVolume, ScheduleFn? scheduler})
    : _volume = _clamp01(initialVolume),
      _lastVolume = _clamp01(initialVolume) > 0 ? _clamp01(initialVolume) : kDefaultVolume,
      _schedule = scheduler ?? _timerSchedule {
    _subs.add(_driver.positionStream.listen(_onPosition));
    _subs.add(_driver.durationStream.listen(_onDuration));
    _subs.add(_driver.playingStream.listen(_onPlaying));
    _subs.add(_driver.loadingStream.listen(_onLoading));
    _subs.add(_driver.errorStream.listen(_onDriverError));
    _subs.add(_driver.canplayStream.listen((_) => _onCanplay()));
    _subs.add(_driver.completedStream.listen((_) => _onCompleted()));
    _subs.add(_driver.bufferedStream.listen(_onBuffered));
  }

  final AudioDriver _driver;
  final ScheduleFn _schedule;
  final _events = StreamController<PlayerEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];

  Track? _track;
  double _volume;
  double _lastVolume;
  bool _muted = false;
  bool _loading = false;
  SeekGuard? _guard;
  double? _pendingSeek;
  bool _disposed = false;

  Stream<PlayerEvent> get events => _events.stream;
  Track? get track => _track;
  bool get playing => _driver.isPlaying;
  bool get muted => _muted;
  double get volume => _muted ? 0 : _volume;
  double get position => _driver.position;
  double? get duration => _driver.durationOrNull;
  double? get buffered => _driver.bufferedOrNull;

  /// 加载曲目。清守卫与待补跳转、置加载、换源；[autoplay] 时不等待播放结果
  /// （失败经 [BlockedEvent] 反馈，对齐 player.js:202-205）。
  Future<bool> load(Track track, {bool autoplay = false}) async {
    _clearSeekGuard();
    _pendingSeek = null;
    _track = track;
    _setLoading(true);
    final opened = await _driver.open(track);
    if (!opened) {
      _setLoading(false);
      return false;
    }
    await _driver.setVolume(volume);
    if (autoplay) {
      unawaited(_play());
    }
    return true;
  }

  Future<void> _play() async {
    try {
      await _driver.play();
      _setLoading(false);
    } catch (error) {
      _setLoading(false);
      _emit(BlockedEvent(_blockedMessageOf(error)));
    }
  }

  /// 原版只对 `NotAllowedError` 说「点播放按钮」，其余给「无法开始播放：原文」。
  String _blockedMessageOf(Object error) {
    final text = error.toString();
    if (text.contains('NotAllowed') || text.contains('focus')) {
      return kAutoplayBlockedMessage;
    }
    return '无法开始播放：${text.replaceAll('\n', ' ')}';
  }

  Future<void> pause() => _driver.pause();

  /// 从暂停处继续：只让内核重新出声，**不重开媒体**。
  ///
  /// 与 [load] 的差别就是「进度保不保」：`load` 会先 `open` 再 seek 回来，
  /// 换源那一刻内核的位置已经归零；锁屏上的播放键必须原地续播，所以走这里。
  /// 自动播放被拦仍由 [_play] 转成 [BlockedEvent]，与首播同一条路径。
  Future<void> resume() => _play();

  /// 跳转。时长未知时先记 [_pendingSeek]，等 duration 到手再补做。
  Future<bool> seek(double seconds) async {
    final requested = seconds.isFinite && seconds > 0 ? seconds : 0.0;
    final total = _driver.durationOrNull;
    if (total == null || !total.isFinite || total <= 0) {
      _pendingSeek = requested;
      return true;
    }
    final target = requested > total ? total : requested;
    final ok = await _driver.seekTo(target);
    if (ok) {
      _armSeekGuard(target);
      _emit(TimeUpdateEvent(target, total));
    } else {
      _pendingSeek = requested;
    }
    return ok;
  }

  Future<bool> seekBy(double delta) =>
      seek(position + (delta.isFinite ? delta : 0));

  /// 设置音量。`v > 0` 解静音并记住；`v == 0` 只把音量留 0，**不动**静音标志
  /// （原版 player.js:315-324 的 else 分支写 `muted = false`，静音与否由音量读数
  /// 决定；`volume` getter 在这一支本来就返回 0）。
  Future<void> setVolume(double value) async {
    final v = _clamp01(value);
    _volume = v;
    if (v > 0) {
      _lastVolume = v;
      _muted = false;
    }
    await _driver.setVolume(v);
    _emit(VolumeEvent(volume, _muted));
  }

  /// 设置静音。取消静音而音量停在 0 时恢复记忆值（默认 0.7）。
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (!muted && _volume == 0) {
      _volume = _lastVolume > 0 ? _lastVolume : kDefaultVolume;
    }
    await _driver.setVolume(volume);
    _emit(VolumeEvent(volume, _muted));
  }

  Future<bool> toggleMute() async {
    await setMuted(!_muted);
    return _muted;
  }

  Future<void> stop() async {
    _clearSeekGuard();
    _pendingSeek = null;
    _track = null;
    await _driver.stop();
    _setLoading(false);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _clearSeekGuard();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _driver.dispose();
    await _events.close();
  }

  void _armSeekGuard(double seconds) {
    _clearSeekGuard();
    final guard = SeekGuard(seconds);
    _guard = guard;
    _schedule(
      const Duration(milliseconds: kSeekGuardVerifyMs),
      () => _verifySeekGuard(guard),
    );
  }

  void _clearSeekGuard() {
    _guard = null;
  }

  /// 单向补做：只有实际位置明显落后目标时才推回去，超过目标绝不回拉。
  void _verifySeekGuard([SeekGuard? candidate]) {
    final guard = candidate ?? _guard;
    if (guard == null || !identical(guard, _guard)) return;
    _clearSeekGuard();
    if (guard.corrected || _track == null) return;
    if (_driver.position < guard.target - kSeekGuardTolerance) {
      unawaited(_driver.seekTo(guard.target));
    }
  }

  void _applySeekGuardOnPlay() {
    final guard = _guard;
    if (guard == null || guard.corrected) return;
    if (_driver.position < guard.target - kSeekGuardTolerance) {
      // 关键次序：先记 corrected 再补做，否则补做引发的 playing 会再进这里，
      // 原版记录过这条自激死循环。
      guard.corrected = true;
      unawaited(_driver.seekTo(guard.target));
    }
    _schedule(
      const Duration(milliseconds: kSeekGuardAfterPlayMs),
      () => _verifySeekGuard(guard),
    );
  }

  void _onPosition(double value) {
    _emit(TimeUpdateEvent(value, _driver.durationOrNull));
  }

  void _onBuffered(double? end) {
    _emit(BufferedEvent(end));
  }

  void _onDuration(double? value) {
    final pending = _pendingSeek;
    if (pending != null && value != null && value > 0) {
      _pendingSeek = null;
      final target = pending > value ? value : pending;
      unawaited(
        _driver.seekTo(target).then((_) => _armSeekGuard(target)),
      );
    }
    _emit(CanplayEvent(value));
  }

  void _onPlaying(bool isPlaying) {
    if (isPlaying) {
      _setLoading(false);
      _applySeekGuardOnPlay();
    }
    _emit(StateChangedEvent(isPlaying));
  }

  void _onLoading(bool value) => _setLoading(value);

  void _onCanplay() {
    _setLoading(false);
    _emit(CanplayEvent(_driver.durationOrNull));
  }

  void _onCompleted() {
    _setLoading(false);
    // 次序对齐原版：先 statechange(false) 再 ended（player.js:466-469）。
    _emit(StateChangedEvent(false));
    _emit(const CompletedEvent());
  }

  void _onDriverError(DriverError error) {
    _setLoading(false);
    _emit(ErrorEvent(error.kind, errorMessageFor(error.kind)));
  }

  /// 加载态去重：同一个值连报只发一次（原版 #setLoading 同值短路）。
  void _setLoading(bool value) {
    if (_loading == value) return;
    _loading = value;
    _emit(LoadingEvent(value));
  }

  void _emit(PlayerEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  static void _timerSchedule(Duration delay, void Function() callback) {
    Timer(delay, callback);
  }
}

double _clamp01(num value) {
  if (!value.isFinite) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value.toDouble();
}
