// lib/playback/media_session_bridge.dart
//
// 系统媒体会话的边界（spec §7.1）：Android 通知栏 / 锁屏与 Windows SMTC
// 都从这一层进来，但**外部动作一律走 [TransportController] 的既有方法**。
// 这里只做两件事：
//   - 「界面 → 系统」：把 [TransportView] 与播放器事件压成 [PublishedSnapshot] 推给 bridge；
//   - 「系统 → 界面」：把 bridge 的 [MediaSessionCommand] 翻译成 transport 调用。
// 绝不出现第二条播放控制路径 —— 于是锁屏按钮与界面按钮共享模式、熔断、
// 损坏跳过、最近播放记录这些语义，不用为媒体键再写一遍。
//
// 推流节流：position 每秒最多推一次（timeupdate 每秒好几次，原样转发会把
// 通知栏的进度条打满系统 IPC）；元数据 / 播放态 / 模式等字段变化立即推。
// 只有 position 不同的快照也按同样规则节流，完全相同的快照不重复推，
// 避免无谓刷新通知。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_player.dart';
import 'play_mode.dart';
import 'track.dart';
import 'transport_controller.dart';

/// position 推送的最小间隔（毫秒）。系统侧进度条不需要比这更细。
const int kMediaPositionPublishIntervalMs = 1000;

/// 系统侧发来的动作。Android 通知栏与 Windows SMTC 的按钮 / 媒体键都归到这里。
sealed class MediaSessionCommand {
  const MediaSessionCommand();
}

/// 播放：从当前位置继续当前曲目（等价于界面上的播放按钮，进度不打回 0）。
class PlayCommand extends MediaSessionCommand {
  const PlayCommand();
}

/// 暂停。只暂停播放内核，不换曲、不清进度。
class PauseCommand extends MediaSessionCommand {
  const PauseCommand();
}

/// 下一首：与界面按钮同一入口，随机模式下按洗牌队列推进。
class NextCommand extends MediaSessionCommand {
  const NextCommand();
}

/// 上一首：沿用「已播放超过 3 秒则回本曲开头」的既有语义。
class PreviousCommand extends MediaSessionCommand {
  const PreviousCommand();
}

/// 停止：暂停并清空当前曲目（回到空态），播放列表原样保留。
class StopCommand extends MediaSessionCommand {
  const StopCommand();
}

/// 拖动系统侧进度条。[seconds] 是目标位置（秒），走与界面同一套 seek 守卫。
class SeekCommand extends MediaSessionCommand {
  const SeekCommand(this.seconds);

  final double seconds;
}

/// 系统侧认识的循环模式。界面是 [PlayMode] 的三态，系统只有这三档：
/// `list` 与 `shuffle` 都是「整列表循环」，随机与否由 `shuffleEnabled` 单独表达。
enum MediaRepeatMode { off, all, one }

/// 一次推给系统的状态快照。字段全部是与平台无关的值，bridge 实现负责翻译。
@immutable
class PublishedSnapshot {
  const PublishedSnapshot({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.artUri,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.shuffleEnabled = false,
    this.repeatMode = MediaRepeatMode.off,
  });

  /// 曲名；没有当前曲目时为空串。
  final String title;
  final String artist;
  final String album;

  /// 封面的本地文件路径或 URI；没有真封面时 null（生成卡不在这里，spec §12）。
  final String? artUri;

  final bool playing;

  /// 当前播放位置。
  final Duration position;

  /// 总时长；未知时 null（通知栏据此不画进度条）。
  final Duration? duration;

  final bool shuffleEnabled;
  final MediaRepeatMode repeatMode;

  @override
  bool operator ==(Object other) =>
      other is PublishedSnapshot &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artUri == artUri &&
      other.playing == playing &&
      other.position == position &&
      other.duration == duration &&
      other.shuffleEnabled == shuffleEnabled &&
      other.repeatMode == repeatMode;

  @override
  int get hashCode => Object.hash(
    title,
    artist,
    album,
    artUri,
    playing,
    position,
    duration,
    shuffleEnabled,
    repeatMode,
  );

