// 临时复现脚本 2：模式矩阵（单曲 / 随机 / 列表）与曲末竞态，
// 外加一个包在真实 MediaKitDriver 外面的审计驱动，记录每次真正交给内核的 URI。
//
// 运行：flutter run -d windows -t tool/repro_modes.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:light_music/playback/audio_driver.dart';
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

/// 审计包装：所有 open / play / seek 都留痕，其余原样透传。
class AuditDriver implements AudioDriver {
  AuditDriver(this.inner);
  final MediaKitDriver inner;

  @override
  Future<bool> open(Track track) {
    _log('OPEN', '${track.id.split(':').last} <- ${track.handle.uri}');
    return inner.open(track).then((ok) {
      _log('OPEN-RESULT', '${track.id.split(':').last} ok=$ok');
      return ok;
    });
  }

  @override
  Future<void> play() {
    _log('PLAY', 'position=${inner.position.toStringAsFixed(2)}');
    return inner.play();
  }

  @override
  Future<void> pause() => inner.pause();

  @override
  Future<bool> seekTo(double seconds) {
    _log('SEEK', '$seconds');
    return inner.seekTo(seconds);
  }

  @override
  Future<void> setVolume(double value) => inner.setVolume(value);

  @override
  Future<void> stop() {
    _log('STOP', '');
    return inner.stop();
  }

  @override
  Future<void> dispose() => inner.dispose();

  @override
  Stream<double> get positionStream => inner.positionStream;
  @override
  Stream<double?> get bufferedStream => inner.bufferedStream;
  @override
  Stream<double?> get durationStream => inner.durationStream;
  @override
  Stream<bool> get playingStream => inner.playingStream;
  @override
  Stream<bool> get loadingStream => inner.loadingStream;
  @override
  Stream<DriverError> get errorStream => inner.errorStream;
  @override
  Stream<void> get completedStream => inner.completedStream;
  @override
  Stream<void> get canplayStream => inner.canplayStream;
  @override
  double get position => inner.position;
  @override
  double? get durationOrNull => inner.durationOrNull;
  @override
  double? get bufferedOrNull => inner.bufferedOrNull;
  @override
  bool get isPlaying => inner.isPlaying;
  @override
  bool get isLoading => inner.isLoading;
}

final Stopwatch _watch = Stopwatch()..start();

void _log(String tag, String message) {
  final ms = _watch.elapsedMilliseconds.toString().padLeft(6);
  // ignore: avoid_print
  print('[$ms] $tag $message');
}

String _id(Track? track) => track == null ? 'null' : track.id.split(':').last;

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

  final mpv = Player();
  final inner = MediaKitDriver(player: mpv);
  final driver = AuditDriver(inner);
  final audio = AudioPlayer(driver);
  final playlist = Playlist(tracks: tracks, mode: PlayMode.list);
  final transport = TransportController(
    player: audio,
    recent: _Recent(),
    toasts: _Toasts(),
    playlist: playlist,
  );

  audio.events.listen((event) {
    if (event is CompletedEvent) {
      _log('EV', 'COMPLETED pos=${driver.position.toStringAsFixed(2)} '
          'track=${_id(audio.track)}');
    }
    if (event is ErrorEvent) {
      _log('EV', 'ERROR ${event.kind} ${event.message}');
    }
  });

  void dump(String tag) {
    _log(
      tag,
      'idx=${playlist.currentIndex} app=${_id(playlist.current)} '
      'kernel=${_id(audio.track)} pos=${driver.position.toStringAsFixed(2)} '
      'playing=${mpv.state.playing} completed=${mpv.state.completed} '
      'mode=${playlist.mode.name} '
      'mpvList=${mpv.state.playlist.medias.length}',
    );
  }

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  // ---- 单曲循环 ----
  playlist.setMode(PlayMode.one);
  _log('SCENE', 'A) 单曲循环：手动下一首');
  await transport.playTrack(tracks[5].id);
  await wait(3000);
  dump('A-before');
  await transport.next();
  await wait(1200);
  dump('A-after-next');
  _log('A-result', 'expect idx 6, got ${playlist.currentIndex}');

  // ---- 单曲循环：曲末自动重播 + 立刻手动下一首（竞态）----
  _log('SCENE', 'B) 单曲循环：曲末自动重播，紧接着手动下一首');
  final duration = playlist.current!.duration;
  await audio.seek((duration - 1.5).clamp(0, duration));
  await wait(2600);
  dump('B-after-auto-replay');
  await transport.next();
  await wait(1400);
  dump('B-after-manual-next');
  _log('B-result', 'expect idx 7, got ${playlist.currentIndex}');

  // ---- 单曲循环：暂停状态下切歌 ----
  _log('SCENE', 'C) 单曲循环：暂停后下一首');
  await transport.pause();
  await wait(400);
  dump('C-before');
  await transport.next();
  await wait(1400);
  dump('C-after');
  _log('C-result', 'expect idx 8, got ${playlist.currentIndex}');

  // ---- 随机模式矩阵 ----
  _log('SCENE', 'D) 随机：连播 12 首，记录是否有原地重复');
  playlist.setMode(PlayMode.shuffle);
  await transport.playTrack(tracks[0].id);
  await wait(1500);
  var sameCount = 0;
  for (var i = 0; i < 12; i++) {
    final before = playlist.currentIndex;
    final beforeId = playlist.current!.id;
    await transport.next();
    await wait(700);
    final after = playlist.currentIndex;
    final afterId = playlist.current!.id;
    if (before == after || beforeId == afterId) {
      sameCount += 1;
      _log('D-REPEAT', '#$i before=$before after=$after');
    }
    _log('D-step', '#$i $before->$after mode=${playlist.mode.name}');
  }
  _log('D-result', 'sameCount=$sameCount');

  // ---- 随机：上一首 ----
  _log('SCENE', 'E) 随机：上一首（位置 > 3s 时按三秒规则）');
  await wait(4000);
  dump('E-before');
  await transport.previous();
  await wait(1200);
  dump('E-after');

  // ---- 列表：曲末自动续播后立刻再按下一首 ----
  playlist.setMode(PlayMode.list);
  _log('SCENE', 'F) 列表：曲末自动续播 + 120ms 内手动下一首');
  await transport.playTrack(tracks[9].id);
  await wait(1500);
  final dur = playlist.current!.duration;
  await audio.seek((dur - 0.6).clamp(0, dur));
  // 等 COMPLETED 事件到达（轮询 mpv.state.completed）
  for (var i = 0; i < 60 && !mpv.state.completed; i++) {
    await wait(50);
  }
  _log('F', 'completion seen completed=${mpv.state.completed} idx=${playlist.currentIndex}');
  await transport.next();
  await wait(1500);
  dump('F-after');
  _log('F-result', 'idx=${playlist.currentIndex}');

  _log('DONE', 'finish');
  unawaited(transport.dispose());
  await wait(600);
  exit(0);
}
