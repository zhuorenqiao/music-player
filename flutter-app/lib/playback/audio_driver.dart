// lib/playback/audio_driver.dart
//
// 播放内核的唯一出口（对译 src/lib/player.js 的全部原生事件），
// 以及测试用的可脚本化替身。纯逻辑，不依赖 media_kit，也不依赖 Flutter material。
//
// 原版每个原生事件在这里都有一条对应的流，映射关系：
//   timeupdate      -> positionStream（每秒多次）
//   progress        -> bufferedStream
//   durationchange  -> durationStream
//   play / pause    -> playingStream
//   loadstart/waiting/stalled -> loadingStream（真）
//   canplay/playing -> loadingStream（假）+ canplayStream
//   error           -> errorStream（DriverError 带归一后的分类）
//   ended           -> completedStream（原版还会同时发 statechange(false)）
//   playblocked     -> 由 errorStream 的 aborted 分类或 play() 抛异常表达
import 'dart:async';

import 'play_error.dart';
import 'track.dart';

/// 一次播放失败：归一后的分类 + 内核原文（mpv / 平台异常文本）。
///
/// [rawMessage] 只作诊断与日志用；面向用户的文案由
/// `errorMessageFor(kind)` 决定，不要直接把原文显示给用户。
class DriverError {
  const DriverError(this.kind, this.rawMessage);

  final PlayErrorKind kind;
  final String rawMessage;

  @override
  String toString() => 'DriverError(${kind.name}, $rawMessage)';
}

/// 播放内核接口。media_kit 实现（Task 13）与 [FakeAudioDriver] 都满足它。
///
/// 八条流**一律是广播流**：订阅只收订阅之后的事件，不重放历史。真实内核不会
/// 补发历史，替身也不补 —— 否则会写出只有替身能过的用例。调用方必须
/// 「先订阅、后动作」。
///
/// 同一个值是否重复上报由实现决定：真实内核只在状态真正变化时发事件，
/// 替身的 [FakeAudioDriver] 内部状态迁移同样做了去重
/// （`emitPlaying` / `emitLoading` 这类显式注入除外）。
abstract class AudioDriver {
  /// 打开一个曲目（先停掉当前播放，但不自动播放）。
  ///
  /// 对齐原版 `load()`：它切源前先 `audio.pause()`（`src/lib/player.js:185`），
  /// 所以「播放中换歌」必须让调用方看到 `playing(false)`，而不是自己去猜。
  /// 返回是否成功发起加载。
  Future<bool> open(Track track);

  Future<void> play();
  Future<void> pause();

  /// 跳转到 [seconds]，返回是否被内核接受（时长未知时可能先返回成功、
  /// 再由实现内部暂存补做）。
  Future<bool> seekTo(double seconds);

  /// 音量 0 ~ 1。
  Future<void> setVolume(double value);

  Future<void> stop();
  Future<void> dispose();

  Stream<double> get positionStream;
  Stream<double?> get bufferedStream;
  Stream<double?> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get loadingStream;
  Stream<DriverError> get errorStream;
  Stream<void> get completedStream;
  Stream<void> get canplayStream;

  double get position;
  double? get durationOrNull;
  double? get bufferedOrNull;
  bool get isPlaying;
  bool get isLoading;
}

/// 可脚本化的播放内核替身：测试用它扮演「真实内核」。
///
/// 三种驱动方式：
/// - **注入事件**：`emitPosition` / `emitDuration` / `emitBuffered` /
///   `emitPlaying` / `emitLoading` / `emitCanplay` / `emitCompleted` /
///   `emitError` —— 直接推到对应广播流，并同步更新同名取值。
/// - **注入失败**：`failNext`（只影响下一次 open）、`alwaysFail`（每次 open 都败）、
///   `blockPlayWithBlocked`（play() 只推 aborted 错误）、`playThrows`（play() 直接抛）。
/// - **注入卡住**：`blockOpen`（open 成功但不发明时长/canplay）。
///
/// 所有调用按发生顺序记进 [calls]，形如 `open:/a.flac`、`play`、`seek:12.5`、
/// `volume:0.70`、`stop`、`dispose`。`open` 记的是 `track.src`（不是
/// `track.handle.uri`），以便测试里直接读路径。
class FakeAudioDriver implements AudioDriver {
  /// `blockPlayWithBlocked` 推送的内核原文，对齐原版 `NotAllowedError` 的说法。
  static const String blockedPlayMessage = 'NotAllowedError: play blocked';

  final List<String> calls = [];

  /// open 返回 true 但从不发时长 / canplay，`isLoading` 置真：模拟仍在加载。
  bool blockOpen = false;

  /// 每次 open 都以 [PlayErrorKind.decode] 失败（[alwaysFailMessage] 为原文）。
  bool alwaysFail = false;

  /// play() 不发 playing，只推一条 [PlayErrorKind.aborted] + [blockedPlayMessage]。
  bool blockPlayWithBlocked = false;

  /// 非 null 时 play() 先记 `play` 再抛出它：模拟内核直接抛错（自动播放被拦）。
  /// 持续生效，置回 null 才恢复正常；想只抛一次可在测试里手动清空。
  Object? playThrows;

