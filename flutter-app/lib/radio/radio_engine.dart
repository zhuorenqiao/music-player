// lib/radio/radio_engine.dart
//
// 电台播放内核：接口 + media_kit 实现 + 测试替身。
//
// 为什么**不**复用 `playback/media_kit_driver.dart`：那台 `Player` 属于曲库播放
// （进度 / 时长 / 歌词 / 睡眠定时器都挂在它身上），而电台是「无限长、不可 seek」
// 的另一条链路 —— 混进同一台设备会让「暂停音乐」变成「暂停电台」、让进度条拿
// 一个永远 NaN 的时长去画。这里单独一台 `Player`，两条链路互不打扰：
//   * 电台开播（含续播）前由装配层把音乐暂停（`RadioState.onTuned`）；
//   * 离开电台页时把电台停掉，音乐页回到「已暂停」的干净状态。
//
// 事件表比 [AudioDriver] 小得多：电台只有「在响 / 在缓冲 / 出错」三件事，
// 外加一条播放头位置 —— 它不画进度（电台无限长、不可 seek），只用来回答
// 「声音到底有没有在往前走」：mpv 的 `core-idle` 会让 `buffering` 在正常出声时
// 反复翻 true/false，只有位置推进才是真的在响。
import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// 电台播放内核。
abstract class RadioEngine {
  /// 打开一条直播流（不自动播放）。
  Future<bool> open(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> setVolume(double value);
  Future<void> dispose();

  Stream<bool> get playingStream;
  Stream<bool> get loadingStream;
  Stream<String> get errorStream;

  /// 播放头位置（只用于判断「有没有在走」，不用于画进度）。
  Stream<Duration> get positionStream;

  /// 流「放完」的那一下（mpv 的 `completed`）。直播流本该无限长，但这几条
  /// 上游 CDN 会把长连接掐掉，掐完 mpv 就把 `completed` 当「播到头」发出来 ——
  /// 与用户按下暂停长得一样，只能靠这条流把它区分开、交给上层重连。
  Stream<bool> get completedStream;

  bool get isPlaying;
}

/// media_kit 实现。`Player` **懒建**：只有第一次 `open` 才去碰原生库 ——
/// 组件测试里构造 `RadioState` 不该为了一个没播过的电台把 libmpv 拉起来。
class MediaKitRadioEngine implements RadioEngine {
  Player? _player;
  bool _disposed = false;

  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _loadingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _positionSub;

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final player = Player();
    _player = player;
    _playingSub = player.stream.playing.listen((value) => _push(_playing, value));
    _loadingSub = player.stream.buffering.listen(
      (value) => _push(_loading, value),
    );
    _completedSub = player.stream.completed.listen(
      (value) => _push(_completed, value),
    );
    _positionSub = player.stream.position.listen(
      (value) => _push(_position, value),
    );
    _errorSub = player.stream.error.listen((message) {
      // mpv 的 error 日志里混着「外挂字幕 / 文件缓存」这类不影响主音频链的噪音
      // （同一份名单见 `playback/media_kit_driver.dart`），电台没有外挂资源，
      // 但缓存告警照样会冒出来 —— 过滤掉，只把真正可能影响出声的留下来。
      if (MediaKitRadioEngine.isNonFatalNoise(message)) return;
      _push(_errors, message);
    });
    return player;
  }

  /// 与 `MediaKitDriver.isNonFatalAttachmentError` 同一套形状，外加电台侧
  /// 常见的 `Failed to open ... cache` 变体。
  static bool isNonFatalNoise(String message) =>
      message.contains('Can not open external file') ||
      message.contains('Failed to create file cache') ||
      message.contains('Cache ended before') ||
      message.contains('Failed to recognize file format');

  @override
  Future<bool> open(String url) async {
    if (_disposed) return false;
    try {
      await _ensure().open(Media(url), play: false);
      return true;
    } catch (error) {
      _push(_errors, error.toString());
      return false;
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    try {
      await _ensure().play();
    } catch (error) {
      _push(_errors, error.toString());
    }
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    try {
      await _ensure().pause();
    } catch (_) {
      // 暂停失败没有可操作的东西，静默
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _ensure().stop();
    } catch (_) {
      // 同上
    }
  }

  /// 0~1 -> mpv 的 0~100（与 `MediaKitDriver.setVolume` 同一标度）。
  @override
  Future<void> setVolume(double value) async {
    if (_disposed) return;
    try {
      await _ensure().setVolume(value * 100);
    } catch (_) {
      // 同上
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _playingSub?.cancel();
    await _loadingSub?.cancel();
    await _errorSub?.cancel();
    await _completedSub?.cancel();
    await _positionSub?.cancel();
    try {
      await _player?.dispose();
    } catch (_) {
      // 原生实例释放失败不反过来打断收尾
    }
    _player = null;
    await _playing.close();
    await _loading.close();
    await _errors.close();
    await _completed.close();
    await _position.close();
  }

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  bool get isPlaying => _player?.state.playing ?? false;

  void _push<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}

/// 可脚本化的替身：测试注入它，既不开原生库、也不打网络。
class FakeRadioEngine implements RadioEngine {
  final List<String> calls = <String>[];

  /// 下一次 `open` 是否失败（模拟不可达 / 被墙的流）。
  bool failNextOpen = false;

  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  bool _playingValue = false;
  bool _disposed = false;

  void emitPlaying(bool value) {
    _playingValue = value;
    _push(_playing, value);
  }

  void emitLoading(bool value) => _push(_loading, value);

  /// 推一条播放头位置：真出声道具用它表示「声音在往前走」。
  void emitPosition(Duration value) => _push(_position, value);

  void emitError(String message) => _push(_errors, message);

  /// 模拟「上游把长连接掐掉、mpv 当播到头」：先落 playing=false 再发 completed。
  void emitCompleted() {
    emitPlaying(false);
    _push(_completed, true);
  }

  @override
  Future<bool> open(String url) async {
    calls.add('open:$url');
    if (failNextOpen) {
      failNextOpen = false;
      _push(_errors, 'stream unreachable');
      return false;
    }
    return true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emitPlaying(false);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emitPlaying(false);
  }

  @override
  Future<void> setVolume(double value) async {
    calls.add('volume:${value.toStringAsFixed(2)}');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (_disposed) return;
    _disposed = true;
    await _playing.close();
    await _loading.close();
    await _errors.close();
    await _completed.close();
    await _position.close();
  }

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  bool get isPlaying => _playingValue;

  void _push<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}
