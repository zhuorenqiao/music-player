// lib/playback/transport_controller.dart
//
// 播放编排：对译 src/state/player.tsx 的「播放编排」（254-347）与
// 「播放器事件」（403-479）两段。职责边界：
//   - 曲目切换的入口只有 [playTrack]，上下曲 / 自动跳 / 损坏跳 / 曲末续播都汇到它；
//   - 曲末自动续播：`CompletedEvent` -> `next(auto: true)`（player.tsx:441），熔断后停手；
//   - 上一首的三秒规则（constants.ts:46 PREV_RESTART_AFTER）；
//   - 加载失败 -> 打角标 + 1400ms 后自动跳，连续失败到列表长度就熔断；
//   - 失败计数只在 canplay 清零（player.tsx:412 的清零点），位置 / 播放态不许洗它；
//   - 真的出声（position > 0 的 timeupdate）才记最近播放，500ms 内同曲不重复。
//
// 延时任务全部走可注入的 [DelayScheduler]：测试注入假时钟，生产用真 Timer。
// 进度（position / buffered / duration）走独立 ValueNotifier —— timeupdate 每秒
// 好几次，绝不能触发 [view] 的通知（否则整个界面跟着每一帧重绘）。
import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';

import 'audio_player.dart';
import 'play_mode.dart';
import 'playlist.dart';
import 'track.dart';

/// 最近播放记录接口。排序、去重、截断都归实现
/// （T16 用 `RecentStore` 实现，对齐 recent-store.js:69-99：
/// 同 id 复用旧条目并置顶，绝不产生重复项）。
abstract class RecentRecorder {
  /// 记一次播放。[at] 是这次播放的时间，缺省由实现取当前时间。
  void record(Track track, {DateTime? at});
}

/// 提示条接口（T20 用 `ToastState` 实现）。
///
/// [show] 的 [key] 相同即原地改文案并重新计时，不叠一条新的；
/// 需要「常驻」的事（被拦、全列表失败）用它，别用会自己消失的临时条。
abstract class ToastSink {
  void show(String message, {String key = '', int durationMs = 3200});
  void info(String message);
  void error(String message);
}

/// 取消一次已排的延时任务；幂等，重复调用无害。
typedef CancelDelay = void Function();

/// 延时调度入口。默认 `Timer`；测试注入可手动推进的假时钟。
typedef DelayScheduler =
    CancelDelay Function(Duration delay, void Function() callback);

/// 「上一首」回到本曲开头的阈值：已播放超过 3 秒就回开头而不是切曲。
const int kPrevRestartAfter = 3;

/// 损坏曲目自动跳下一首前的等待（毫秒）。
const int kBrokenSkipDelayMs = 1400;

/// 被拦的自动播放最多重试几次（constants.ts MAX_AUTOPLAY_RETRIES）。
const int kMaxAutoplayRetries = 3;

/// 同一首曲子两次记账的最小间隔（recent-store.js NOOP_WINDOW）。
const int kRecentDedupeMs = 500;

/// 界面订阅的播放态快照。只在「语义变化」时重建并推给 [TransportController.view]。
class TransportView {
  TransportView({
    this.playing = false,
    this.loading = false,
    this.circuitOpen = false,
    this.blocked,
    this.current,
    this.mode = PlayMode.list,
    this.volume = kDefaultVolume,
    this.muted = false,
  });

  final bool playing;
  final bool loading;
  final bool circuitOpen;

  /// 被拦的提示文案（非 null 即处于「等用户点一下」的状态）。
  final String? blocked;

  final Track? current;
  final PlayMode mode;
  final double volume;
  final bool muted;

  @override
  bool operator ==(Object other) =>
      other is TransportView &&
      other.playing == playing &&
      other.loading == loading &&
      other.circuitOpen == circuitOpen &&
      other.blocked == blocked &&
      other.mode == mode &&
      other.volume == volume &&
      other.muted == muted &&
      other.current?.id == current?.id;

  @override
  int get hashCode => Object.hash(
    playing,
    loading,
    circuitOpen,
    blocked,
    current?.id,
    mode,
    volume,
    muted,
  );

  @override
  String toString() =>
      'TransportView(playing: $playing, loading: $loading, '
      'circuitOpen: $circuitOpen, blocked: $blocked, '
      'current: ${current?.id}, mode: ${mode.name})';
}

/// 播放编排：模式、上下曲、损坏与熔断，最近播放记账。
class TransportController {
  TransportController({
    required this.player,
    required this.recent,
    required this.toasts,
    Playlist? playlist,
    int Function()? now,
    DelayScheduler? scheduler,
  }) : playlist = playlist ?? Playlist(tracks: const []),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _schedule = scheduler ?? _timerSchedule {
    _sub = player.events.listen(_onPlayerEvent);
    _syncProgressFrom(player);
    _publish();
  }

  final AudioPlayer player;
  final RecentRecorder recent;
  final ToastSink toasts;
  final Playlist playlist;
  final int Function() _now;
  final DelayScheduler _schedule;

  late final StreamSubscription<PlayerEvent> _sub;

