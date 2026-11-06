// lib/playback/media_kit_driver.dart
//
// AudioDriver 的 media_kit 实现（唯一依赖 media_kit 的文件）。
//
// 与 AudioDriver 头注释的事件表一一对应：
//   stream.position  -> positionStream（mpv 的 time-pos，毫秒）
//   stream.buffer    -> bufferedStream
//   stream.duration  -> durationStream
//   stream.playing   -> playingStream
//   stream.buffering -> loadingStream
//   stream.error     -> errorStream（按 T11 的分类归一）
//   stream.completed -> completedStream
//   open() 成功      -> canplayStream（media_kit 没有 canplay，可用即可播）
//
// 音量用 mpv 的 0~100 标度（setVolume 内部写 mpv `volume` 属性），
// 所以对外 0~1 需要乘 100。使用前必须由装配层（T14）先调
// MediaKit.ensureInitialized()，否则 Player() 拿不到 libmpv。
import 'dart:async';

// media_kit 也导出一个 `Track`（容器内的音视频轨），与本项目的曲目模型同名，
// 这里隐藏掉，避免与本文件的 `Track` 产生歧义。
import 'package:media_kit/media_kit.dart' hide Track;

import 'audio_driver.dart';
import 'play_error.dart';
import 'track.dart';

class MediaKitDriver implements AudioDriver {
  MediaKitDriver({Player? player}) : _player = player ?? Player() {
    _positionSub = _player.stream.position.listen(
      (value) => _emit(_position, value.inMilliseconds / 1000),
    );
    _durationSub = _player.stream.duration.listen(
      (value) => _emit(_duration, value.inMilliseconds / 1000),
    );
    _bufferedSub = _player.stream.buffer.listen(
      (value) => _emit(_buffered, value.inMilliseconds / 1000),
    );
    _playingSub = _player.stream.playing.listen(
      (value) => _emit(_playing, value),
    );
    _loadingSub = _player.stream.buffering.listen((value) {
      _emit(_loading, value);
    });
    _completedSub = _player.stream.completed.listen((value) {
      if (value) _emit(_completed, null);
    });
    _errorSub = _player.stream.error.listen((message) {
      _emit(
        _errors,
        DriverError(
          classifyFailure(
            fileName: _currentFileName,
            rawMessage: message,
          ),
          message,
        ),
      );
    });
  }

  final Player _player;

  final _position = StreamController<double>.broadcast();
  final _buffered = StreamController<double?>.broadcast();
  final _duration = StreamController<double?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<DriverError>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _canplay = StreamController<void>.broadcast();

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration> _durationSub;
  late final StreamSubscription<Duration> _bufferedSub;
  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<bool> _loadingSub;
  late final StreamSubscription<bool> _completedSub;
  late final StreamSubscription<String> _errorSub;

  /// 当前曲目的文件名，只用于把内核原文归到「格式不支持 / 不存在」。
  String? _currentFileName;
  bool _disposed = false;

  @override
  Future<bool> open(Track track) async {
    _currentFileName = track.handle.displayName;
    final uri = track.handle.uri;
    try {
      await _player.open(Media(uri), play: false);
    } catch (error) {
      _emit(
        _errors,
        DriverError(
          classifyFailure(
            fileName: _currentFileName,
            rawMessage: error.toString(),
          ),
          error.toString(),
        ),
      );
      _emit(_loading, false);
      return false;
    }
    // media_kit 没有 canplay：open 返回即认为可播，播放层据此清加载态。
    _emit(_canplay, null);
    _emit(_loading, false);
    return true;
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<bool> seekTo(double seconds) async {
    if (!seconds.isFinite || seconds < 0) return false;
    try {
      await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 0~1 -> mpv 的 0~100。
  @override
  Future<void> setVolume(double value) => _player.setVolume(value * 100);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _positionSub.cancel();
    await _durationSub.cancel();
    await _bufferedSub.cancel();
    await _playingSub.cancel();
    await _loadingSub.cancel();
    await _completedSub.cancel();
    await _errorSub.cancel();
    await _player.dispose();
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
  double get position {
    final seconds = _player.state.position.inMilliseconds / 1000;
    return seconds.isFinite && seconds > 0 ? seconds : 0;
  }

  @override
  double? get durationOrNull {
    final seconds = _player.state.duration.inMilliseconds / 1000;
    return seconds.isFinite && seconds > 0 ? seconds : null;
  }

  @override
  double? get bufferedOrNull {
    final seconds = _player.state.buffer.inMilliseconds / 1000;
    return seconds.isFinite && seconds > 0 ? seconds : null;
  }

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isLoading => _player.state.buffering;

  /// 销毁后到达的内核回调静默丢弃。
  void _emit<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}
