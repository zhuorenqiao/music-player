// 临时复现脚本 3：抓 mpv 原始 error 日志与「1.4s 自动跳」的联动。
//
// 运行：flutter run -d windows -t tool/repro_error.dart
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
      _log('ERRTOAST', message);
}

class _Recent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

class AuditDriver implements AudioDriver {
  AuditDriver(this.inner);
  final MediaKitDriver inner;

  @override
  Future<bool> open(Track track) {
    _log('OPEN', '${track.id.split(':').last} ${track.handle.displayName}');
    return inner.open(track);
  }

  @override
  Future<void> play() => inner.play();
  @override
  Future<void> pause() => inner.pause();
  @override
  Future<bool> seekTo(double seconds) {
    _log('SEEK', seconds.toStringAsFixed(2));
    return inner.seekTo(seconds);
  }

  @override
  Future<void> setVolume(double value) => inner.setVolume(value);
  @override
  Future<void> stop() => inner.stop();
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

String _tail(Track? t) => t == null ? 'null' : t.handle.displayName;

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

  // mpv 原始日志：只打印 error 级，带日志前缀。
  inner.errorStream.listen((e) {
    _log('RAW', '${e.kind.name} | ${e.rawMessage.replaceAll('\n', ' ⏎ ')}');
  });
  mpv.stream.log.listen((event) {
    if (event.level == 'error') {
      _log('MPVLOG', '${event.prefix} | ${event.text.trim()}');
    }
  });

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  // ---- 1) 逐个曲目切换：切走时会不会冒 error / 多跳一首 ----
  _log('SCENE', '1) switch through every track with 1.2s gap');
  for (var i = 0; i < tracks.length; i++) {
    final idx = i;
    await transport.playTrack(tracks[idx].id);
    await wait(1200);
    final expectIdx = (idx + 1) % tracks.length;
    await transport.next();
    await wait(2200); // 覆盖 1.4s 自动跳窗口
    final at = playlist.currentIndex;
    final flag = at == expectIdx ? 'ok' : 'MISMATCH';
    _log('S1', 'from=$idx expect=$expectIdx got=$at $flag '
        'kernel=${_tail(audio.track)} broken=${tracks[expectIdx].broken}');
    if (flag == 'MISMATCH') {
      _log('S1-DETAIL', 'pos=${driver.position.toStringAsFixed(2)}');
    }
  }

  // ---- 2) FLAC 自然播完：会不会冒 error / 多跳 ----
  _log('SCENE', '2) natural eof of flac tracks');
  for (final idx in [5, 7, 8, 10]) {
    await transport.playTrack(tracks[idx].id);
    await wait(800);
    final dur = playlist.current!.duration;
    await audio.seek(dur - 3);
    await wait(2500);
    final afterAuto = playlist.currentIndex;
    await wait(2500); // 再等一个 1.4s 窗口，看有没有二次跳
    _log('S2', 'from=$idx afterEof=$afterAuto later=${playlist.currentIndex} '
        'expectFirst=${(idx + 1) % tracks.length} '
        'broken=${tracks[idx].broken}');
  }

  // ---- 3) m4a / mp3 自然播完（对照组）----
  _log('SCENE', '3) natural eof of mp3/m4a');
  for (final idx in [15, 19]) {
    await transport.playTrack(tracks[idx].id);
    await wait(800);
    final dur = playlist.current!.duration;
    await audio.seek(dur - 3);
    await wait(2500);
    _log('S3', 'from=$idx afterEof=${playlist.currentIndex} '
        'expectFirst=${(idx + 1) % tracks.length} broken=${tracks[idx].broken}');
  }

  _log('DONE', 'finish');
  unawaited(transport.dispose());
  await wait(600);
  exit(0);
}
