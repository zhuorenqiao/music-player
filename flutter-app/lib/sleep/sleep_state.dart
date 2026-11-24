// lib/sleep/sleep_state.dart
//
// 休眠模块的播放状态（Flutter）。
//
// 与电台同一套思路：**独立的第三条音频链路**（一台单独的 media_kit Player），
// 不经过曲库播放器 —— 休眠是「无限循环的声景」，混进 PlayerState 会让进度条
// 拿一个假时长、让「暂停音乐」变成「暂停声景」。
//
// 三条互斥规则（与 React `src/state/sleep.tsx` 逐条一致）：
//   1. 开始 / 续播休眠前，先暂停音乐与电台；
//   2. 音乐或电台一开声，休眠自动让位（保留当前曲目，回到休眠页可续播）；
//   3. 离开休眠页**不停声**：睡前声景要在后台一直放，音乐页底部的迷你条
//      交代「还在响的是哪一段」，想关掉只有条上的关闭或回到页面按暂停。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../radio/radio_state.dart';
import '../state/player_state.dart';
import 'sleep_audio.dart';
import 'sleep_track.dart';

/// 略低于音乐音量：睡前声景是「垫在环境里的」，不该抢过正常听歌的响度。
const double _kTargetVolume = 0.72;

/// 起播淡入时长：从 0 缓缓推到目标音量，避免「啪」一下出声。
const int _kFadeInMs = 1400;

class SleepState extends ChangeNotifier {
  SleepState({
    required PlayerState player,
    required RadioState radio,
    SleepAudioEngine? engine,
    SleepAudioCache? cache,
    this.onStateChanged,
  }) : _engine = engine ?? MediaKitSleepEngine(),
       _cache = cache ?? SleepAudioCache() {
    // 私有字段 + 命名参数：命名参数不能以下划线开头，所以只能进构造函数体赋值。
    _player = player;
    _radio = radio;
    _playingSub = _engine.playingStream.listen(_onEnginePlaying);
    _loadingSub = _engine.loadingStream.listen(_onEngineLoading);
    _errorSub = _engine.errorStream.listen(_onEngineError);
    _player.addListener(_onExternalAudio);
    _radio.addListener(_onExternalAudio);
  }

  late final PlayerState _player;
  late final RadioState _radio;
  final SleepAudioEngine _engine;
  final SleepAudioCache _cache;

  /// 测试 / 媒体会话用的观察钩子：状态一变就回调（不改变内部状态）。
  final VoidCallback? onStateChanged;

  SleepTrack? _current;
  bool _playing = false;
  bool _loading = false;
  String? _error;
  bool _disposed = false;

  /// 当前曲目是否已经成功 open 过。暂停不会卸载媒体，所以续播只需 play；
  /// 只有首次起播 / 换曲 / 失败重试才重新读文件。
  bool _loaded = false;

  /// 异步起播守卫：用户连点两条时，只让最后一次落定。
  int _token = 0;

  /// 淡入的定时器：换曲 / 暂停时立刻掐掉。
  Timer? _fadeTimer;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _loadingSub;
  StreamSubscription<String>? _errorSub;

  SleepTrack? get current => _current;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasCurrent => _current != null;

  Future<void> tune(SleepTrack track) async {
    final token = ++_token;
    _cancelFade();
    _current = track;
    _playing = false;
    _loading = true;
    _loaded = false;
    _error = null;
    _notify();

    // 三条链路都先让位：不做这一步就是两路声音叠在一起。旧声景也要先停，
    // 否则换曲时它会一直响到新文件 open 完。
    await _engine.pause();
    await _player.pause();
    await _radio.pause();
    if (_disposed || token != _token) return;

    try {
      final path = await _cache.fileFor(track);
      if (_disposed || token != _token) return;
      final opened = await _engine.open(path);
      if (_disposed || token != _token) return;
      if (!opened) {
        _loading = false;
        _playing = false;
        _error = '这段声景没能出声，再点一次试试';
        _notify();
        return;
      }
      _loaded = true;
      // 生成期间用户可能又按了音乐 / 电台：再让一次，别让两路一起响
      if (_player.playing || _radio.playing) {
        await _player.pause();
        await _radio.pause();
      }
      await _engine.setVolume(0);
      await _engine.play();
      if (_disposed || token != _token) return;
      _startFadeIn();
    } catch (error) {
      if (_disposed || token != _token) return;
      _loading = false;
      _playing = false;
      _error = '这段声景没能出声，再点一次试试';
      _notify();
    }
  }

