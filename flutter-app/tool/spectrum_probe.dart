// 一次性运行探针（不进产物）：把「真解码」与「纯计算」两段耗时分别量出来，
// 确认 Windows 上解码 → FFT → 折带这条链路真的走通，并打印一帧的段落快照。
//
// 用法：
//   flutter run --release -d windows -t tool/spectrum_probe.dart \
//     --dart-define=TRACK=<音频绝对路径> [--dart-define=OUT=<写出 .bin 的路径>]
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const track = String.fromEnvironment('TRACK');
  if (track.isEmpty) {
    stdout.writeln('PROBE: 缺少 --dart-define=TRACK=<path>');
    exit(2);
  }
  final tmp = Directory.systemTemp.createTempSync('lspc-probe-');
  final wav = '${tmp.path}${Platform.pathSeparator}pcm.wav';
  stdout.writeln('PROBE: track=$track');

  final decode = Stopwatch()..start();
  try {
    await defaultSpectrumAudioDecoder(track, wav);
  } catch (e) {
    stdout.writeln('PROBE: 解码抛异常 → $e');
    exit(0);
  }
  decode.stop();
  final wavBytes = File(wav).lengthSync();

  final computeWatch = Stopwatch()..start();
  final table = computeSpectrumSync(wav);
  computeWatch.stop();

  stdout.writeln('PROBE: 解码 ${decode.elapsedMilliseconds}ms  '
      '(wav ${(wavBytes / 1e6).toStringAsFixed(1)}MB)  '
      '计算 ${computeWatch.elapsedMilliseconds}ms  '
      'frames=${table.frameCount}  '
      'dur=${(table.frameCount * table.frameMs / 1000).toStringAsFixed(1)}s');

  const outPath = String.fromEnvironment('OUT');
  if (outPath.isNotEmpty) {
    await table.saveTo(outPath);
    stdout.writeln('PROBE: 已写出 $outPath');
  }

  // 一帧的 64 段快照（按 ASCII 阶梯显示，1 格 ≈ 4 个字节）。
  const bands = 64;
  final frames = table.frameCount;
  for (final f in [10, frames ~/ 4, frames ~/ 2, frames * 3 ~/ 4, frames - 11]) {
    final row = List.generate(bands, (k) => table.bands[f * bands + k] ~/ 26);
    stdout.writeln('PROBE: t=${(f * table.frameMs / 1000).toStringAsFixed(1)}s  '
        '${row.join(',')}');
  }
  try {
    tmp.deleteSync(recursive: true);
  } on FileSystemException {
    // 清不掉不影响结论。
  }
  exit(0);
}
