// 临时复现脚本 4：曲末竞态矩阵 —— 手动切歌撞上 COMPLETED / 1.4s 自动跳。
//
// 运行：flutter run -d windows -t tool/repro_race.dart
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
  int openCount = 0;

  @override
  Future<bool> open(Track track) {
    openCount += 1;
    _log('OPEN', '#$openCount ${track.id.split(':').last} ${track.handle.displayName}');
    return inner.open(track);
  }

  @override
  Future<void> play() => inner.play();
  @override
  Future<void> pause() => inner.pause();
  @override
  Future<bool> seekTo(double seconds) => inner.seekTo(seconds);
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

String _short(Track? t) => t == null ? 'null' : t.id.split(':').last;

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
    if (event is CompletedEvent) _log('EV', 'COMPLETED at ${_short(playlist.current)}');
    if (event is ErrorEvent) _log('EV', 'ERROR ${event.kind}');
  });

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  void dump(String tag) => _log(tag,
      'idx=${playlist.currentIndex} app=${_short(playlist.current)} kernel=${_short(audio.track)} pos=${driver.position.toStringAsFixed(2)} opens=${driver.openCount}');

  /// 等 mpv 走到 completed=true（最多 4s）
  Future<bool> waitCompleted() async {
    for (var i = 0; i < 100; i++) {
      if (mpv.state.completed) return true;
      await wait(40);
    }
    return false;
  }

  // 列表模式：手动下一首正好撞上 COMPLETED（同一时刻）
  for (var round = 0; round < 3; round++) {
    playlist.setMode(PlayMode.list);
    final idx = 10 + round;
    await transport.playTrack(tracks[idx].id);
    await wait(700);
    final dur = playlist.current!.duration;
    dump('R$round-before');
    await audio.seek(dur - 0.4);
    final seen = await waitCompleted();
    _log('R$round', 'completed=$seen at ${_short(playlist.current)}');
    await transport.next(); // 撞在 completed 的那一瞬间
    await wait(1000);
    dump('R$round-after-next');
    await wait(1400); // 覆盖 1.4s 自动跳窗口
    dump('R$round-after-wait');
    _log('R$round-result',
        'expect=${(idx + 1) % tracks.length} got=${playlist.currentIndex}');
  }

  // 单曲循环：手动下一首撞上 COMPLETED
  for (var round = 0; round < 2; round++) {
    playlist.setMode(PlayMode.one);
    final idx = 5 + round;
    await transport.playTrack(tracks[idx].id);
    await wait(700);
    final beforeOpen = driver.openCount;
    final dur = playlist.current!.duration;
    await audio.seek(dur - 0.4);
    await waitCompleted();
    await transport.next();
    await wait(1200);
    dump('O$round-after-next');
    await wait(1400);
    dump('O$round-after-wait');
    _log('O$round-result', 'expect=${idx + 1} got=${playlist.currentIndex} '
        'opensDuring=${driver.openCount - beforeOpen}');
  }

  // 曲末前 300ms 手动切歌（此时 completed 尚未触发）
  playlist.setMode(PlayMode.list);
  for (var round = 0; round < 2; round++) {
    final idx = 12 + round;
    await transport.playTrack(tracks[idx].id);
    await wait(700);
    final dur = playlist.current!.duration;
    await audio.seek(dur - 0.35);
    await wait(150);
    final beforeOpen = driver.openCount;
    await transport.next();
    await wait(1000);
    dump('E$round-after-next');
    await wait(1400);
    dump('E$round-after-wait');
    _log('E$round-result', 'expect=${(idx + 1) % tracks.length} '
        'got=${playlist.currentIndex} opens=${driver.openCount - beforeOpen}');
  }

  // 自动续播后立刻（0ms）再按上一首
  playlist.setMode(PlayMode.list);
  await transport.playTrack(tracks[3].id);
  await wait(700);
  final d3 = playlist.current!.duration;
  await audio.seek(d3 - 0.4);
  await waitCompleted();
  await wait(120);
  final autoIdx = playlist.currentIndex;
  _log('P', 'auto-next -> idx=$autoIdx ${_short(playlist.current)}');
  await transport.previous();
  await wait(1200);
  dump('P-after-prev');
  _log('P-result', 'from=$autoIdx now=${playlist.currentIndex}');

  _log('DONE', 'finish');
  unawaited(transport.dispose());
  await wait(600);
  exit(0);
}