  @override
  String toString() =>
      'PublishedSnapshot(title: $title, artist: $artist, album: $album, '
      'artUri: $artUri, playing: $playing, position: $position, '
      'duration: $duration, shuffleEnabled: $shuffleEnabled, '
      'repeatMode: ${repeatMode.name})';
}

/// 平台媒体会话的接口。T22 用 `flutter_media_session` 实现 Android 与 Windows
/// 两个通道；本任务只定义边界与测试替身，不引任何平台代码。
abstract class MediaSessionBridge {
  /// 注册会话与按钮回调。幂等由实现决定，协调器只调一次。
  Future<void> start();

  /// 停掉会话（没有当前曲目时通知栏应回到空状态）。
  Future<void> stop();

  /// 推一次状态。实现方负责只推送真正变化的字段。
  Future<void> publish(PublishedSnapshot snapshot);

  /// 外部动作（通知栏按钮、锁屏、媒体键）的入口。
  Stream<MediaSessionCommand> get commands;

  Future<void> dispose();
}

/// 记录型替身：测试用它断言「推了什么」与「收到什么指令」。
///
/// [calls] 只记录生命周期调用（`start` / `stop` / `dispose`），推送内容在
/// [published] 里，避免同一个动作出现两处以不同形状存在。
class FakeMediaSessionBridge implements MediaSessionBridge {
  final List<PublishedSnapshot> published = [];
  final List<String> calls = [];
  final StreamController<MediaSessionCommand> _controller =
      StreamController<MediaSessionCommand>.broadcast();

  int get startCount => calls.where((call) => call == 'start').length;
  int get stopCount => calls.where((call) => call == 'stop').length;

  /// 注入一次系统侧动作。
  void emit(MediaSessionCommand command) => _controller.add(command);

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> publish(PublishedSnapshot snapshot) async =>
      published.add(snapshot);

  @override
  Stream<MediaSessionCommand> get commands => _controller.stream;

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _controller.close();
  }
}

