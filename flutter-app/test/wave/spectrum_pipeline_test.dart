// test/wave/spectrum_pipeline_test.dart
//
// M3 Task 8：离线频谱管线测试（spec §10.1）。
// 真解码（audio_decoder 平台通道）在 `flutter test` 无宿主，管线入口的
// convertToWav 缝隙注入 fake（直接写合成 WAV）；纯计算核心 computeSpectrumSync
// 是纯 Dart，直测真跑。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';

/// 合成 WAV：44100Hz/mono/16bit，固定 4 秒——前 1 秒 440Hz、后 3 秒静音。
/// 返回字节（标准 44B RIFF 头）。
const double amplitude = 0.5;
const int freq = 440;

Uint8List synthWav() {
  const totalSamples = 4 * 44100;
  const toneSamples = 1 * 44100;
  const freq = 440.0;
  const amplitude = 0.5;
  const sr = 44100;
  final data = BytesBuilder();
  for (var i = 0; i < totalSamples; i++) {
    final v = i < toneSamples
        ? (amplitude *
                32767 *
                math.sin(2 * math.pi * freq * i / sr))
            .round()
        : 0;
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
  u32(sr);
  u32(sr * 2);
  u16(2);
  u16(16);
  header.add('data'.codeUnits);
  u32(pcm.length);
  return Uint8List.fromList([...header.takeBytes(), ...pcm]);
}

/// 与 lib 侧 dbToByte 相同的映射，测试用它换算期望值。
int expectDbToByte(double dB) {
  const minDb = -90.0;
  const maxDb = -15.0;
  final t = (dB - minDb) / (maxDb - minDb);
  return ((t * 255).round()).clamp(0, 255);
}

void main() {
  late Directory tmp;
  late File wavFile; // 4 秒：前 1 秒 440Hz、后 3 秒静音

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lspc-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    wavFile = File('${tmp.path}/tone.wav')..writeAsBytesSync(synthWav());
  });

  test('computeSpectrumSync：帧数 ≈ 80（±2）+ 头字段', () {
    final t = computeSpectrumSync(wavFile.path);
    // 4s → 4000 样本/50ms 槽 2205 → 期望 80（尾槽补零视口内）。
    expect(t.frameCount, inInclusiveRange(78, 82),
        reason: '4000/2205 ≈ 80，±2 容差');
    expect(t.sampleRate, 44100);
    expect(t.frameMs, 50);
    expect(t.bands.length, t.frameCount * 64);
    expect(t.wave.length, t.frameCount * 128);
  });

  test('computeSpectrumSync：440Hz 峰段显著高于两端；静音段贴 0.02 下限', () {
    final t = computeSpectrumSync(wavFile.path);
    // 第一帧（440Hz 主能量）。对数折叠下 440Hz 落在 bin 20-21 →
    // 464^t = 20 → t ≈ 0.488 → 段 30-31（不是「低段」——对数轴上 440Hz
    // 在 0~10kHz 的中点附近）。峰段应显著高于两端（Hann 旁瓣 + 0.02 下限）。
    final f0 = t.bands.sublist(0, 64);
    final peakAvg = _avg(f0.sublist(28, 34));
    final lowAvg = _avg(f0.sublist(0, 8));
    final highAvg = _avg(f0.sublist(56, 64));
    expect(peakAvg, greaterThan(lowAvg * 1.5),
        reason: '440Hz 的峰段（对数轴中段）应显著高于低频端');
    expect(peakAvg, greaterThan(highAvg * 1.5),
        reason: '峰段应显著高于高频端（高频只有 Hann 旁瓣）');
    expect(peakAvg, greaterThan(60), reason: '0.5 幅度正弦的峰段字节值应可观');

    // 静音段（后 3 秒，帧 ≥ 20）：折叠公式 out ≥ 0.02 下限 → uint8 ≥ 5。
    final silent = t.bands.sublist(40 * 64, 60 * 64);
    for (final v in silent) {
      expect(v, lessThanOrEqualTo(8),
          reason: '静音帧 pow(≈0/255,1.35)*tilt*1.05 贴 0.02 下限 → ≤8');
      expect(v, greaterThanOrEqualTo(5), reason: '下限 0.02*255≈5.1 → ≥5');
    }
    // 静音段时域包络全 0。
    final silentWave = t.wave.sublist(40 * 128, 60 * 128);
    expect(silentWave.every((v) => v == 0), isTrue);
  });

  test('toBin/fromBin 往返：字段一致、bands/wave 逐位一致', () {
    final t = computeSpectrumSync(wavFile.path);
    final bin = t.toBin();

    // 头字段直接断言（小端）。
    expect(String.fromCharCodes(bin.sublist(0, 4)), 'LSPC');
    final bd = ByteData.sublistView(bin);
    expect(bd.getUint16(4, Endian.little), 1);
    expect(bd.getUint32(6, Endian.little), 44100);
    expect(bd.getUint16(10, Endian.little), 50);
    expect(bd.getUint16(12, Endian.little), 64);
    expect(bd.getUint16(14, Endian.little), 128);
    expect(bd.getUint32(16, Endian.little), t.frameCount);
    expect(bin.length, 20 + t.frameCount * 192);

    final back = SpectrumFrameTable.fromBin(bin)!;
    expect(back.sampleRate, t.sampleRate);
    expect(back.frameMs, t.frameMs);
    expect(back.frameCount, t.frameCount);
    expect(back.bands.length, t.bands.length);
    expect(back.wave.length, t.wave.length);
    // 逐位一致。
    var same = true;
    for (var i = 0; i < t.bands.length; i++) {
      if (t.bands[i] != back.bands[i]) {
        same = false;
        break;
      }
    }
    expect(same, isTrue, reason: 'bands 逐位一致');
    for (var i = 0; i < t.wave.length; i++) {
      if (t.wave[i] != back.wave[i]) {
        same = false;
        break;
      }
    }
    expect(same, isTrue, reason: 'wave 逐位一致');
  });

  test('fromBin：坏头/坏版本/长度不符 → null', () {
    final t = SpectrumFrameTable(
      sampleRate: 44100,
      frameMs: 50,
      frameCount: 2,
      bands: Uint8List(2 * 64),
      wave: Int8List(2 * 128),
    );
    final bin = t.toBin();

    // 魔数坏。
    final badMagic = Uint8List.fromList(bin);
    badMagic[0] = 0x58; // 'X'
    expect(SpectrumFrameTable.fromBin(badMagic), isNull);
    // 版本坏。
    final badVer = Uint8List.fromList(bin);
    ByteData.sublistView(badVer).setUint16(4, 2, Endian.little);
    expect(SpectrumFrameTable.fromBin(badVer), isNull);
    // 长度不符（截尾）。
    expect(SpectrumFrameTable.fromBin(bin.sublist(0, bin.length - 1)), isNull);
    // 太短。
    expect(SpectrumFrameTable.fromBin(Uint8List(8)), isNull);
  });

  test('saveTo/loadFrom 往返（真临时目录）', () async {
    final t = computeSpectrumSync(wavFile.path);
    final path = '${tmp.path}/track.bin';
    await t.saveTo(path);
    expect(File(path).existsSync(), isTrue);

    final back = await SpectrumFrameTable.loadFrom(path);
    expect(back, isNotNull);
    expect(back!.frameCount, t.frameCount);
    expect(back.sampleRate, t.sampleRate);
    var same = true;
    for (var i = 0; i < t.bands.length; i++) {
      if (t.bands[i] != back.bands[i]) {
        same = false;
        break;
      }
    }
    expect(same, isTrue, reason: '落盘后 bands 逐位一致');
  });

  test('spectrumFingerprint：同参数同值；mtime/size 变化 → 指纹变化', () {
    final fp1 = spectrumFingerprint(wavFile.path);
    final fp2 = spectrumFingerprint(wavFile.path);
    expect(fp1, equals(fp2));
    expect(fp1.split('|').length, 3, reason: 'path|mtimeMs|size 三段');

    // 显式 mtime/size 同参同值。
    expect(spectrumFingerprint(wavFile.path, mtimeMs: 5, size: 10),
        spectrumFingerprint(wavFile.path, mtimeMs: 5, size: 10));
    expect(spectrumFingerprint(wavFile.path, mtimeMs: 5, size: 10),
        isNot(spectrumFingerprint(wavFile.path, mtimeMs: 6, size: 10)));
    expect(spectrumFingerprint(wavFile.path, mtimeMs: 5, size: 10),
        isNot(spectrumFingerprint(wavFile.path, mtimeMs: 5, size: 11)));

    // touch 文件（mtime 变）→ 指纹变。
    final before = spectrumFingerprint(wavFile.path);
    // 同 stat 粒度下 mtime 可能不变——先确保过 1ms 再 touch。
    final newTime = DateTime.now().add(const Duration(milliseconds: 50));
    File(wavFile.path).setLastModifiedSync(newTime);
    final after = spectrumFingerprint(wavFile.path);
    expect(after, isNot(before), reason: 'mtime 变 → 指纹变');

    // 不存在的文件：stat 失败记 -1，仍成指纹（不抛）。
    final fpMissing = spectrumFingerprint('${tmp.path}/no-such.wav');
    expect(fpMissing.endsWith('|-1|-1'), isTrue,
        reason: 'stat 失败 → mtimeMs=-1、size=-1');
  });

  test('dbToByte：-90→0、-15→255、线性中点、clamp 上下界', () {
    expect(dbToByte(-90), 0);
    expect(dbToByte(-15), 255);
    expect(dbToByte(-52.5), expectDbToByte(-52.5)); // 中点 127/128
    expect(dbToByte(-100), 0, reason: '低于 minDb clamp 到 0');
    expect(dbToByte(0), 255, reason: '高于 maxDb clamp 到 255');
    // 独立映射核对：-30dB → (60/75)*255 = 204。
    expect(dbToByte(-30), 204);
  });

  test('SpectrumPipeline：第一次重算、第二次命中缓存（解码调用计数 1）', () async {
    var decodeCalls = 0;
    setSpectrumAudioDecoderForTest((input, output) async {
      decodeCalls++;
      // fake 解码：直接把合成 WAV 拷成「归一化输出」。
      File(output).writeAsBytesSync(File(input).readAsBytesSync());
      return output;
    });
    addTearDown(() => setSpectrumAudioDecoderForTest(null));

    final cacheDir = '${tmp.path}/spectrum';
    final p = SpectrumPipeline(cacheDirectory: cacheDir);
    final t1 = await p.request('track-a', wavFile.path);
    expect(t1, isNotNull);
    expect(decodeCalls, 1, reason: '首次未命中缓存 → 解码一次');
    expect(Directory(cacheDir).existsSync(), isTrue);

    final t2 = await p.request('track-a', wavFile.path);
    expect(t2, isNotNull);
    expect(decodeCalls, 1, reason: '第二次同 key 同指纹 → 缓存命中，不再解码');
    expect(t2!.frameCount, t1!.frameCount);
    expect(t2.bands.length, t1.bands.length);
  });

  test('SpectrumPipeline：prioritize 插队到队首', () async {
    // 不消费结果前先排队三个，观察 queueSnapshot 顺序。
    setSpectrumAudioDecoderForTest((input, output) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(output).writeAsBytesSync(File(input).readAsBytesSync());
      return output;
    });
    addTearDown(() => setSpectrumAudioDecoderForTest(null));

    final p = SpectrumPipeline(cacheDirectory: '${tmp.path}/spectrum2');
    // 让第一条阻塞队（fake 延时 5ms），随后两条压入，当前曲目插队。
    final f1 = p.request('track-1', wavFile.path);
    // 等到 _drain 确实摘走第一条（fake 已开跑）再排队断言。
    await Future<void>.delayed(const Duration(milliseconds: 2));
    unawaited(p.request('track-2', wavFile.path));
    unawaited(p.request('track-3', wavFile.path));
    expect(p.queueSnapshot, ['track-2', 'track-3']);
    unawaited(p.request('track-now', wavFile.path, prioritize: true));
    expect(p.queueSnapshot, ['track-now', 'track-2', 'track-3'],
        reason: 'prioritize 把当前曲目插到队首');
    await f1;
    await p.request('track-now', wavFile.path);
    await p.request('track-2', wavFile.path);
    await p.request('track-3', wavFile.path);
  });

  test('SpectrumPipeline：坏文件路径 → request 返回 null 不抛', () async {
    // fake 解码器模拟 AudioConversionException：输出文件不写 + 抛。
    setSpectrumAudioDecoderForTest((input, output) async {
      throw FileSystemException('decode failed', input);
    });
    addTearDown(() => setSpectrumAudioDecoderForTest(null));

    final p = SpectrumPipeline(cacheDirectory: '${tmp.path}/spectrum3');
    final t = await p.request('track-bad', '${tmp.path}/no-such-file.mp3');
    expect(t, isNull, reason: '解码失败 → null（调用方走装饰回退）');
  });
}

double _avg(List<int> xs) {
  if (xs.isEmpty) return 0;
  var s = 0;
  for (final v in xs) {
    s += v;
  }
  return s / xs.length;
}
