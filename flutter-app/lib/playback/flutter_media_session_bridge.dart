// lib/playback/flutter_media_session_bridge.dart
//
// `flutter_media_session` 3.0.9 的真正实现（spec §7.2：一套 API 覆盖 Android
// 通知栏 / 锁屏与 Windows SMTC）。本文件只做「翻译」——把 [PublishedSnapshot]
// 翻成包认得的元数据 / 播放态 / 动作集合，把包推上来的动作翻成
// [MediaSessionCommand]；播放控制语义仍然只由 [MediaSessionCoordinator]
// 翻译成 [TransportController] 的调用，这里不碰播放器。
//
// 签名以本机 pub cache 里 3.0.9 的源码为准（README 停在 3.0.0 之前的写法）：
//   - `FlutterMediaSession().activate() / deactivate()`；
//   - 同步数据走平台接口，不在门面上（3.0 已移除 setMetadata/setPlaybackState）：
//       `FlutterMediaSessionPlatform.instance.updateMetadata(MediaMetadata)`
//       `FlutterMediaSessionPlatform.instance.updatePlaybackState(PlaybackState)`
//       `FlutterMediaSessionPlatform.instance.updateAvailableActions(Set<MediaAction>?)`
//       `FlutterMediaSessionPlatform.instance.onMediaAction`（Stream<MediaAction>）
//   - `PlaybackState` 的「状态」是枚举 `PlaybackStatus`，没有 `stopped` 档；
//     空态落 `idle`（Android 侧 STATE_IDLE 会撤掉通知，Windows 侧落 Stopped）。
//   - 动作名是 `play` / `pause` / `skipToNext` / `skipToPrevious` / `stop` /
//     `seekTo` / `rewind` / `fastForward`；不是 `nexttrack` 那套 MPRIS 名字，
//     所以 [actionsFor] 与 [mediaActionsFor] 分开：前者是快照语义，后者才是
//     发给平台的名字。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;

import 'media_session_bridge.dart';

/// 通知渠道名（Android 通知栏上显示的应用名 / 渠道名）。
const String mediaSessionChannelName = '流光音乐';

/// 通知渠道 id。同一渠道的播放通知会被系统归并，不再叠第二条。
const String mediaSessionChannelId = 'light_music_playback';

/// 播放态名字：与快照的三类状态一一对应。
///
/// 「在放」优先：内核说在放就报 `playing`（进度条要跟着走）。没在放时再分两种
/// —— 有当前曲目就是 `paused`，没有（标题为空）就是 `stopped`。
/// 协调器挂空态之前一定先暂停，所以「标题空 + playing」只在暂停指令迟到的那
/// 一瞬间可能出现，此时报 `playing` 比 `stopped` 更接近内核的真实状态。
String mapStateName(PublishedSnapshot snapshot) {
  if (snapshot.playing) return 'playing';
  if (snapshot.title.isEmpty) return 'stopped';
  return 'paused';
}

/// [mapStateName] 到包内枚举的映射。`stopped` 没有对应项，落 `idle`。
fms.PlaybackStatus statusFor(PublishedSnapshot snapshot) =>
    switch (mapStateName(snapshot)) {
      'playing' => fms.PlaybackStatus.playing,
      'paused' => fms.PlaybackStatus.paused,
      _ => fms.PlaybackStatus.idle,
    };

/// 快照允许的系统动作。空态一个都不给（通知栏 / SMTC 应该干净）。
///
/// 没有当前曲目就谈不上上下曲；时长未知时不给 seek —— 系统侧画不出可拖的
/// 进度条，给了也只会收到 0 秒的跳转请求。
List<String> actionsFor(PublishedSnapshot snapshot) {
  if (snapshot.title.isEmpty) return const [];
  return [
    'play',
    'pause',
    'next',
    'previous',
    'stop',
    if (snapshot.duration != null) 'seek',
  ];
}

/// 把 [actionsFor] 的语义名换成包真正认的动作常量。
///
/// 这一步不能省：平台只认 `skipToNext` / `skipToPrevious`，发 `next` 过去
/// 等于告诉系统「本轮没有下一首」，锁屏上的上下曲会变灰。
Set<fms.MediaAction> mediaActionsFor(PublishedSnapshot snapshot) {
  final actions = <fms.MediaAction>{};
  for (final name in actionsFor(snapshot)) {
    switch (name) {
      case 'play':
        actions.add(fms.MediaAction.play);
      case 'pause':
        actions.add(fms.MediaAction.pause);
      case 'next':
        actions.add(fms.MediaAction.skipToNext);
      case 'previous':
        actions.add(fms.MediaAction.skipToPrevious);
      case 'stop':
        actions.add(fms.MediaAction.stop);
      case 'seek':
        actions.add(fms.MediaAction.seekTo);
    }
  }
  return actions;
}

/// 快照里的封面（本地缓存路径或已有 URI）→ 系统侧能读的 URI。
///
/// Windows SMTC 走 `StorageFile` / `Uri` 取缩略图，纯路径能用但 `file://` 更稳；
/// Android Media3 只认 `Uri.parse` 之后非空的串。文件不存在就返回 null：
/// 画一张打不开的封面比不画更糟（通知栏会闪一下再变白）。
String? toArtUri(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http')) return path;
  if (kIsWeb) return null;
  try {
    final file = File(path);
    return file.existsSync() ? file.uri.toString() : null;
  } catch (_) {
    return null;
  }
}

