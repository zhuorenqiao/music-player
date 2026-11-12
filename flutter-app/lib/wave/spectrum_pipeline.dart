// lib/wave/spectrum_pipeline.dart
//
// M3 Task 8：离线频谱管线（spec §10.1）。
//
// 管线（两段式，MethodChannel 只能跑在主 isolate）：
//   主 isolate：SpectrumPipeline.request
//     → await AudioDecoder.convertToWav（平台通道，**只能在主 isolate**；
//       compute 的 isolate 里没有插件宿主，调了就 MissingPluginException）
//     → File.readAsBytesSync 读出 WAV 字节（纯 IO，isolate 无关）
//   compute isolate：computeSpectrumSync
//     → 解析 WAV 头 + 16bit PCM → Hann 窗分帧 → fft 包幅度谱
//       → readBands 64 段折叠 + 128 点峰谷包络 → SpectrumFrameTable
//   回主 isolate：写 spectrum/<trackKey>.bin 缓存。
//
// 缓存帧格式（spec §10.1 逐字）：头 = 魔数 'LSPC' + 版本 1 + sampleRate +
// frameMs + bandCount + waveCount + frameCount，共 20 字节；每帧
// bands 64×uint8 + wave 128×int8 = 192 字节。**头实际 20B 而非 spec 行文里
// 的「16 字节头」——spec 同一行枚举的七个字段加起来就是 20B（4+2+4+2+2+2+4），
// 「16 字节」是行文笔误，此处以字段清单为准；kBinHeaderSize 记录真实头长，
// 读取端按它校验，不按「16」。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:fft/fft.dart' as fftlib;
import 'package:flutter/foundation.dart';

/// FFT 帧长（spec §10.1）。
const int kFrameSize = 2048;
/// Hann 窗 hop（≈23.2ms @44100；入库帧对齐 50ms，见下）。
const int kHop = 1024;
/// 折叠段数（缓存帧格式）。
const int kBandCount = 64;
/// 时域包络点数（缓存帧格式）。
const int kWavCount = 128;
/// 缓存头字节数（'LSPC'4 + ver2 + sr4 + frameMs2 + bands2 + wave2 + frames4）。
const int kBinHeaderSize = 20;
/// 每帧负载字节数（64×uint8 + 128×int8）。
const int kFrameBytes = kBandCount + kWavCount;
/// 解码目标采样率（convertToWav 归一化输出）。
const int kTargetSampleRate = 44100;
/// 入库帧对齐周期（ms，spec §10.1「每 50ms 一帧」）。
const int kFrameMs = 50;
/// 缓存魔数。
const String kBinMagic = 'LSPC';
/// 缓存格式版本。
const int kBinVersion = 1;

/// 缓存帧表：解析结果，读取端按 positionSeconds 插值取帧。
class SpectrumFrameTable {
  const SpectrumFrameTable({
    required this.sampleRate,
    required this.frameMs,
    required this.frameCount,
    required this.bands,
    required this.wave,
  });

  /// PCM 采样率（恒为 44100）。
  final int sampleRate;
  /// 入库帧周期 ms（恒为 50）。
  final int frameMs;
  /// 入库帧数（每帧 64 bands + 128 wave 点）。
  final int frameCount;
  /// frameCount × 64，uint8。
  final Uint8List bands;
  /// frameCount × 128，int8（时域峰谷包络）。
  final Int8List wave;

  /// 从缓存字节反序列化。头校验（魔数 LSPC、版本 1、字段一致、长度自洽）
  /// 失败返回 null，调用方走重算/装饰回退。
  static SpectrumFrameTable? fromBin(Uint8List bytes) {
    if (bytes.length < kBinHeaderSize) return null;
    final magic = ascii.decode(bytes.sublist(0, 4), allowInvalid: false);
    if (magic != kBinMagic) return null;
    final bd = ByteData.sublistView(bytes);
    final version = bd.getUint16(4, Endian.little);
    if (version != kBinVersion) return null;
    final sampleRate = bd.getUint32(6, Endian.little);
    final frameMs = bd.getUint16(10, Endian.little);
    final bandCount = bd.getUint16(12, Endian.little);
    final waveCount = bd.getUint16(14, Endian.little);
    final frameCount = bd.getUint32(16, Endian.little);
    if (sampleRate <= 0 || frameMs <= 0 || bandCount == 0 || waveCount == 0) {
      return null;
    }
    final need = kBinHeaderSize + frameCount * (bandCount + waveCount);
    if (bytes.length != need) return null;
    final bands = Uint8List.sublistView(bytes, kBinHeaderSize,
        kBinHeaderSize + frameCount * bandCount);
    final wave = Int8List.sublistView(bytes,
        kBinHeaderSize + frameCount * bandCount, need);
    return SpectrumFrameTable(
      sampleRate: sampleRate,
      frameMs: frameMs,
      frameCount: frameCount,
      bands: bands,
      wave: wave,
    );
  }

