// test/sleep/sleep_audio_test.dart
//
// 程序化助眠声景：WAV 头 / 长度 / 非静音 / 同种子可复现，以及目录表约束。
// 这些是「不上版权音频」的底线 —— 只要公式或采样参数被改坏，两端听到的
// 时长与文件结构就会先对不上。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/sleep/sleep_audio.dart';
import 'package:light_music/sleep/sleep_track.dart';

/// 读 little-endian 16 位**有符号**采样（跳过 44 字节头）。
int _sampleAt(Uint8List wav, int index) {
  final offset = 44 + index * 2;
  return ByteData.sublistView(wav).getInt16(offset, Endian.little);
}

/// 声景的三个听感指标：整体响度（RMS）、1.2kHz 以上能量占比、逐秒包络起伏。
({double rms, double highRatio, double envelope}) _scapeMetrics(Uint8List wav) {
  final n = kSleepSampleRate * kSleepLoopSeconds;
  var sumSq = 0.0;
  var highSq = 0.0;
  var lp = 0.0;
  final a = 1 - 2.0 * math.pi * 1200 / kSleepSampleRate;
  for (var i = 0; i < n; i++) {
    final x = _sampleAt(wav, i) / 0x7fff;
    sumSq += x * x;
    lp += a * (x - lp);
    final high = x - lp;
    highSq += high * high;
  }

  final windowRms = <double>[];
  for (var start = 0; start < n; start += kSleepSampleRate) {
    var sq = 0.0;
    var count = 0;
    for (var i = start; i < start + kSleepSampleRate && i < n; i++) {
      final x = _sampleAt(wav, i) / 0x7fff;
      sq += x * x;
      count++;
    }
    windowRms.add(math.sqrt(sq / count));
  }

  return (
    rms: math.sqrt(sumSq / n),
    highRatio: highSq / sumSq,
    envelope: windowRms.reduce(math.max) / windowRms.reduce(math.min),
  );
}

