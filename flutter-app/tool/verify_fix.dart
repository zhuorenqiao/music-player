// 临时验证脚本：2026-11-23「上一曲 / 下一曲切歌不换歌、从头开始播」修复后的
// 真实内核（media_kit / libmpv）回归。跑法与复现脚本相同：
//
//   flutter run -d windows -t tool/verify_fix.dart
//
// 只读用户真实曲库，不改任何文件。每条用例打 PASS / FAIL，末尾打印汇总。
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
  final List<String> shown = [];
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {
    shown.add(message);
    _log('TOAST', message);
  }

  @override
  void info(String message) => _log('INFO', message);
  @override
  void error(String message, {int durationMs = 3200}) {
    shown.add(message);
    _log('ERRTOAST', message);
  }
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
    _log('OPEN', '#$openCount ${track.handle.displayName}');
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
final List<String> _failures = [];

void _log(String tag, String message) {
  final ms = _watch.elapsedMilliseconds.toString().padLeft(6);
  // ignore: avoid_print
  print('[$ms] $tag $message');
}

void _check(String name, bool ok, String detail) {
  // ignore: avoid_print
  print('${ok ? "PASS" : "FAIL"} $name —— $detail');
  if (!ok) _failures.add('$name ($detail)');
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
  final toasts = _Toasts();
  final transport = TransportController(
    player: audio,
    recent: _Recent(),
    toasts: toasts,
    playlist: playlist,
  );

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// 等开次涨到 [target]（最多 4s），返回是否等到。
  Future<bool> waitOpens(int target) async {
    for (var i = 0; i < 100; i++) {
      if (driver.openCount >= target) return true;
      await wait(40);
    }
    return false;
  }

  // A. 单曲循环 + 曲末硬 EOF：原地重播**只开一次**（旧代码会再开一次，
  //    因为换源瞬间又收到一条上一首的 completed）。
  playlist.setMode(PlayMode.one);
  final aIdx = 5;
  await transport.playTrack(tracks[aIdx].id);
  await wait(900);
  final aBefore = driver.openCount;
  toasts.shown.clear();
  final aDur = playlist.current!.duration;
  await audio.seek(aDur - 0.4);
  await waitOpens(aBefore + 1);
  await wait(2200);
  final aAfter = driver.openCount;
  _check(
    'A 单曲循环曲末只重播一次',
    aAfter == aBefore + 1 && playlist.currentIndex == aIdx,
    'opens ${aAfter - aBefore}（期望 1）idx=${playlist.currentIndex}（期望 $aIdx）'
        ' 误报=${toasts.shown}',
  );

  // B. 列表循环 + 曲末硬 EOF：自动续播只跳一首。
  playlist.setMode(PlayMode.list);
  final bIdx = 10;
  await transport.playTrack(tracks[bIdx].id);
  await wait(900);
  final bBefore = driver.openCount;
  final bDur = playlist.current!.duration;
  await audio.seek(bDur - 0.4);
  await waitOpens(bBefore + 1);
  await wait(2200);
  final bExpect = (bIdx + 1) % tracks.length;
  _check(
    'B 列表循环曲末只跳一首',
    driver.openCount == bBefore + 1 && playlist.currentIndex == bExpect,
    'opens ${driver.openCount - bBefore}（期望 1）idx=${playlist.currentIndex}'
        '（期望 $bExpect）',
  );

  // C. 播放超过 3 秒按上一首：必须换歌，不许 seek 回 0。
  final cIdx = 8;
  await transport.playTrack(tracks[cIdx].id);
  await wait(900);
  await audio.seek(6.0); // 位置 6s > 旧的三秒阈值
  await wait(400);
  final cBefore = driver.openCount;
  final cPos = driver.position;
  await transport.previous();
  await wait(1200);
  final cExpect = (cIdx - 1 + tracks.length) % tracks.length;
  _check(
    'C 播过 3 秒按上一首换歌',
    playlist.currentIndex == cExpect && driver.openCount == cBefore + 1,
    'pos=$cPos idx=${playlist.currentIndex}（期望 $cExpect）'
        ' opens=${driver.openCount - cBefore}（期望 1）',
  );

  // D. 曲末前 350ms 手动下一首：允许自然 EOF 再补一跳，但不许连跳 3 首以上。
  final dIdx = 14;
  await transport.playTrack(tracks[dIdx].id);
  await wait(800);
  final dDur = playlist.current!.duration;
  await audio.seek(dDur - 0.35);
  await wait(120);
  final dBefore = driver.openCount;
  await transport.next();
  await wait(2200);
  final dOpens = driver.openCount - dBefore;
  _check(
    'D 曲末切下一首',
    playlist.currentIndex >= dIdx + 1 &&
        playlist.currentIndex <= dIdx + 2 &&
        dOpens <= 2,
    'idx=${playlist.currentIndex}（期望 ${dIdx + 1}~${dIdx + 2}）'
        ' opens=$dOpens（期望 ≤2）',
  );

  // E. 常规顺序切歌（基线，守卫不许误伤）。
  playlist.setMode(PlayMode.list);
  await transport.playTrack(tracks[0].id);
  await wait(700);
  var sequenceOk = true;
  for (var i = 1; i <= 5; i++) {
    await transport.next();
    await wait(600);
    if (playlist.currentIndex != i) {
      sequenceOk = false;
      break;
    }
  }
  _check('E 顺序下一首 5 次', sequenceOk, 'idx=${playlist.currentIndex}（期望 5）');

  // ignore: avoid_print
  print(_failures.isEmpty
      ? 'RESULT 全部通过'
      : 'RESULT 失败 ${_failures.length} 条: ${_failures.join(' | ')}');
  unawaited(transport.dispose());
  await wait(600);
  exit(_failures.isEmpty ? 0 : 1);
}