  /// 序列化为缓存字节（头小端）。
  Uint8List toBin() {
    final out = BytesBuilder();
    out.add(ascii.encode(kBinMagic));
    final bd = ByteData(16);
    bd.setUint16(0, kBinVersion, Endian.little);
    bd.setUint32(2, sampleRate, Endian.little);
    bd.setUint16(6, frameMs, Endian.little);
    bd.setUint16(8, bandCountOf(this), Endian.little);
    bd.setUint16(10, waveCountOf(this), Endian.little);
    bd.setUint32(12, frameCount, Endian.little);
    out.add(bd.buffer.asUint8List());
    out.add(bands);
    out.add(Uint8List.view(wave.buffer, wave.offsetInBytes, wave.length));
    return out.toBytes();
  }

  /// 原子落盘（.tmp + rename，避免读到半截缓存）。
  Future<void> saveTo(String path) async {
    final bytes = toBin();
    final tmp = '$path.tmp';
    final f = File(tmp);
    await f.writeAsBytes(bytes, flush: true);
    try {
      await f.rename(path);
    } on FileSystemException {
      // rename 跨卷失败时退化为普通写。
      await File(path).writeAsBytes(bytes, flush: true);
      await f.delete();
    }
  }

  /// 读缓存；头校验失败/IO 失败返回 null（调用方重算或走装饰回退）。
  static Future<SpectrumFrameTable?> loadFrom(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return fromBin(bytes);
    } on FileSystemException {
      return null;
    }
  }
}

// 字段一致性取值（fromBin 已校验一致，这里只是序列化时的口径）。
int bandCountOf(SpectrumFrameTable t) {
  final n = t.frameCount == 0 ? 0 : t.bands.length ~/ t.frameCount;
  return n > 0 ? n : kBandCount;
}

int waveCountOf(SpectrumFrameTable t) {
  final n = t.frameCount == 0 ? 0 : t.wave.length ~/ t.frameCount;
  return n > 0 ? n : kWavCount;
}

/// 缓存 key 指纹：'$path|$mtimeMs|$size'。
/// mtimeMs/size 缺省时从 File.statSync 读（stat 失败或路径不存在记 -1，
/// 仍能成指纹——不存在的文件指纹稳定，不会反复触发重算）。
String spectrumFingerprint(String path, {int? mtimeMs, int? size}) {
  var m = mtimeMs;
  var s = size;
  if (m == null || s == null) {
    try {
      final st = File(path).statSync();
      if (st.type == FileSystemEntityType.notFound) {
        m ??= -1;
        s ??= -1;
      } else {
        m ??= st.modified.millisecondsSinceEpoch;
        s ??= st.size;
      }
    } on FileSystemException {
      m ??= -1;
      s ??= -1;
    }
  }
  return '$path|$m|$s';
}