void main() {
  test('每条声景都生成合法 WAV：44 字节头 + 32 秒单声道 16bit', () {
    final expected = 44 + kSleepSampleRate * kSleepLoopSeconds * 2;
    for (final track in kSleepTracks) {
      final wav = generateSleepWavForId(track.id);
      expect(wav.lengthInBytes, expected, reason: track.id);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');

      final view = ByteData.sublistView(wav);
      expect(view.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(view.getUint16(22, Endian.little), 1, reason: '单声道');
      expect(view.getUint32(24, Endian.little), kSleepSampleRate);
      expect(view.getUint16(34, Endian.little), 16);
      expect(view.getUint32(40, Endian.little), wav.lengthInBytes - 44);
    }
  });

  test('目录：id 唯一、三个页签都有货、副标题都写 32 秒循环', () {
    final ids = kSleepTracks.map((track) => track.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'id 是缓存与播放态的主键');
    for (final track in kSleepTracks) {
      expect(track.detail, contains('32 秒循环'), reason: track.id);
    }
    for (final tab in kSleepTabs) {
      expect(sleepTracksOf(tab.id), isNotEmpty, reason: '${tab.label} 页签不能空');
    }
    expect(
      sleepTracksOf(SleepCategory.scape).length,
      greaterThanOrEqualTo(5),
      reason: '环境声是主入口，不能只有三首',
    );
  });

  test('有声、不削波：峰值落在 0.15~0.83 之间', () {
    for (final track in kSleepTracks) {
      final wav = generateSleepWavForId(track.id);
      var peak = 0;
      for (var i = 0; i < kSleepSampleRate * kSleepLoopSeconds; i++) {
        final value = _sampleAt(wav, i).abs();
        if (value > peak) peak = value;
      }
      expect(peak, greaterThan(0.15 * 0x7fff), reason: '${track.id} 不能是静音');
      expect(peak, lessThanOrEqualTo(0.83 * 0x7fff), reason: '${track.id} 别削波');
    }
  });

  test('同一条曲目两次生成逐字节一致（缓存与双端校验都靠它）', () {
    final a = generateSleepWavForId('sleep-rain');
    final b = generateSleepWavForId('sleep-rain');
    expect(a, orderedEquals(b));
  });

  test('循环接缝：第一个样本紧接最后一个样本，不跳变', () {
    // 生成器把尾巴折回开头：第 0 个样本等于「第 L 个样本」（fold 权重 0），
    // 因此循环点两侧是同一段连续噪声的两个相邻采样，不应出现半个量程的跳变。
    final wav = generateSleepWavForId('sleep-rain');
    final first = _sampleAt(wav, 0);
    final last = _sampleAt(wav, kSleepSampleRate * kSleepLoopSeconds - 1);
    expect((first - last).abs(), lessThan(0.2 * 0x7fff));
  });

  test('三条声景各有各的呼吸：不起沙、也不雷同', () {
    // 需求原话：「声景里的曲子很雷同，沙沙声太大，很吵闹」。这组断言守住
    // 三件事：整体足够轻（RMS 有上限）、高频沙声占比低、三条声景的动态
    // 形态彼此不同（雨稳、潮汐大起大落、林风一阵一阵）。
    final wavRain = generateSleepWavForId('sleep-rain');
    final wavOcean = generateSleepWavForId('sleep-ocean');
    final wavWind = generateSleepWavForId('sleep-wind');

    final rain = _scapeMetrics(wavRain);
    final ocean = _scapeMetrics(wavOcean);
    final wind = _scapeMetrics(wavWind);

    // 响度：都在「轻声」一档，雨稍近、林风最远。
    expect(rain.rms, inInclusiveRange(0.085, 0.115), reason: '雨');
    expect(ocean.rms, inInclusiveRange(0.065, 0.090), reason: '潮汐');
    expect(wind.rms, inInclusiveRange(0.055, 0.078), reason: '林风');

    // 高频「沙」：1.2kHz 以上只占很小一撮，风里的叶摩擦可以略多一点。
    expect(rain.highRatio, lessThan(0.06), reason: '雨不能有宽带沙');
    expect(ocean.highRatio, lessThan(0.04), reason: '潮汐主要是低频');
    expect(wind.highRatio, lessThan(0.09), reason: '林风只留一点叶摩擦');

    // 动态：雨是稳态的，潮汐与林风必须有明显的涨落，不能都做成一条噪声。
    expect(rain.envelope, lessThan(2.0), reason: '雨要稳');
    expect(ocean.envelope, greaterThan(4.0), reason: '潮汐要一涨一落');
    expect(wind.envelope, greaterThan(3.5), reason: '林风要一阵一阵');
  });

  test('新加的六条各是各的声音：流水 / 鸟鸣 / 篝火 / 虫鸣 / 夜曲 / 飞瀑', () {
    // 加曲目最容易犯的错是「配方换了个名字、听感还是那条噪声」。这组断言
    // 盯住每条新声景的辨识点：溪涧的宽带水声、鸟鸣的高频叫声、虫鸣的脉冲、
    // 飞瀑比深夜白噪亮、夜曲是低频乐句。
    final stream = _scapeMetrics(generateSleepWavForId('sleep-stream'));
    final birds = _scapeMetrics(generateSleepWavForId('sleep-birds'));
    final campfire = _scapeMetrics(generateSleepWavForId('sleep-campfire'));
    final crickets = _scapeMetrics(generateSleepWavForId('sleep-crickets'));
    final nocturne = _scapeMetrics(generateSleepWavForId('sleep-nocturne'));
    final waterfall = _scapeMetrics(generateSleepWavForId('sleep-waterfall'));
    final noise = _scapeMetrics(generateSleepWavForId('sleep-noise'));

    // 溪涧：一股一股的水流，但别起伏成潮汐
    expect(stream.rms, inInclusiveRange(0.075, 0.095), reason: '溪涧');
    expect(stream.highRatio, inInclusiveRange(0.08, 0.20), reason: '水面带要有中高频');
    expect(stream.envelope, inInclusiveRange(1.8, 3.2), reason: '流水要匀，不能一阵一阵');

    // 鸟鸣：叫声落在 1.9~3.3kHz，高频占比明显高于雨 / 潮
    expect(birds.rms, inInclusiveRange(0.060, 0.078), reason: '鸟鸣');
    expect(birds.highRatio, greaterThan(0.03), reason: '叫声要在高频留下痕迹');

    // 篝火：低频热气打底，噼啪只是一颗颗的尖
    expect(campfire.rms, inInclusiveRange(0.062, 0.082), reason: '篝火');

    // 虫鸣：脉冲串，逐秒包络必须大起大落，且能量集中在 4kHz 附近
    expect(crickets.highRatio, greaterThan(0.12), reason: '蟋蟀是高音');
    expect(crickets.envelope, greaterThan(5.0), reason: '虫鸣是脉冲，不是稳态噪声');

    // 飞瀑：同样是白噪，但比「深夜白噪」亮一档
    expect(waterfall.rms, inInclusiveRange(0.105, 0.135), reason: '飞瀑');
    expect(waterfall.highRatio, greaterThan(noise.highRatio + 0.04), reason: '飞瀑要更亮');

    // 夜曲：低音区的乐句，几乎没有 1.2kHz 以上的能量
    expect(nocturne.rms, inInclusiveRange(0.10, 0.18), reason: '夜曲');
    expect(nocturne.highRatio, lessThan(0.02), reason: '夜曲是低频垫');
  });

  test('缓存文件名带版本：旧版 WAV 会被清掉，不会继续放旧声音', () async {
    final dir = Directory.systemTemp.createTempSync('sleep_audio_cache_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final legacy = File('${dir.path}/sleep-rain.wav')..writeAsStringSync('old');
    final cache = SleepAudioCache(folderOverride: dir);
    final path = await cache.fileFor(kSleepTracks.first);

    expect(path, endsWith('sleep-rain-${SleepAudioCache.version}.wav'));
    expect(await legacy.exists(), isFalse, reason: '旧文件名必须清掉');
    expect(
      await File(path).length(),
      44 + kSleepSampleRate * kSleepLoopSeconds * 2,
    );
  });
}
