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

import '../library/duration_probe.dart' show DurationProbeSkipped;
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
      // mpv 的 error 级日志**不都致命**。media_kit 把 `cplayer` / `lavf` /
      // `stream` 前缀的 error 日志一律转发到 `stream.error`（real.dart 的
      // MPV_EVENT_LOG_MESSAGE 分支），其中混着「附加资源加载失败」这类
      // **不影响主音频链**的噪音 —— 2026-11-10 真机实测抓到的形状：
      //   [lavf][error]    Failed to create file cache.
      //   [cplayer][error] Can not open external file \\?\D:\…\<歌名>.lrc.
      // 出现场景：曲目目录里有同名 .lrc 外挂歌词，mpv 自动挂载外挂字幕/
      // 歌词时用带 `\\?\` 前缀的路径打不开（它对外挂文件走这个前缀，主文件
      // 不用）→ 打不开**外挂**，但音频主链完全正常（实测 duration 正确回报、
      // position 持续前进、playing=true）。不过滤的话这条被 classifyFailure
      // 归成 unknown → 弹「音频播放失败」→ 还触发 1.4s 自动跳坏链，把一首
      // 播得好好的歌标记成损坏并切走 —— 这就是真机上「音乐播放不出来」的
      // 直接原因。
      //
      // 致命错误（真坏文件）的形状完全不同，实测对照：
      //   [ffmpeg/audio][error] flac: invalid residual
      //   [ffmpeg/audio][error] flac: decode_frame() failed
      //   [ad][error]           Error decoding audio.
      // 解码器/音频输出层的失败**不在**过滤名单里，照常上报 —— 过滤只丢
      // 「外挂文件 / file cache」这两个已证实的噪音形状，宁可漏报噪音、
      // 绝不吞掉真错。
      if (MediaKitDriver.isNonFatalAttachmentError(message)) {
        return;
      }
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

  /// mpv 的「外挂资源打开失败」噪音：主音频链不受影响，不上报。
  ///
  /// 两条形状都是 2026-11-10 真机/同源 libmpv 实测的原话（`\\?\` 后的路径
  /// 任意、结尾句点可有可无），用 `contains` 匹配以容纳路径差异。
  /// static 公开：test/playback/media_kit_driver_filter_test.dart 直接钉这份名单。
  static bool isNonFatalAttachmentError(String message) =>
      message.contains('Can not open external file') ||
      message.contains('Failed to create file cache');

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
/// `MediaKit.ensureInitialized()`，`Player()` 直接抛。这条路径归到
/// [DurationProbeSkipped]（第 4 轮 C8：**根本没探**，不是「这文件没有时长」），
/// 由 `DurationProbe` 折算成 `notAttempted`；绝不冒泡 —— 没有时长可比界面崩掉轻得多。
class MediaKitDurationOpener {
  /// [timeoutMs] 由装配层给（与 `DurationProbe` 同一预算）。
  ///
  /// 实际先到点的是外层 `DurationProbe` 的预算（它比这里更早起表），所以生产路径上
  /// 超时由外层归成 `timedOut`，这里是**兜底**：万一下次有人改预算、把外层去掉，
  /// 也不会让一次 `open` 无限挂着。`finally` 的清理在本 future 结束时照跑。
  MediaKitDurationOpener({required this.timeoutMs});

  final int timeoutMs;

  Player? _player;
  bool _disposed = false;

  /// 探一个来源（文件路径或已经是 URI）；失败 / 超时都是 NaN，绝不抛。
  ///
  /// 唯一的例外是 [DurationProbeSkipped]：那三支**根本没探**（内核已释放、来源
  /// 不能探、原生库起不来）不许伪装成「这文件没有时长」—— 第 4 轮 C8 的要点是
  /// NaN 这个返回值必须只有一个含义，否则上层会把一次被丢弃的尝试记成永久结论。
  Future<double> call(String source) async {
    // 已经释放的探测器不再碰内核（第 4 轮 C8）：退出时排在队列里的探测会一路
    // 跑到这里来，从前它返回 NaN，与「文件没有时长」同形 → 标记照记。
    if (_disposed) throw const DurationProbeSkipped('opener disposed');
    // 终审 R7：这一层只会把来源包成文件 URI，`content://` 之类的 SAF 句柄
    // 开不了 —— 与其占着串行队列白等满 [timeoutMs] 再换一个 NaN，不如当场
    // 承认「这条我探不了」。调用方（`ImportService._enrich`）已经先按句柄
    // 类型挡了一道，这里是最后一道闸：探针还有别的入口时同样不许白等。
    if (!FilePathHandle(source).canProbeDuration) {
      throw const DurationProbeSkipped('source is not a readable file');
    }
    final Player player;
    try {
      player = _player ??= Player();
    } catch (_) {
      // 原生库不可用（测试环境、缺 libmpv 的平台）：这是**环境**没探成，不是
      // 文件的结论 —— 记成「没时长」等于把库里每一条都永久冻在 `--:--`。
      throw const DurationProbeSkipped('native player unavailable');
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
