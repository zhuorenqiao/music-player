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
import 'track_handle.dart';

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

/// 独立内核的时长探测 opener（终审 I1）。
///
/// 与播放用的 [MediaKitDriver] 各持一个 `Player`：探测不许打断正在播的曲目，
/// 也不许把自己的状态混进主播放链路 —— 原版同样是开一个临时 `<audio>` 元素读
/// `loadedmetadata`（`src/state/duration.ts`）。排队与「一次只开一首」由
/// `library/duration_probe.dart` 负责，这里只实现「打开 → 拿第一个有限时长 →
/// 卸掉」这一件事。
///
/// 实例**懒建**：组合根在 widget 测试里也会被构造，而那里从未调过
/// `MediaKit.ensureInitialized()`，`Player()` 直接抛。这条路径按「探不出来」
/// 处理成 NaN，绝不冒泡 —— 没有时长可比界面崩掉轻得多。
class MediaKitDurationOpener {
  /// [timeoutMs] 由装配层给（与 `DurationProbe` 同一预算），两个数值必须一致：
  /// 这里先到点，才能保证 `finally` 的清理赶在队列放行之前。
  MediaKitDurationOpener({required this.timeoutMs});

  final int timeoutMs;

  Player? _player;
  bool _disposed = false;

  /// 探一个来源（文件路径或已经是 URI）；失败 / 超时都是 NaN，绝不抛。
  Future<double> call(String source) async {
    if (_disposed) return double.nan;
    // 终审 R7：这一层只会把来源包成文件 URI，`content://` 之类的 SAF 句柄
    // 开不了 —— 与其占着串行队列白等满 [timeoutMs] 再换一个 NaN，不如当场
    // 承认「这条我探不了」。调用方（`ImportService._enrich`）已经先按句柄
    // 类型挡了一道，这里是最后一道闸：探针还有别的入口时同样不许白等。
    if (!FilePathHandle(source).canProbeDuration) return double.nan;
    final Player player;
    try {
      player = _player ??= Player();
    } catch (_) {
      // 原生库不可用（测试环境、缺 libmpv 的平台）：全部当「探不出来」。
      return double.nan;
    }
    final deadline = Duration(milliseconds: timeoutMs);
    final completer = Completer<double>();
    StreamSubscription<Duration>? subscription;
    try {
      // 先订阅再开：media_kit 的 duration 只在变化时发，晚订阅会错过这一首的值。
      subscription = player.stream.duration.listen((value) {
        if (value.inMilliseconds > 0 && !completer.isCompleted) {
          completer.complete(value.inMilliseconds / 1000.0);
        }
      });
      await player.open(Media(FilePathHandle(source).uri), play: false);
      // open 已经把现值算好了的（常见）就不用再等一条流事件。
      final settled = player.state.duration;
      if (settled.inMilliseconds > 0) return settled.inMilliseconds / 1000.0;
      return await completer.future.timeout(deadline, onTimeout: () => double.nan);
    } catch (_) {
      return double.nan;
    } finally {
      try {
        await subscription?.cancel();
      } catch (_) {
        // 取消失败不影响下面那次 stop
      }
      // 无论成败都把媒体卸掉：留着上一首会污染下一首的 duration 流。
      try {
        await player.stop();
      } catch (_) {
        // 停止失败只当这次没清理，交给下一次探测或 dispose
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.dispose();
    } catch (_) {
      // 原生实例释放失败没有可操作的东西，也不该反过来打断收尾。
    }
  }
}