  Future<void> toggle() async {
    final track = _current;
    if (track == null) {
      await tune(kSleepFirstTrack);
      return;
    }
    if (_playing) {
      await pause();
      return;
    }
    await resume();
  }

  Future<void> resume() async {
    final track = _current;
    if (track == null) return;
    final token = ++_token;
    _cancelFade();
    _error = null;
    _loading = true;
    _notify();

    await _player.pause();
    await _radio.pause();
    if (_disposed || token != _token) return;

    try {
      // 首次起播才读文件；暂停 / 续播时媒体还挂在 Player 上，直接 play。
      if (!_loaded) {
        final path = await _cache.fileFor(track);
        if (_disposed || token != _token) return;
        final opened = await _engine.open(path);
        if (_disposed || token != _token) return;
        if (!opened) {
          _loading = false;
          _error = '这段声景没能出声，再点一次试试';
          _notify();
          return;
        }
        _loaded = true;
      }
      if (_disposed || token != _token) return;
      if (_player.playing || _radio.playing) {
        await _player.pause();
        await _radio.pause();
      }
      await _engine.setVolume(0);
      await _engine.play();
      if (_disposed || token != _token) return;
      _startFadeIn();
    } catch (error) {
      if (_disposed || token != _token) return;
      _loading = false;
      _error = '这段声景没能出声，再点一次试试';
      _notify();
    }
  }

  /// 无条件往暂停走（保留当前曲目；睡眠定时器到点也走它）。
  Future<void> pause() async {
    _token++;
    _cancelFade();
    _playing = false;
    _loading = false;
    _notify();
    await _engine.pause();
  }

  /// 关掉（清空当前曲目，页面回到「还没开始」）。
  Future<void> stop() async {
    _token++;
    _cancelFade();
    _current = null;
    _playing = false;
    _loading = false;
    _loaded = false;
    _error = null;
    _notify();
    await _engine.stop();
    await _engine.setVolume(0);
  }

  void _startFadeIn() {
    _cancelFade();
    // 用 tick 计数而不是墙钟：testWidgets 的 FakeAsync 会拨动 Timer，但
    // DateTime.now() 不动；按 tick 走，组件测试里也能正常收尾。
    final totalTicks = _kFadeInMs ~/ 80;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final progress = (timer.tick / totalTicks).clamp(0.0, 1.0);
      final eased = 1 - (1 - progress) * (1 - progress) * (1 - progress);
      unawaited(_engine.setVolume(_kTargetVolume * eased));
      if (progress >= 1) {
        timer.cancel();
        _fadeTimer = null;
      }
    });
  }

  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
  }

  /// 音乐 / 电台一开声，休眠让位（当前曲目保留，回页面可续播）。
  void _onExternalAudio() {
    if (_disposed || !_playing) return;
    if (_player.playing || _radio.playing) {
      unawaited(pause());
    }
  }

  void _onEnginePlaying(bool value) {
    if (_disposed) return;
    _playing = value;
    if (value) _loading = false;
    _notify();
  }

  void _onEngineLoading(bool value) {
    if (_disposed) return;
    // 本地 WAV 只在首次解码时短暂 buffering；没有当前曲目时不要冒转圈
    _loading = value && _current != null;
    _notify();
  }

  void _onEngineError(String message) {
    if (_disposed) return;
    _playing = false;
    _loading = false;
    _loaded = false;
    _error = '这段声景没能出声，再点一次试试';
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    onStateChanged?.call();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelFade();
    _playingSub?.cancel();
    _loadingSub?.cancel();
    _errorSub?.cancel();
    _player.removeListener(_onExternalAudio);
    _radio.removeListener(_onExternalAudio);
    unawaited(_engine.dispose());
    super.dispose();
  }
}