/// 系统动作名 → 命令。名字统一转小写，两端的写法（`skipToNext` / `nexttrack`）
/// 都能落进来。`seekTo` 需要位置，只能由 [commandFromAction] 构造。
MediaSessionCommand? commandFromName(String name) =>
    switch (name.toLowerCase()) {
      'play' || 'resume' || 'toggleplay' => const PlayCommand(),
      'pause' => const PauseCommand(),
      'next' || 'nexttrack' || 'skipnext' || 'skiptonext' =>
        const NextCommand(),
      'previous' || 'previoustrack' || 'skipprevious' || 'skiptoprevious' =>
        const PreviousCommand(),
      'stop' => const StopCommand(),
      // fastForward / rewind 在 M1 就是切歌：原版没有倍速与 10 秒跳转，
      // 系统给了这两个键就按「下一首 / 上一首」处理（brief 的既定映射）。
      'fastforward' => const NextCommand(),
      'rewind' => const PreviousCommand(),
      _ => null,
    };

/// 平台动作对象 → 命令。`seekTo` 带位置（[fms.MediaAction.seekPosition]），
/// 是唯一需要秒数的命令；缺位置就丢弃（不猜 0 秒）。
MediaSessionCommand? commandFromAction(fms.MediaAction action) {
  if (action.name == 'seekTo') {
    final position = action.seekPosition;
    if (position == null) return null;
    return SeekCommand(position.inMilliseconds / 1000);
  }
  return commandFromName(action.name);
}

/// 平台媒体会话的桥。启动一次、按快照推状态、把动作转成命令。
class FlutterMediaSessionBridge implements MediaSessionBridge {
  FlutterMediaSessionBridge();

  final fms.FlutterMediaSession _session = fms.FlutterMediaSession();
  final StreamController<MediaSessionCommand> _commands =
      StreamController<MediaSessionCommand>.broadcast();

  StreamSubscription<fms.MediaAction>? _actionSub;

  /// 上一次推过的元数据指纹：位置每秒跳一次，元数据不该跟着重发
  /// （Android 每发一次都会让 Media3 invalidateState，通知栏会闪）。
  String? _metadataKey;

  /// 上一次推过的动作集合，同样去重。
  Set<fms.MediaAction>? _lastActions;

  bool _started = false;
  bool _disposed = false;

  @override
  Stream<MediaSessionCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _session.activate();
    // onMediaAction 是广播流：只收订阅之后的事件，所以先 activate 再订阅。
    _actionSub = fms.FlutterMediaSessionPlatform.instance.onMediaAction.listen(
      (action) {
        final command = commandFromAction(action);
        if (command != null && !_commands.isClosed) _commands.add(command);
      },
      onError: (Object error, StackTrace stack) {
        // 平台通道出错不该炸掉播放；动作流断掉只意味着系统侧按钮暂时没反应。
        debugPrint('flutter_media_session action error: $error');
      },
    );
  }

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {
    if (_disposed) return;
    final platform = fms.FlutterMediaSessionPlatform.instance;

    final artworkUri = toArtUri(snapshot.artUri);
    final metadataKey = [
      snapshot.title,
      snapshot.artist,
      snapshot.album,
      artworkUri ?? '',
      '${snapshot.duration?.inMilliseconds ?? ''}',
    ].join('\u0001');
    if (metadataKey != _metadataKey) {
      _metadataKey = metadataKey;
      await platform.updateMetadata(
        fms.MediaMetadata(
          title: snapshot.title,
          artist: snapshot.artist,
          album: snapshot.album,
          artworkUri: artworkUri,
          duration: snapshot.duration,
        ),
      );
    }

    await platform.updatePlaybackState(
      fms.PlaybackState(
        status: statusFor(snapshot),
        position: snapshot.position,
        // 速度是倍率不是开关：Media3 的 PlaybackParameters 要求 speed > 0，
        // 传 0 会直接抛；暂停由 status 表达。
        speed: 1,
        repeatMode: _repeatModeOf(snapshot.repeatMode),
        shuffleModeEnabled: snapshot.shuffleEnabled,
      ),
    );

    final actions = mediaActionsFor(snapshot);
    if (!_sameActions(actions, _lastActions)) {
      _lastActions = actions;
      await platform.updateAvailableActions(actions);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed || !_started) return;
    final platform = fms.FlutterMediaSessionPlatform.instance;
    // 空态之后第一件事就是重新发一次元数据：归零指纹，别让下一首的标题
    // 被「与上一首相同」的去重挡掉。
    _metadataKey = null;
    _lastActions = const <fms.MediaAction>{};
    await platform.updatePlaybackState(
      const fms.PlaybackState(status: fms.PlaybackStatus.idle),
    );
    await platform.updateAvailableActions(const <fms.MediaAction>{});
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _actionSub?.cancel();
    _actionSub = null;
    if (_started) {
      _started = false;
      await _session.deactivate();
    }
    await _commands.close();
  }

  fms.MediaRepeatMode _repeatModeOf(MediaRepeatMode mode) => switch (mode) {
    MediaRepeatMode.off => fms.MediaRepeatMode.none,
    MediaRepeatMode.all => fms.MediaRepeatMode.all,
    MediaRepeatMode.one => fms.MediaRepeatMode.one,
  };

  /// 动作集合判等。`MediaAction` 的 == 只比名字与类型，但 Set 的 == 是身份比较。
  bool _sameActions(
    Set<fms.MediaAction> next,
    Set<fms.MediaAction>? last,
  ) {
    if (last == null || next.length != last.length) return false;
    for (final action in next) {
      if (!last.contains(action)) return false;
    }
    return true;
  }
}