  /// [alwaysFail] 每次推送的内核原文。
  String alwaysFailMessage = 'decoding failed';

  final _position = StreamController<double>.broadcast();
  final _buffered = StreamController<double?>.broadcast();
  final _duration = StreamController<double?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<DriverError>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _canplay = StreamController<void>.broadcast();

  double _positionValue = 0;
  double? _durationValue;
  double? _bufferedValue;
  bool _isPlaying = false;
  bool _isLoading = false;
  DriverError? _nextError;
  bool _disposed = false;

  /// 让下一次 open 以给定分类失败，只影响一次。
  void failNext({
    PlayErrorKind kind = PlayErrorKind.decode,
    String message = 'boom',
  }) {
    _nextError = DriverError(kind, message);
  }

  void emitPosition(double seconds) {
    _positionValue = seconds;
    _push(_position, seconds);
  }

  void emitDuration(double? seconds) {
    _durationValue = seconds;
    _push(_duration, seconds);
  }

  void emitBuffered(double? seconds) {
    _bufferedValue = seconds;
    _push(_buffered, seconds);
  }

  void emitPlaying(bool value) {
    _isPlaying = value;
    _push(_playing, value);
  }

  void emitLoading(bool value) {
    _isLoading = value;
    _push(_loading, value);
  }

  /// 推一条 canplay。加载态不跟着变 —— 需要时自己调 [emitLoading]。
  void emitCanplay() => _push(_canplay, null);

  /// 推一条结束事件并同步播放态：`ended` 隐含暂停，所以 `isPlaying` 置假，
  /// 播放中还会补一条 `playing(false)` —— 否则取值与流最后的值会互相矛盾
  /// （调用方两边都读）。未播放时结束不额外发事件，对齐 `pause()` 只在真迁移时报。
  void emitCompleted() {
    _setPlaying(false);
    _push(_completed, null);
  }

  void emitError(DriverError error) => _push(_errors, error);

  @override
  Future<bool> open(Track track) async {
    calls.add('open:${track.src}');
    // 换源：位置与时长先归零，等内核回报（失败分支同样如此）。
    _positionValue = 0;
    _durationValue = null;
    _bufferedValue = null;
    final next = _nextError;
    if (next != null) {
      _nextError = null;
      _setLoading(false);
      _push(_errors, next);
      return false;
    }
    if (alwaysFail) {
      _setLoading(false);
      _push(_errors, DriverError(PlayErrorKind.decode, alwaysFailMessage));
      return false;
    }
    // 切源先停播（原版 load 的第一步就是 audio.pause()）：成功路径上正在播放
    // 就补一条 playing(false)，已暂停则静默 —— 与 pause() 一样只在真迁移时报。
    _setPlaying(false);
    if (blockOpen) {
      _setLoading(true);
      return true;
    }
    final seconds = track.hasDuration ? track.duration : _fallbackDuration;
    _durationValue = seconds;
    _push(_duration, seconds);
    _bufferedValue = seconds;
    _push(_buffered, seconds);
    _setLoading(false);
    _push(_canplay, null);
    return true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    final thrown = playThrows;
    if (thrown != null) throw thrown;
    if (blockPlayWithBlocked) {
      _push(_errors, const DriverError(PlayErrorKind.aborted, blockedPlayMessage));
      return;
    }
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _setPlaying(false);
  }

  @override
  Future<bool> seekTo(double seconds) async {
    var target = seconds.isFinite && seconds > 0 ? seconds : 0.0;
    final total = _durationValue;
    if (total != null && target > total) target = total;
    _positionValue = target;
    calls.add('seek:${target.toStringAsFixed(1)}');
    _push(_position, target);
    return true;
  }

  @override
  Future<void> setVolume(double value) async {
    final clamped = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    calls.add('volume:${clamped.toStringAsFixed(2)}');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _positionValue = 0;
    _setPlaying(false);
    _setLoading(false);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _buffered.close();
    await _duration.close();
    await _playing.close();
    await _loading.close();
    await _errors.close();
    await _completed.close();
    await _canplay.close();
  }

  @override
  Stream<double> get positionStream => _position.stream;
  @override
  Stream<double?> get bufferedStream => _buffered.stream;
  @override
  Stream<double?> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<DriverError> get errorStream => _errors.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
  @override
  Stream<void> get canplayStream => _canplay.stream;

  @override
  double get position => _positionValue;
  @override
  double? get durationOrNull => _durationValue;
  @override
  double? get bufferedOrNull => _bufferedValue;
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isLoading => _isLoading;

  /// 曲目不带时长时 open 回报的占位时长（brief 约定），只为让 seek/守卫可算。
  static const double _fallbackDuration = 100;

  /// 内部状态迁移：同一个值不重复发事件（对齐真实内核只在变化时上报）。
  void _setPlaying(bool value) {
    if (_isPlaying == value) return;
    _isPlaying = value;
    _push(_playing, value);
  }

  void _setLoading(bool value) {
    if (_isLoading == value) return;
    _isLoading = value;
    _push(_loading, value);
  }

  /// 销毁之后到达的事件静默丢弃（迟到回调不应炸掉测试）。
  void _push<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}
