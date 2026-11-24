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

/// 上一首：换歌（与 [NextCommand] 对称，不再有「回本曲开头」那套三秒规则）。
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

/// 卡片当前代表哪条播放链路。
///
/// App 只有一张系统媒体卡片（Android 一个会话一条通知、Windows 一个 SMTC），
/// 所以音乐与电台必须「谁在响谁接管」：由 [MediaSessionCoordinator] 按播放态
/// 动态选源，不能用两张会话各推各的。
enum MediaKind {
  /// 曲库里的歌。
  music,

  /// 电台 / 播客直播流。
  radio,
}

/// 一次推给系统的状态快照。字段全部是与平台无关的值，bridge 实现负责翻译。
@immutable
class PublishedSnapshot {
  const PublishedSnapshot({
    this.kind = MediaKind.music,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.artUri,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.live = false,
    this.artworkHue,
    this.shuffleEnabled = false,
    this.repeatMode = MediaRepeatMode.off,
  });

  /// 这条快照属于音乐还是电台。电台快照下系统按钮只剩播放 / 暂停 / 关闭。
  final MediaKind kind;

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

  /// 直播流：没有进度、不可拖动、不给上下曲。
  ///
  /// 与 [duration] 为 null 的区别是语义上的：未知时长只是「算不出来」，
  /// 直播是「永远没有终点」，系统卡片据此只画播放 / 暂停 / 关闭。
  final bool live;

  /// 生成卡的色相覆盖（0~360）。电台卡固定落在品牌绿附近，
  /// 音乐曲目为 null 时仍按「歌手名哈希」取色，和界面生成卡一致。
  final int? artworkHue;

  final bool shuffleEnabled;
  final MediaRepeatMode repeatMode;

  @override
  bool operator ==(Object other) =>
      other is PublishedSnapshot &&
      other.kind == kind &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artUri == artUri &&
      other.playing == playing &&
      other.position == position &&
      other.duration == duration &&
      other.live == live &&
      other.artworkHue == artworkHue &&
      other.shuffleEnabled == shuffleEnabled &&
      other.repeatMode == repeatMode;

  @override
  int get hashCode => Object.hash(
    kind,
    title,
    artist,
    album,
    artUri,
    playing,
    position,
    duration,
    live,
    artworkHue,
    shuffleEnabled,
    repeatMode,
  );

  @override
  String toString() =>
      'PublishedSnapshot(kind: ${kind.name}, title: $title, artist: $artist, '
      'album: $album, artUri: $artUri, playing: $playing, '
      'position: $position, duration: $duration, live: $live, '
      'artworkHue: $artworkHue, shuffleEnabled: $shuffleEnabled, '
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

  /// 系统侧「播放 / 上一首 / 下一首」是否该被压住（返回 true = 不理）。
  ///
  /// 电台还没接管卡片（例如正在起播、音乐还没落暂停）时，系统按键仍可能落在
  /// 音乐那份快照上。此时 Android 的媒体按键 / 蓝牙耳机按 Play，落的都是音乐的
  /// `resume()` —— 用户听到的就是「电台播着播着，突然开始放歌」。装配层把这条
  /// 接到「电台正在响」，这条链上的播放指令一律丢弃；电台真正接管卡片后，
  /// 动作走 [onRadioPlay] / [onRadioPause] / [onRadioStop]，不再经过这里。
  bool Function()? suppressTransportCommands;

  /// 电台接管卡片后的系统动作。与音乐一样只有一套入口：续播 / 暂停 / 关闭
  /// 都转给 [RadioState] 的既有方法，不在这里另开一条播放路径。
  Future<void> Function()? onRadioPlay;
  Future<void> Function()? onRadioPause;
  Future<void> Function()? onRadioStop;

  final int Function() _nowMs;

  StreamSubscription<MediaSessionCommand>? _commandSub;
  StreamSubscription<PlayerEvent>? _playerSub;
  VoidCallback? _viewListener;
  PublishedSnapshot? _last;
  int _lastPublishMs = 0;
  int _publishCount = 0;
  bool _attached = false;
  bool _stoppedWithoutTrack = false;

  /// 电台侧最近一次快照；null = 没有当前台（或已关台）。
  PublishedSnapshot? _radio;

  /// 上一次真正在响的是不是电台。都没响时用它决定卡片留给谁：
  /// 用户刚暂停的电台应该留在卡片上，而不是被一份同样暂停的音乐顶掉。
  bool _radioOwns = false;

  /// 音乐上一拍是否在响：只在「开始响」的那一下抢走卡片，
  /// 暂停中的音乐不会把电台挤下去。
  bool _lastMusicPlaying = false;

  /// 成功推给 bridge 的快照条数（节流 / 去重之后的真实推送次数）。
  int get publishCount => _publishCount;

