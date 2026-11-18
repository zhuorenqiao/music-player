// 一次性预热探针（不进产物）：把用户曲库里所有本地曲目的频谱帧表先算出来，
// 写进**应用自己的**缓存目录，这样用户第一次在歌词页播放某首歌时
// SpectrumState.cached() 直接命中，不用等几十秒的离线解析。
//
// 用法（release 跑，debug 的 FFT 慢 10 倍）：
//   flutter run --release -d windows -t tool/spectrum_prewarm.dart \
//     --dart-define=CACHE=<应用数据目录>\spectrum \
//     --dart-define=LIB=<应用数据目录>\library.json
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const cacheDir = String.fromEnvironment('CACHE');
  const libPath = String.fromEnvironment('LIB');
  if (cacheDir.isEmpty || libPath.isEmpty) {
    stdout.writeln('PREWARM: 需要 --dart-define=CACHE=... 与 --dart-define=LIB=...');
    exit(2);
  }
  final lib = jsonDecode(File(libPath).readAsStringSync()) as Map<String, dynamic>;
  final tracks = (lib['tracks'] as List).cast<Map<String, dynamic>>();
  final pipeline = SpectrumPipeline(cacheDirectory: cacheDir);
  stdout.writeln('PREWARM: ${tracks.length} 首，缓存目录 $cacheDir');
  var ok = 0;
  var cached = 0;
  var failed = 0;
  for (final t in tracks) {
    final id = (t['id'] ?? '').toString();
    final src = (t['src'] ?? '').toString();
    final title = (t['title'] ?? '').toString();
    if (src.isEmpty || !File(src).existsSync()) {
      stdout.writeln('PREWARM: 跳过（文件不存在）$title  $src');
      failed++;
      continue;
    }
    final hit = await pipeline.cached(id, src);
    if (hit != null) {
      stdout.writeln('PREWARM: 命中缓存 $title  frames=${hit.frameCount}');
      cached++;
      continue;
    }
    final watch = Stopwatch()..start();
    final table = await pipeline.request(id, src);
    watch.stop();
    if (table == null) {
      stdout.writeln('PREWARM: 解析失败 $title  ($src)');
      failed++;
      continue;
    }
    ok++;
    stdout.writeln('PREWARM: 算完 $title  frames=${table.frameCount}  '
        '耗时=${watch.elapsedMilliseconds}ms');
  }
  stdout.writeln('PREWARM: 完成 新算=$ok 命中=$cached 失败=$failed');
  exit(0);
}