  final ValueNotifier<double> _position = ValueNotifier<double>(0);
  final ValueNotifier<double?> _buffered = ValueNotifier<double?>(null);
  final ValueNotifier<double?> _duration = ValueNotifier<double?>(null);
  final ValueNotifier<TransportView> _view = ValueNotifier<TransportView>(
    TransportView(),
  );

  int _consecutiveFailures = 0;
  bool _circuitOpen = false;
  bool _loading = false;
  bool _disposed = false;
  String? _blockedMessage;
  int _blockedRetries = 0;
  CancelDelay? _cancelSkip;
  String _lastRecentId = '';
  int _lastRecentAt = 0;

  /// 播放进度（秒）。每次 timeupdate 都变，只推这个，不碰 [view]。
  ValueNotifier<double> get position => _position;

  /// 已缓冲到的秒数；内核还没报过是 null。
  ValueNotifier<double?> get buffered => _buffered;

  /// 当前曲目总时长；未知时 null（对齐原版 `Number.NaN` 的「未知」语义）。
  ValueNotifier<double?> get duration => _duration;

  /// 播放态快照。
  ValueNotifier<TransportView> get view => _view;

  Track? get current => playlist.current;
  bool get playing => player.playing;
  bool get loading => _loading;

  /// 熔断：一轮里每首都失败过，已停止自动跳转。canplay 后自动复原。
  bool get circuitOpen => _circuitOpen;

  /// 自上次真正可播（canplay）以来累计的失败次数。
  int get consecutiveFailures => _consecutiveFailures;

  /// 自动播放被拦时的文案，供界面画常驻提示条。
  String? get blockedMessage => _blockedMessage;

  double get volume => player.volume;
  bool get muted => player.muted;

  // -- 编排 ----------------------------------------------------------------

  /// 播放 [id] 指向的曲目。找不到 id 时什么都不做（不碰驱动、不弹提示）。
  Future<void> playTrack(String id, {bool autoplay = true}) async {
    final track = playlist.byId(id);
    if (track == null) return;
    // 换成别的曲目了：上一条 1400ms 待跳定时器与「等用户手势」状态都作废。
    _cancelPendingSkip();
    _blockedMessage = null;
    _blockedRetries = 0;
    playlist.setCurrentById(id);
    await _load(track, autoplay: autoplay);
  }

  /// 播放 / 暂停。没有当前曲目时从第一首开始。
  Future<void> togglePlay() async {
    if (playlist.size == 0) {
      toasts.info('播放列表为空，请先添加音频文件');
      return;
    }
    final track = playlist.current;
    if (track == null || player.track == null) {
      await playTrack((track ?? playlist.tracks.first).id);
      return;
    }
    if (player.playing) {
      await player.pause();
      return;
    }
    await _resume(track);
  }

  /// 下一首。[auto] 为 true 表示是播放器自己的动作（跳损坏、播完自动续），
  /// 交给 Playlist 决定单曲循环下原地重播。
  Future<void> next({bool auto = false}) async {
    final index = playlist.nextIndex(auto: auto);
    if (index < 0) return;
    await playTrack(playlist.tracks[index].id);
  }

  /// 上一首：已播放超过三秒先回本曲开头，否则真的切上一曲。
  Future<void> previous() async {
    if (playlist.size == 0) return;
    // 读驱动的实时位置而不是 position.value：事件是异步投递的，刚 seek 完
    // 可能还没到；原版这里读的也是 player.currentTime（player.tsx:290）。
    if (player.position > kPrevRestartAfter) {
      await player.seek(0);
      return;
    }
    final index = playlist.prevIndex();
    if (index < 0) return;
    await playTrack(playlist.tracks[index].id);
  }

  /// 循环切换播放模式（列表 → 单曲 → 随机）。
  PlayMode cycleMode() {
    final mode = playlist.cycleMode();
    // 同一个 key：连点只在原位置改文案并重新计时，不叠一条新的（player.tsx:346）
    toasts.show('播放模式：${playModeLabel(mode)}', key: 'play-mode', durationMs: 2000);
    _publish();
    return mode;
  }

  Future<bool> seekTo(double seconds) => player.seek(seconds);

  Future<bool> seekBy(double delta) => player.seekBy(delta);

  Future<void> setVolume(double value) async {
    await player.setVolume(value);
    // volumechange 事件是异步投递的；这里顺手推一次，调用方 await 完就能读到。
    _publish();
  }

  Future<void> toggleMute() async {
    await player.toggleMute();
    _publish();
  }

  /// 页面里一次真实交互：把被拦住的播放再拉一次，最多 [kMaxAutoplayRetries] 次。
  /// 用完就保持 [blockedMessage] 不变 —— 让用户自己点播放，绝不无限打转。
  Future<void> userGesture() async {
    final track = playlist.current;
    if (_blockedMessage == null || track == null) return;
    if (_blockedRetries >= kMaxAutoplayRetries) return;
    _blockedRetries += 1;
    await player.load(track, autoplay: true);
  }