/// 缓存文件名：指纹哈希（FNV-1a 64 → hex）。路径含非法文件名字符也不炸。
String spectrumCacheName(String fingerprint) {
  const mask = 0xFFFFFFFFFFFFFFFF;
  var h = 0xCBF29CE484222325 & mask;
  for (final cu in fingerprint.codeUnits) {
    h ^= cu & mask;
    h = (h * 0x100000001B3) & mask;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// 幅度谱 → AnalyserNode 的 0..255 字节语义
/// （getByteFrequencyData：dB 域 minDecibels=-90 / maxDecibels=-15 线性映射）。
/// 独立函数便于测试。
int dbToByte(double dB) {
  const minDb = -90.0;
  const maxDb = -15.0;
  final t = (dB - minDb) / (maxDb - minDb);
  return clampi((t * 255).round(), 0, 255);
}

/// 纯计算核心：WAV(44100/mono/16bit) → 帧表。
///
/// 顶层函数，专供 compute() 调用（compute 只接受顶层/static 函数）。
/// 不碰平台通道——convertToWav 必须在主 isolate 先做完。
SpectrumFrameTable computeSpectrumSync(
  String wavPath, {
  int sampleRate = kTargetSampleRate,
}) {
  final bytes = File(wavPath).readAsBytesSync();
  final pcm = _parseWavPcm(bytes, sampleRate: sampleRate);

  // Hann 窗（逐字公式，预生成一次）。
  final window = Float64List(kFrameSize);
  for (var n = 0; n < kFrameSize; n++) {
    window[n] =
        0.5 * (1 - math.cos(2 * math.pi * n / (kFrameSize - 1)));
  }

  // —— 帧步进表 ——
  // hop=1024（23.22ms），入库帧对齐 50ms（2205 样本）：每个 50ms 槽内扫
  // hop 帧（槽头 0 与 1024 两个候选起点，视口 2048）取「能量最大者」入库。
  final framesPerBin = sampleRate * kFrameMs ~/ 1000; // 2205
  final candidateStarts = <int>[];
  for (var off = 0; off + 1 < kFrameSize; off += kHop) {
    candidateStarts.add(off);
  }

  final binCount = kFrameSize ~/ 2; // 1024
  final slotCount =
      pcm.length <= kFrameSize ? 1 : ((pcm.length - kFrameSize) ~/ framesPerBin + 1);
  final bands = Uint8List(slotCount * kBandCount);
  final wave = Int8List(slotCount * kWavCount);

  final fftBuf = Float64List(kFrameSize);
  final magBuf = Float64List(binCount);
  final byteBuf = Uint8List(binCount); // dbToByte 后的「buf」——readBands 语义

  // readBands 折叠的预计算（与帧无关）：bin 索引 + tilt。
  final binWidth = sampleRate / kFrameSize;
  final freqBins = binCount;
  final maxBin = clampi((10000 / binWidth).round(), 8, freqBins - 1);
  final bandBins = Uint16List(kBandCount);
  final bandTilts = Float64List(kBandCount);
  for (var i = 0; i < kBandCount; i++) {
    final t = i / (kBandCount - 1);
    final bin = clampi(math.pow(maxBin, t).round(), 1, maxBin);
    bandBins[i] = bin;
    bandTilts[i] = 0.78 + 0.72 * t;
  }

  var energy = 0.0; // 当前候选帧的窗内能量（越大者入库）

  void processFrame(int start) {
    // 加窗 + 逐帧能量。PCM 归一化到 [-1,1]（AnalyserNode 的字节语义是
    // float 域 dB 映射——直接喂 int16 会整体抬高 ~90dB 令全段饱和）。
    energy = 0;
    for (var n = 0; n < kFrameSize; n++) {
      final idx = start + n;
      final s = idx < pcm.length ? pcm[idx] : 0;
      final w = window[n] * (s / 32768.0);
      fftBuf[n] = w;
      energy += w * w;
    }
    // FFT → 幅度谱（只取前半；FFT 输入是 real 信号）。
    final spec = fftlib.FFT.Transform(fftBuf);
    for (var k = 0; k < binCount; k++) {
      magBuf[k] = spec[k].abs();
    }
    // 幅度谱 → 0..255 字节语义（AnalyserNode 等价映射）。
    for (var k = 0; k < binCount; k++) {
      byteBuf[k] = dbToByte(20 * math.log(magBuf[k] + 1e-9) / math.ln10);
    }
  }

  // 当前帧的折带结果暂存（写入时复制到 bands/wave 目标槽）。
  final slotBands = Uint8List(kBandCount);
  final slotWave = Int8List(kWavCount);

  void foldBands() {
    for (var i = 0; i < kBandCount; i++) {
      final bin = bandBins[i];
      final hi = bin + 1 > maxBin ? maxBin : bin + 1;
      final value = math.max(byteBuf[bin].toDouble(), byteBuf[hi].toDouble());
      final tilt = bandTilts[i];
      final out =
          clampd(math.pow(value / 255, 1.35) * tilt * 1.05, 0.02, 1.0);
      slotBands[i] = (out * 255).round();
    }
  }

  void foldWave(int frameStart) {
    // 获胜帧的 2048 点窗 → 128 点：每 16 样本块取「abs 最大样本」的带符号
    // 值（峰谷包络：绝对值峰值及其真实极性）→ int8。
    const chunk = kFrameSize ~/ kWavCount; // 16
    for (var i = 0; i < kWavCount; i++) {
      var best = 0;
      var bestAbs = -1;
      final base = frameStart + i * chunk;
      for (var j = 0; j < chunk; j++) {
        final idx = base + j;
        final s = idx < pcm.length ? pcm[idx] : 0;
        final a = s.abs();
        if (a > bestAbs) {
          bestAbs = a;
          best = s;
        }
      }
      slotWave[i] = clampi((best / 32768 * 127).round(), -128, 127);
    }
  }

  for (var slot = 0; slot < slotCount; slot++) {
    final slotStart = slot * framesPerBin;
    var bestEnergy = -1.0;
    var bestStart = -1;
    for (final off in candidateStarts) {
      final start = slotStart + off;
      if (start >= pcm.length) break;
      processFrame(start);
      if (bestStart < 0 || energy > bestEnergy) {
        bestEnergy = energy;
        bestStart = start;
      }
    }
    if (bestStart < 0) {
      // 尾巴槽视口完全溢出——用补零窗口（processFrame 对越界补 0）再算。
      processFrame(slotStart);
      bestStart = slotStart;
    }
    // byteBuf 此时装的是最后一个候选帧（或补零帧）的数据——获胜帧需重算。
    processFrame(bestStart);
    foldBands();
    foldWave(bestStart);
    bands.setRange(slot * kBandCount, (slot + 1) * kBandCount, slotBands);
    wave.setRange(slot * kWavCount, (slot + 1) * kWavCount, slotWave);
  }

  return SpectrumFrameTable(
    sampleRate: sampleRate,
    frameMs: kFrameMs,
    frameCount: slotCount,
    bands: bands,
    wave: wave,
  );
}

/// 解析标准 44 字节 RIFF 头 + 16bit PCM（decode_probe 的 _parseWav 泛化版：
/// 带采样率/声道校验，data chunk 按 16bit 取样本）。
Int16List _parseWavPcm(Uint8List bytes, {required int sampleRate}) {
  if (bytes.length < 44) {
    throw const FormatException('WAV 太短：无合法 RIFF 头');
  }
  if (ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('WAV：非 RIFF/WAVE');
  }
  final bd = ByteData.sublistView(bytes);
  final audioFormat = bd.getUint16(20, Endian.little);
  final channels = bd.getUint16(22, Endian.little);
  final sr = bd.getUint32(24, Endian.little);
  final bitsPerSample = bd.getUint16(34, Endian.little);
  // convertToWav 输出恒为 PCM(1)/16bit；防呆：非 PCM 头直接拒。
  if (audioFormat != 1) {
    throw const FormatException('WAV：audioFormat 非 PCM（预期 convertToWav 已归一化）');
  }
  if (bitsPerSample != 16) {
    throw const FormatException('WAV：预期 16bit（convertToWav 已归一化）');
  }
  if (sr != sampleRate) {
    throw FormatException('WAV：sampleRate=$sr ≠ 目标 $sampleRate');
  }
  // data chunk（标准布局在 offset 36）；头里自带 data 长度。
  const dataHeaderAt = 36;
  if (ascii.decode(bytes.sublist(dataHeaderAt, dataHeaderAt + 4)) != 'data') {
    throw const FormatException('WAV：data chunk 不在标准位置');
  }
  final dataSize = bd.getUint32(dataHeaderAt + 4, Endian.little);
  final sampleCount = dataSize ~/ 2 ~/ channels;
  final out = Int16List(sampleCount);
  // 多声道时求和（convertToWav 已请求 mono，这里只做防御性兼容）。
  for (var i = 0; i < sampleCount; i++) {
    var acc = 0;
    for (var c = 0; c < channels; c++) {
      final off = dataHeaderAt + 8 + (i * channels + c) * 2;
      acc += bd.getInt16(off, Endian.little);
    }
    out[i] = clampi(acc, -32768, 32767);
  }
  return out;
}

int clampi(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
double clampd(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// [SpectrumPipeline] 的可替换边界。
///
/// 装配层的 [SpectrumState] 只认这个接口，不认具体实现：单测注入一个异步可控的
/// 假源就能验「懒请求 / 换曲作废 / 缓存优先」的状态机，不必真的去解 FLAC、
/// 也不必碰平台通道。两个方法与 [SpectrumPipeline] 的公开签名逐字一致。
abstract class SpectrumSource {
  /// 只读已有缓存（不排队、不解码）；没有返回 null。
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath);

  /// 请求帧表：缓存命中直接读，否则入串行队列重算。
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  });
}

/// 带串行队列的入口：主 isolate 侧（平台通道只能在这跑）。
class SpectrumPipeline implements SpectrumSource {
  SpectrumPipeline({required this.cacheDirectory});

  /// '$dataDirectory/spectrum'。
  final String cacheDirectory;

  final Queue<_Job> _queue = Queue();
  bool _draining = false;

  /// 测试/调试用的队列快照（trackKey 顺序，队首在前）。
  List<String> get queueSnapshot => _queue.map((j) => j.trackKey).toList();

  /// 当前缓存中的帧表（命中时直接读，不排队；trackKey 与指纹同源冗余）。
  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) {
    // trackKey 不参与缓存定位（缓存名 = 指纹哈希），保留入参对齐 request。
    final name = spectrumCacheName(spectrumFingerprint(audioPath));
    return SpectrumFrameTable.loadFrom('$cacheDirectory/$name.bin');
  }

  /// 请求帧表：缓存命中（指纹一致）直接读；否则串行排队重算（compute）。
  /// [prioritize] 为 true（当前曲目）时插队到队首。
  /// 返回 null = 解码失败（调用方走装饰回退），不抛。
  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) {
    final completer = Completer<SpectrumFrameTable?>();
    _queue.add(_Job(
      trackKey: trackKey,
      audioPath: audioPath,
      completer: completer,
    ));
    if (prioritize && _queue.length > 1) {
      final job = _queue.removeLast();
      _queue.addFirst(job);
    }
    _drain();
    return completer.future;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        SpectrumFrameTable? table;
        try {
          table = await _runJob(job);
        } catch (_) {
          table = null; // 任何失败 → null（装饰回退），不外抛。
        }
        if (!job.completer.isCompleted) job.completer.complete(table);
      }
    } finally {
      _draining = false;
    }
  }

  Future<SpectrumFrameTable?> _runJob(_Job job) async {
    final cacheDir = Directory(cacheDirectory);
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

    // —— 缓存命中路径 ——
    final fingerprint = spectrumFingerprint(job.audioPath);
    final cachePath = '$cacheDirectory/${spectrumCacheName(fingerprint)}.bin';
    final hit = await SpectrumFrameTable.loadFrom(cachePath);
    if (hit != null) return hit;

    // —— 重算路径 ——
    // 1) 主 isolate：convertToWav（MethodChannel 不能进 compute isolate）。
    final tmpDir = await Directory.systemTemp.createTemp('lspc-');
    final wavPath = '${tmpDir.path}${Platform.pathSeparator}pcm.wav';
    try {
      final impl = _audioDecoderOverride ?? defaultSpectrumAudioDecoder;
      await impl(job.audioPath, wavPath);
      // 2) compute isolate：纯计算 WAV → 帧表（compute 回调必须顶层/static；
      //    只传 wavPath，函数体是纯 IO + 算术，无平台依赖）。
      final table = await compute(computeSpectrumSync, wavPath);
      // 3) 主 isolate：落盘。
      await table.saveTo(cachePath);
      return table;
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录清不掉不影响结果。
      }
    }
  }
}

