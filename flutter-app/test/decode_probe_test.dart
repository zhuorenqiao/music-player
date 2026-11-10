// test/decode_probe_test.dart
//
// M3 T1 首日风险闸（spec §18）：audio_decoder 在 Windows 上的解码实测。
// 路线：任意格式 → convertToWav(44100Hz/mono/16bit) → 自解析 WAV 头拿 PCM。
// 夹具用仓库自带的合成 wav（tools/gen_demo_audio.py 的产物链同源），不依赖用户曲库。
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// 最小合法 16bit 单声道 44100Hz WAV：1 秒 440Hz 正弦（手写字节，不靠外部文件）。
Uint8List _synthWav() {
  const sampleRate = 44100;
  const samples = sampleRate; // 1 秒
  final data = BytesBuilder();
  for (var i = 0; i < samples; i++) {
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
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  header.add('data'.codeUnits);
  u32(pcm.length);
  return Uint8List.fromList([...header.takeBytes(), ...pcm]);
}

/// 解析标准 44 字节 RIFF 头 + 16bit PCM，返回 (sampleRate, channels, samples)。
(int, int, int) _parseWav(Uint8List bytes) {
  // RIFF(4) + size(4) + WAVE(4) = 12；fmt chunk = 8 + 16 = 24；data header = 8。
  final dataStart = 12 + 24 + 8;
  final sampleRate = bytes[24] | (bytes[25] << 8) | (bytes[26] << 16) | (bytes[27] << 24);
  final channels = bytes[22] | (bytes[23] << 8);
  final dataSize = bytes[dataStart - 4] |
      (bytes[dataStart - 3] << 8) |
      (bytes[dataStart - 2] << 16) |
      (bytes[dataStart - 1] << 24);
  return (sampleRate, channels, dataSize ~/ 2);
}

void main() {
  // 平台通道需要 binding（audio_decoder 走 MethodChannel）。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 首日风险闸（spec §18）的**单元测试形态**跑不了：audio_decoder 是
  // MethodChannel 插件，`flutter test` 没有 App 宿主 → MissingPluginException。
  // 真实解码验证归 Windows 真机段（M3-ACCEPTANCE §C），这里保留探针代码、
  // 默认 skip，需要手动验时去掉 skip 跑 `flutter test test/decode_probe_test.dart
  // --plain-name audio_decoder -d windows`（integration_test 形态另行搭）。
  const skipReason = 'MethodChannel 需要原生宿主；解码实测走 Windows 真机段（M3-ACCEPTANCE）';

  test('audio_decoder：WAV 信息读取', skip: skipReason, () async {
    final tmp = Directory.systemTemp.createTempSync('decode-probe-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/probe.wav')..writeAsBytesSync(_synthWav());

    final info = await AudioDecoder.getAudioInfo(file.path);
    expect(info.sampleRate, 44100);
    expect(info.channels, 1);
    expect(info.format, 'wav');
  });

  test('audio_decoder：convertToWav 归一化输出（44100/mono/16bit）',
      skip: skipReason, () async {
    final tmp = Directory.systemTemp.createTempSync('decode-probe-');
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
    expect(File(result).existsSync(), isTrue);
    final parsed = _parseWav(File(result).readAsBytesSync());
    expect(parsed.$1, 44100, reason: 'sampleRate');
    expect(parsed.$2, 1, reason: 'channels');
    expect(parsed.$3, 44100, reason: '1 秒的样本数');
    // 波形能量非零（不是静音输出）。
    final bytes = File(result).readAsBytesSync();
    var peak = 0;
    for (var i = 44; i + 1 < bytes.length; i += 2) {
      final v = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16).abs();
      if (v > peak) peak = v;
    }
    expect(peak, greaterThan(1000), reason: '440Hz 0.5 幅度的峰值应显著');
  });
}
