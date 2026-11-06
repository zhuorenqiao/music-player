// lib/state/player_state.dart
//
// 播放器状态：对译原版 `state/player.tsx` 的「持久化时机」与对外 getter。
// 播放编排本身在 [TransportController]，这里只做两件事：
//   1. 把冷启动要读回的音量 / 静音 / 模式读一次（[ready]）；
//   2. 在语义变化时把 currentId / order / mode 节流写回 prefs（[schedulePersist]）。
//
// **进度不经过 ChangeNotifier**：position / buffered / duration 三个
// ValueNotifier 直接从 transport 透出，界面用 `ValueListenableBuilder` 只重绘
// 进度条那几片叶子。把它们接进 notifyListeners 就是原版记录过的「一秒四次
// 整树重绘」，这里不许再走那条路。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../playback/audio_driver.dart' show FakeAudioDriver;
import '../playback/audio_player.dart';
import '../playback/play_mode.dart';
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/transport_controller.dart';

/// 播放态持久化的防抖窗口（毫秒）。
///
/// 切歌 / 暂停恢复会连着产生好几次语义变化，一次落盘就够；400ms 也让
/// 「连续点下一首」只在停手之后写一次。
const int kPersistDebounceMs = 400;

/// 播放器状态层。
class PlayerState extends ChangeNotifier {
  PlayerState({required this.prefs, required this.transport}) {
    _sub = transport.player.events.listen(_onEvent);
    transport.view.addListener(_onView);
    // 冷启动就把音量读回来，首帧的滑块位置才是对的；重复调用由 [ready] 去重。
    unawaited(ready());
  }

  final AppPrefs prefs;
  final TransportController transport;

  late final StreamSubscription<PlayerEvent> _sub;
  Timer? _persistDebounce;
  Future<void>? _readyFuture;
  bool _ready = false;
  bool _disposed = false;

  /// 播放进度（秒）。只推订阅者，不通知 [ChangeNotifier]。
  ValueNotifier<double> get position => transport.position;

  /// 已缓冲到的秒数；内核还没报过是 null。
  ValueNotifier<double?> get buffered => transport.buffered;

  /// 当前曲目总时长；未知时 null。
  ValueNotifier<double?> get duration => transport.duration;

  /// 播放态快照（播放中 / 加载中 / 模式 / 音量…）。
  ValueNotifier<TransportView> get view => transport.view;

  Track? get current => transport.current;
  bool get playing => transport.playing;
  double get volume => transport.player.volume;
  bool get muted => transport.player.muted;
  String? get blockedMessage => transport.blockedMessage;
  bool get circuitOpen => transport.circuitOpen;

  /// 冷启动读回音量 / 静音 / 模式，只做一次。
  ///
  /// 构造时已经开始跑了；需要「读完了再断言」的测试 / 启动流程可以 await 它。
  Future<void> ready() => _readyFuture ??= _loadPersistedPrefs();

  Future<void> _loadPersistedPrefs() async {
    if (_ready) return;
    _ready = true;
    final volume = await prefs.readNumber(
      StorageKeys.volume,
      min: 0,
      max: 1,
    );
    if (volume != null) await transport.setVolume(volume.toDouble());
    if (await prefs.readBool(StorageKeys.muted)) {
      await transport.player.setMuted(true);
    }
    final mode = await prefs.readString(StorageKeys.mode);
    if (mode != null) {
      transport.playlist.setMode(playModeFromId(mode));
      // setMode 不改 view，模式变化得自己通知一次（界面据此换循环按钮图标）
      if (!_disposed) notifyListeners();
    }
  }

  /// 真的开始出声才落盘：暂停 / 加载失败都不该写 currentId。
  void _onEvent(PlayerEvent event) {
    if (event is StateChangedEvent && event.playing) schedulePersist();
  }

  void _onView() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> playTrack(String id) async {
    await transport.playTrack(id);
    schedulePersist();
  }

  Future<void> togglePlay() async {
    await transport.togglePlay();
    schedulePersist();
  }

  Future<void> next() => transport.next();

  Future<void> previous() => transport.previous();

  /// 循环切换模式（列表 → 单曲 → 随机）。模式立即落 prefs。
  void cycleMode() {
    transport.cycleMode();
    unawaited(
      prefs.writeString(StorageKeys.mode, transport.playlist.mode.name),
    );
    notifyListeners();
  }