  /// 当前卡片是否由电台接管（测试与装配层可以读）。
  bool get radioOwnsCard =>
      _radio != null && _radio!.title.isNotEmpty && _radioOwns;

  /// 电台侧状态变化的入口：装配层在 [RadioState] 每次 notify 时调这里。
  ///
  /// [snapshot] 为 null = 没有当前台（关台 / 清空）。换了台、开始出声都会把
  /// 卡片让给电台；单纯暂停不会 —— 暂停是「同一台还在」，卡片应留在它身上。
  void publishRadio(PublishedSnapshot? snapshot) {
    final previous = _radio;
    _radio = snapshot;
    if (snapshot == null) {
      _radioOwns = false;
    } else if (snapshot.playing ||
        previous == null ||
        previous.title != snapshot.title) {
      _radioOwns = true;
    }
    if (_attached) _publish();
  }

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

  /// 外部状态（封面显示层异步命中在线图 / 写真）变化后重推一次快照。
  ///
  /// 封面可能晚于切歌到位：在线匹配是异步的，`track.cover` 不变，transport
  /// view 不会再发事件，通知栏就一直挂着占位图。封面表到货后由装配层调这里
  /// 补推；`_publish` 内部按元数据指纹去重，封面没变时不会重复打平台。
  void refresh() => _publish();

  /// 系统侧动作 → 当前接管的那条链路。这里是唯一的翻译点。
  ///
  /// 电台接管时：播放 / 暂停 / 关闭都转给电台的既有方法，上下曲与 seek 直接
  /// 忽略（直播没有「下一台」也没有进度可拖）。音乐接管时仍走
  /// [TransportController.resume] / [TransportController.stopPlayback]：
  /// 锁屏按钮与界面按钮的听觉与数据结果必须一致，不能给系统留第二条路径。
  void _onCommand(MediaSessionCommand command) {
    if (radioOwnsCard) {
      switch (command) {
        case PlayCommand():
          final play = onRadioPlay;
          if (play != null) unawaited(play());
          return;
        case PauseCommand():
          final pause = onRadioPause;
          if (pause != null) unawaited(pause());
          return;
        case StopCommand():
          final stop = onRadioStop;
          if (stop != null) unawaited(stop());
          return;
        case NextCommand():
        case PreviousCommand():
        case SeekCommand():
          return;
      }
    }

    // 电台还没接管（起播中 / 音乐刚被让位）：音乐侧的播放类按键**一概不理**
    // （见 [suppressTransportCommands]）。暂停 / 停止仍然放行 —— 它们只是让音乐
    // 更安静，不会把电台挤停。
    final suppressed = suppressTransportCommands?.call() ?? false;
    if (suppressed) {
      switch (command) {
        case PlayCommand():
        case NextCommand():
        case PreviousCommand():
          return;
        case PauseCommand():
        case StopCommand():
        case SeekCommand():
          break;
      }
    }
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
    final music = PublishedSnapshot(
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

    final snapshot = _activeSnapshot(music);

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

    if (snapshot.title.isEmpty) {
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

  /// 谁在响谁接管；都没响时，卡片留在最后响过的那条链路。
  ///
  /// 三条规则：
  ///   1. 电台在响 → 电台（音乐此时已被互斥钩子暂停）；
  ///   2. 音乐在响 → 音乐，并把「最后响过」记到音乐；
  ///   3. 都没响 → [lastRadio] 决定；它没有台时才回落到音乐的暂停态。
  ///
  /// 每次采样都先记「音乐这一拍是否在响」，于是音乐由响转停时不会反过来把
  /// 刚让位的电台又顶掉：暂停中的音乐只在电台没有台的时候出现。
  PublishedSnapshot _activeSnapshot(PublishedSnapshot music) {
    final radio = _radio;
    final radioHasContent = radio != null && radio.title.isNotEmpty;

    if (music.playing && !_lastMusicPlaying) {
      _radioOwns = false;
    }
    if (radio != null && radio.playing) {
      _radioOwns = true;
    }
    _lastMusicPlaying = music.playing;

    if (radio != null && radio.playing) return radio;
    if (music.playing) return music;
    if (radioHasContent && _radioOwns) return radio;
    if (music.title.isNotEmpty) return music;
    if (radioHasContent) return radio;
    return music;
  }

  /// 除 position 外全部字段相同即视为「语义未变」：position 单独走节流，
  /// 不能把它算进判等，否则进度每秒一次的节流永远不会生效。
  bool _sameMetadata(PublishedSnapshot a, PublishedSnapshot b) =>
      a.kind == b.kind &&
      a.title == b.title &&
      a.artist == b.artist &&
      a.album == b.album &&
      a.artUri == b.artUri &&
      a.playing == b.playing &&
      a.duration == b.duration &&
      a.live == b.live &&
      a.artworkHue == b.artworkHue &&
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
