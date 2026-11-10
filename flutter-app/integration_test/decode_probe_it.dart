// integration_test/decode_probe_it.dart
//
// M3 T1 首日风险闸的真机形态：`flutter test integration_test/decode_probe_it.dart
// -d windows`（原生宿主里跑，MethodChannel 可用）。结论写进 M3-ACCEPTANCE §C。
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 最小合法 16bit 单声道 44100Hz WAV：1 秒 440Hz 正弦。
Uint8List _synthWav() {
  const sampleRate = 44100;
  final data = BytesBuilder();
  for (var i = 0; i < sampleRate; i++) {
    final v =
        (0.5 * 32767 * (2 * 3.141592653589793 * 440 * i / sampleRate)).round();
    data.add([v & 0xFF, (v >> 8) & 0xFF]);
  }
  final pcm = data.takeBytes();
  final header = BytesBuilder();
  void u32(int v) =>
      header.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => header.add([v & 0xFF, (v >> 8) & 0xFF]);
  header.add('RIFF'.codeUnits);
  u32(36 + pcm.length);
  header.add('WAVE'.codeUnits);
  header.add('fmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  header.add('data'.codeUnits);
  u32(pcm.length);
  return Uint8List.fromList([...header.takeBytes(), ...pcm]);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('audio_decoder 真机：convertToWav 归一化输出', (tester) async {
    final tmp = await Directory.systemTemp.createTemp('decode-it-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final src = File('${tmp.path}/probe.wav')..writeAsBytesSync(_synthWav());
    final out = '${tmp.path}/probe.out.wav';

    final result = await AudioDecoder.convertToWav(
      src.path,
      out,
      sampleRate: 44100,
      channels: 1,
      bitDepth: 16,
    );
    final bytes = await File(result).readAsBytes();
    binding.takeException();
    expect(bytes.length, greaterThan(44), reason: 'WAV 头 + PCM 应显著非空');
    final sampleRate = bytes[24] | (bytes[25] << 8) | (bytes[26] << 16) | (bytes[27] << 24);
    expect(sampleRate, 44100);
    final channels = bytes[22] | (bytes[23] << 8);
    expect(channels, 1);
    var peak = 0;
    for (var i = 44; i + 1 < bytes.length; i += 2) {
      final v = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16).abs();
      if (v > peak) peak = v;
    }
    expect(peak, greaterThan(1000), reason: '440Hz 0.5 幅度的峰值应显著');
  });
}