  /// 设置音量：只写 `volume`，静音标志按播放层的真实读数写。
  ///
  /// 以前这里有一句 `writeBool(muted, value == 0)` —— 原版没有的行为：拖到 0
  /// 之后重启读回来是「已静音」，用户取消静音也解不掉（音量还是 0），看起来
  /// 像坏了。原版 `volume` 与 `muted` 是两个独立键，`setVolume(>0)` 由播放层
  /// 顺手清掉 muted（`src/lib/player.js:315-324`），这里只如实反映它的结果
  /// （终审 I3 + T13 那条 deferred minor）。
  Future<void> setVolume(double value) async {
    await transport.setVolume(value);
    await prefs.writeNumber(StorageKeys.volume, value);
    await prefs.writeBool(StorageKeys.muted, transport.player.muted);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    await transport.toggleMute();
    // 静音标志以播放层的实现为准（取消静音可能顺手恢复记忆音量）
    await prefs.writeBool(StorageKeys.muted, transport.player.muted);
    notifyListeners();
  }

  Future<bool> seekTo(double seconds) => transport.seekTo(seconds);

  Future<bool> seekBy(double delta) => transport.seekBy(delta);

  /// 页面里一次真实交互：被自动播放策略拦住时由界面调用。
  Future<void> userGesture() => transport.userGesture();

  /// 排一次落盘（400ms 防抖）。连续切歌只写最后一次。
  void schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(
      const Duration(milliseconds: kPersistDebounceMs),
      () => unawaited(flushPersist()),
    );
  }

  /// 立刻落盘：currentId / order / mode。
  ///
  /// currentId **如实同步**（终审 I4，取方案 (b)）：光标没了或指向一首已知坏掉
  /// 的曲目时把键删掉，而不是留着上一次的旧值。以前只有「非空且不损坏」才写、
  /// 从不删，于是停止播放 / 当前曲目变损坏 / 列表被清空之后重启，会复活一个
  /// 指向不该再播的曲目的 currentId —— 原版每次变化都写（包括 `Storage.remove`）。
  ///
  /// `order` 同样按当前列表重写：**列表顺序的权威永远是文件仓**（`LibraryState.
  /// restore` 只按它重建列表），prefs 这份是「最后一次现场」——它与文件仓逐位
  /// 一致时，[StorageKeys.currentId] 会被还原当成最新光标（播放推进只写 prefs、
  /// 不重写文件仓）；对不上就整份按陈旧处理。规则见 `LibraryState.restore`。
  ///
  /// 这里**不写 volume / muted**（终审 A1）：那两个键由 [setVolume] / [toggleMute]
  /// 各自即时写死（与原版同一处，`src/state/player.tsx:333` / `:338`），存档路径
  /// 上是「谁改谁立刻落盘」；在防抖落盘里补一句 `writeNumber(volume, player.volume)`
  /// 反而会把音量写成 0 —— 本层的 `volume` 读数在静音时就是 0（UI 靠它画静音图标）。
  Future<void> flushPersist() async {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final playlist = transport.playlist;
    await _syncCurrentIdAndOrder(playlist);
    await prefs.writeString(StorageKeys.mode, playlist.mode.name);
  }

  /// 按当前列表写 / 清 `currentId` 与 `order` 两个键（[flushPersist] 与
  /// `LibraryState.persist` 共用同一条规则，避免两处各写一半）。
  Future<void> _syncCurrentIdAndOrder(Playlist playlist) async {
    final current = playlist.current;
    if (current == null || current.broken) {
      await prefs.remove(StorageKeys.currentId);
    } else {
      await prefs.writeString(StorageKeys.currentId, current.id);
    }
    await prefs.writeJson(
      StorageKeys.order,
      playlist.tracks.map((t) => t.id).toList(),
    );
  }

  /// 无 IO 的测试构造（T28 的 PanelHarness 用）：假驱动 + 内存 prefs。
  @visibleForTesting
  factory PlayerState.fake(Playlist playlist) => PlayerState(
    prefs: AppPrefs.inMemory(),
    transport: TransportController(
      player: AudioPlayer(FakeAudioDriver()),
      recent: const _NullRecent(),
      toasts: const _SilentToasts(),
      playlist: playlist,
    ),
  );

  @override
  void dispose() {
    _disposed = true;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    transport.view.removeListener(_onView);
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// fake 构造用：不记最近播放。
class _NullRecent implements RecentRecorder {
  const _NullRecent();

  @override
  void record(Track track, {DateTime? at}) {}
}

/// fake 构造用：吞掉全部提示。
class _SilentToasts implements ToastSink {
  const _SilentToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message) {}
}