/// 界面状态 ⇄ 系统会话的唯一桥。动作全部交给 transport，
/// 于是锁屏 / 媒体键与界面按钮共用模式、熔断、最近播放语义（spec §7.1）。
class MediaSessionCoordinator {
  MediaSessionCoordinator({
    required this.bridge,
    required this.transport,
    this.artUriFor,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MediaSessionBridge bridge;
  final TransportController transport;

  /// 封面 URI 的额外加工（T22 可能要转成 `file://` 或落一张缩略图）；
  /// 缺省直接用 `track.cover`。
  final String Function(Track)? artUriFor;

  final int Function() _nowMs;

  StreamSubscription<MediaSessionCommand>? _commandSub;
  StreamSubscription<PlayerEvent>? _playerSub;
  VoidCallback? _viewListener;
  PublishedSnapshot? _last;
  int _lastPublishMs = 0;
  int _publishCount = 0;
  bool _attached = false;
  bool _stoppedWithoutTrack = false;

  /// 成功推给 bridge 的快照条数（节流 / 去重之后的真实推送次数）。
  int get publishCount => _publishCount;

  /// 接上会话：启动 bridge、订阅指令与状态、并立刻推一次当前快照。
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    await bridge.start();
    _commandSub = bridge.commands.listen(_onCommand);
    _playerSub = transport.player.events.listen(_onPlayerEvent);
    _viewListener = () => _publish();
    transport.view.addListener(_viewListener!);
    _publish();
  }

  /// 系统侧动作 → transport 的既有方法。这里是唯一的翻译点。
  ///
  /// 播放走 [TransportController.resume]（不重载、接着放），停止走
  /// [TransportController.stopPlayback]（暂停 + 清当前曲目 → 空态）：
  /// 锁屏按钮与界面按钮的听觉与数据结果必须一致，不能给系统留第二条路径。
  void _onCommand(MediaSessionCommand command) {
    switch (command) {
      case PlayCommand():
        unawaited(transport.resume());
      case PauseCommand():
        unawaited(transport.player.pause());
      case NextCommand():
        unawaited(transport.next());
      case PreviousCommand():
        unawaited(transport.previous());
      case StopCommand():
        unawaited(transport.stopPlayback());
      case SeekCommand(:final seconds):
        unawaited(transport.seekTo(seconds));
    }
  }

  /// 播放器事件只补 view 不覆盖的部分：进度、以及内核回报的时长。
  void _onPlayerEvent(PlayerEvent event) {
    if (event is TimeUpdateEvent) {
      // 用事件自带的位置：它比 transport.position 更直接，不依赖订阅顺序。
      _publish(positionSeconds: event.position);
      return;
    }
    _publish();
  }

  void _publish({double? positionSeconds}) {
    final now = _nowMs();
    final view = transport.view.value;
    final track = view.current;
    final snapshot = PublishedSnapshot(
      title: track?.title ?? '',
      artist: track?.artist ?? '',
      album: track?.album ?? '',
      artUri: _artUriOf(track),
      playing: view.playing,
      position: _asDuration(positionSeconds ?? transport.position.value),
      duration: _durationOf(track),
      shuffleEnabled: view.mode == PlayMode.shuffle,
      repeatMode: _repeatModeOf(view.mode),
    );

    final last = _last;
    if (last != null) {
      if (_sameMetadata(snapshot, last)) {
        // 语义没变：只剩进度差异，按节流窗口推。
        if (snapshot.position == last.position) return;
        if (now - _lastPublishMs < kMediaPositionPublishIntervalMs) return;
      }
    }

    _last = snapshot;
    _lastPublishMs = now;
    _publishCount += 1;

    if (track == null) {
      // 空状态：通知栏 / SMTC 只该被停一次，反复 stop 会打平台日志。
      if (!_stoppedWithoutTrack) {
        _stoppedWithoutTrack = true;
        unawaited(bridge.stop());
      }
    } else {
      _stoppedWithoutTrack = false;
    }
    unawaited(bridge.publish(snapshot));
  }

  /// 除 position 外全部字段相同即视为「语义未变」：position 单独走节流，
  /// 不能把它算进判等，否则进度每秒一次的节流永远不会生效。
  bool _sameMetadata(PublishedSnapshot a, PublishedSnapshot b) =>
      a.title == b.title &&
      a.artist == b.artist &&
      a.album == b.album &&
      a.artUri == b.artUri &&
      a.playing == b.playing &&
      a.duration == b.duration &&
      a.shuffleEnabled == b.shuffleEnabled &&
      a.repeatMode == b.repeatMode;

  String? _artUriOf(Track? track) {
    if (track == null) return null;
    final uri = artUriFor?.call(track) ?? track.cover;
    return uri.isEmpty ? null : uri;
  }

  /// 时长优先取内核回报（可能修正标签里的值），没有再退回曲目自己的时长。
  Duration? _durationOf(Track? track) {
    final reported = transport.duration.value;
    if (reported != null && reported.isFinite && reported > 0) {
      return _asDuration(reported);
    }
    if (track != null && track.hasDuration) return _asDuration(track.duration);
    return null;
  }

  /// `list` 与 `shuffle` 在系统侧都是「整列表循环」，随机单独由
  /// [PublishedSnapshot.shuffleEnabled] 表达；界面的三态没有「不循环」档，
  /// 所以 [MediaRepeatMode.off] 只会出现在空状态里。
  MediaRepeatMode _repeatModeOf(PlayMode mode) =>
      mode == PlayMode.one ? MediaRepeatMode.one : MediaRepeatMode.all;

  static Duration _asDuration(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return Duration.zero;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Future<void> dispose() async {
    if (!_attached) return;
    _attached = false;
    await _commandSub?.cancel();
    _commandSub = null;
    await _playerSub?.cancel();
    _playerSub = null;
    final listener = _viewListener;
    if (listener != null) {
      transport.view.removeListener(listener);
      _viewListener = null;
    }
    await bridge.stop();
    await bridge.dispose();
  }
}