  /// 停掉订阅与播放器。进度 notifier 不销毁：界面可能还挂着监听，等它自己放。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelPendingSkip();
    await _sub.cancel();
    await player.dispose();
  }

  // -- 内部 ----------------------------------------------------------------

  Future<void> _load(Track track, {required bool autoplay}) async {
    // 换曲后旧进度立刻作废：原版 goTo 把 time / buffered 归零、
    // duration 先取曲目自己的值，等内核回报再校正（player.tsx:264-266）。
    _position.value = 0;
    _buffered.value = 0;
    _duration.value = track.hasDuration ? track.duration : null;
    _publish();
    await player.load(track, autoplay: autoplay);
  }

  /// 暂停后恢复：从原位置接着放，而不是从头开始。
  Future<void> _resume(Track track) async {
    final sameTrack = player.track?.id == track.id;
    final resumeAt = sameTrack ? player.position : 0.0;
    _blockedMessage = null;
    _blockedRetries = 0;
    await player.load(track, autoplay: true);
    if (resumeAt > 0) await player.seek(resumeAt);
  }

  void _syncProgressFrom(AudioPlayer source) {
    _position.value = source.position;
    _buffered.value = source.buffered;
    _duration.value = source.duration;
  }

  void _onPlayerEvent(PlayerEvent event) {
    if (_disposed) return;
    switch (event) {
      case LoadingEvent(:final loading):
        _loading = loading;
        _publish();
      case CanplayEvent(:final duration):
        if (duration != null) _duration.value = duration;
        // 唯一清零点：真的能播了才算这一轮的失败结束。
        // 挪到 timeupdate / statechange 上，坏文件先出一声再崩就能把计数洗掉，
        // 熔断永远不会触发（原版靠这条保证「坏列表只走一圈」）。
        _consecutiveFailures = 0;
        _cancelPendingSkip();
        if (_circuitOpen) {
          _circuitOpen = false;
          toasts.info('播放已恢复');
        }
        _publish();
      case TimeUpdateEvent(:final position, :final duration):
        _position.value = position;
        if (duration != null) _duration.value = duration;
        // 这里只动进度：绝不 _publish()，否则每帧都重建整棵界面。
        _recordIfAudible(position);
      case StateChangedEvent():
        // statechange(true) 不清零失败计数：它之后仍可能立刻崩。
        _publish();
      case BufferedEvent(:final end):
        // 缓冲条只走独立 notifier，与 timeupdate 一样绝不 _publish()。
        _buffered.value = end;
      case CompletedEvent():
        // 原版 `ended` -> playNext({auto: true})（player.tsx:441）。熔断时停手，
        // 与损坏跳转同一条件；单曲循环由 Playlist.nextIndex(auto) 决定原地重播。
        if (circuitOpen) return;
        unawaited(next(auto: true));
      case VolumeEvent():
        _publish();
      case ErrorEvent(:final message):
        _handleFailure(message);
      case BlockedEvent(:final message):
        _blockedMessage = message;
        toasts.error(message);
        _publish();
    }
  }

  /// 只有真出声（位置推过 0）才记账；同一首 500ms 内不重复记。
  void _recordIfAudible(double position) {
    if (position <= 0) return;
    final track = playlist.current;
    if (track == null) return;
    final now = _now();
    if (track.id == _lastRecentId && now - _lastRecentAt < kRecentDedupeMs) {
      return;
    }
    _lastRecentId = track.id;
    _lastRecentAt = now;
    recent.record(track, at: DateTime.fromMillisecondsSinceEpoch(now));
  }

  void _handleFailure(String message) {
    final track = playlist.current;
    if (track != null) {
      track.broken = true;
      toasts.show(
        '$message（${track.title}）',
        key: 'broken-${track.id}',
        durationMs: 5000,
      );
    }
    _consecutiveFailures += 1;
    final limit = max(1, playlist.size);
    if (_circuitOpen || _consecutiveFailures >= limit) {
      _openCircuit();
      return;
    }
    _scheduleSkip();
  }

  /// 熔断：停手、暂停、常驻提示，不再排任何自动跳。
  void _openCircuit() {
    _cancelPendingSkip();
    _circuitOpen = true;
    toasts.show(
      '播放列表中的曲目都无法播放，已停止自动跳转。请检查音频文件后重新添加。',
      key: 'circuit',
      durationMs: 6400,
    );
    unawaited(player.pause().whenComplete(_publish));
    _loading = false;
    _publish();
  }

  void _scheduleSkip() {
    _cancelPendingSkip();
    _cancelSkip = _schedule(
      const Duration(milliseconds: kBrokenSkipDelayMs),
      () {
        _cancelSkip = null;
        if (_disposed || _circuitOpen) return;
        unawaited(next(auto: true));
      },
    );
  }

  void _cancelPendingSkip() {
    _cancelSkip?.call();
    _cancelSkip = null;
  }

  void _publish() {
    if (_disposed) return;
    _view.value = TransportView(
      playing: player.playing,
      loading: _loading,
      circuitOpen: _circuitOpen,
      blocked: _blockedMessage,
      current: playlist.current,
      mode: playlist.mode,
      volume: player.volume,
      muted: player.muted,
    );
  }

  static CancelDelay _timerSchedule(
    Duration delay,
    void Function() callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }
}
