// 临时复现脚本：用真实 media_kit 内核驱动 TransportController，
// 反复切歌并打印每一次 open / 位置 / 播放态，定位「切歌变成从头重播」。
//
// 运行：flutter run -d windows -t tool/repro_switch.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/media_kit_driver.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:media_kit/media_kit.dart' hide Playlist, Track;

class _Toasts implements ToastSink {
  @override
  void show(String message, {String key = '', int durationMs = 3200}) =>
      _log('TOAST', message);
  @override
  void info(String message) => _log('INFO', message);
  @override
  void error(String message, {int durationMs = 3200}) =>
      _log('ERROR', message);
}

class _Recent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

final Stopwatch _watch = Stopwatch()..start();

void _log(String tag, String message) {
  final ms = _watch.elapsedMilliseconds.toString().padLeft(6);
  // ignore: avoid_print
  print('[$ms] $tag $message');
}

String _tail(Track? track) {
  if (track == null) return 'null';
  final name = track.handle.displayName;
  return '${track.id.split(':').last}($name)';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final libPath = Platform.environment['LIGHT_LIB'] ??
      r'C:\Users\Administrator\AppData\Roaming\com.lightmusic\light_music\library.json';
  final raw = jsonDecode(File(libPath).readAsStringSync()) as Map<String, dynamic>;
  final tracks = <Track>[];
  for (final item in (raw['tracks'] as List)) {
    final track = normalizeTrack(item);
    if (track != null) tracks.add(track);
  }
  _log('BOOT', 'tracks=${tracks.length}');

  final mpv = Player();
  final driver = MediaKitDriver(player: mpv);
  final audio = AudioPlayer(driver);
  final playlist = Playlist(tracks: tracks, mode: PlayMode.list);
  final transport = TransportController(
    player: audio,
    recent: _Recent(),
    toasts: _Toasts(),
    playlist: playlist,
  );

  audio.events.listen((event) {
    switch (event) {
      case LoadingEvent(:final loading):
        _log('EV', 'loading=$loading');
      case CanplayEvent(:final duration):
        _log('EV', 'canplay duration=$duration');
      case StateChangedEvent(:final playing):
        _log('EV', 'playing=$playing pos=${driver.position.toStringAsFixed(2)}');
      case CompletedEvent():
        _log('EV', 'COMPLETED pos=${driver.position.toStringAsFixed(2)}');
      case ErrorEvent(:final kind, :final message):
        _log('EV', 'ERROR $kind $message');
      case BlockedEvent(:final message):
        _log('EV', 'BLOCKED $message');
      default:
        break;
    }
  });

  Map<String, Object?> snap() => {
        'app': '${playlist.currentIndex}:${_tail(playlist.current)}',
        'kernelTrack': _tail(audio.track),
        'mpvPos': driver.position.toStringAsFixed(2),
        'mpvPlaying': mpv.state.playing,
        'mpvCompleted': mpv.state.completed,
        'mpvPlaylist': mpv.state.playlist.medias
            .map((m) => Uri.parse(m.uri).pathSegments.isNotEmpty
                ? Uri.parse(m.uri).pathSegments.last
                : m.uri)
            .join(','),
        'mpvIndex': mpv.state.playlist.index,
      };

  void dump(String tag) {
    _log(tag, const JsonEncoder.withIndent(' ').convert(snap()).replaceAll('\n', ' '));
  }

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  // ---- 场景 1：普通列表循环，逐首 next ----
  _log('SCENE', '1) sequential next');
  await transport.playTrack(tracks[10].id);
  await wait(4000);
  dump('S1-before');
  for (var i = 0; i < 6; i++) {
    final before = playlist.current!.id;
    await transport.next();
    await wait(1200);
    dump('S1-next#$i');
    final after = playlist.current!.id;
    _log('S1-result', 'before=${before.split(':').last} after=${after.split(':').last} '
        'same=${before == after}');
  }

  // ---- 场景 2：极快连按下一首（连续 3 次，无间隔）----
  _log('SCENE', '2) rapid triple next');
  dump('S2-before');
  final before2 = playlist.currentIndex;
  await transport.next();
  await transport.next();
  await transport.next();
  await wait(1500);
  dump('S2-after');
  _log('S2-result', 'fromIndex=$before2 toIndex=${playlist.currentIndex}');

  // ---- 场景 3：曲末自动续播，紧接着手动 next（竞态）----
  _log('SCENE', '3) eof then manual next');
  final dur = playlist.current!.duration;
  await audio.seek((dur - 2).clamp(0, dur));
  await wait(2000);
  dump('S3-after-eof');
  await transport.next();
  await wait(1500);
  dump('S3-after-manual-next');
  _log('S3-result', 'index-after-auto=${playlist.currentIndex}');

  // ---- 场景 4：上一首三秒规则 ----
  _log('SCENE', '4) previous after 5s');
  await wait(5000);
  dump('S4-before-prev');
  await transport.previous();
  await wait(1200);
  dump('S4-after-prev');

  _log('SCENE', '5) previous within 1s after a switch');
  await transport.next();
  await wait(400);
  final beforeIndex = playlist.currentIndex;
  await transport.previous();
  await wait(1200);
  dump('S5-after-prev');
  _log('S5-result', 'index=$beforeIndex -> ${playlist.currentIndex}');

  _log('DONE', 'finish');
  unawaited(transport.dispose());
  await Future<void>.delayed(const Duration(milliseconds: 600));
  exit(0);
}