class _Job {
  _Job({
    required this.trackKey,
    required this.audioPath,
    required this.completer,
  });

  final String trackKey;
  final String audioPath;
  final Completer<SpectrumFrameTable?> completer;
}

/// audio_decoder 的调用缝：[SpectrumPipeline] 的 convertToWav 走这里。
/// 单元测试注入 fake（平台通道在 `flutter test` 里无宿主，MissingPluginException）；
/// 生产缺省走 [defaultSpectrumAudioDecoder]（真插件）。
typedef SpectrumAudioDecoder = Future<String> Function(
    String inputPath, String outputPath);

/// 真实现：主 isolate 调 audio_decoder 插件（平台通道），
/// 输出归一化 44100Hz / mono / 16bit WAV。
Future<String> defaultSpectrumAudioDecoder(
    String inputPath, String outputPath) {
  return AudioDecoder.convertToWav(
    inputPath,
    outputPath,
    sampleRate: kTargetSampleRate,
    channels: 1,
    bitDepth: 16,
  );
}

/// 测试注入点：替换 [SpectrumPipeline] 里 convertToWav 的实现
/// （传 null 恢复真实现）。
void setSpectrumAudioDecoderForTest(SpectrumAudioDecoder? impl) {
  _audioDecoderOverride = impl;
}

SpectrumAudioDecoder? _audioDecoderOverride;
