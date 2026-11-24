// lib/library/audio_info_duration_opener.dart
//
// 先用「读容器头」拿时长，再退回 media_kit。
//
// 为什么值得多这一层：media_kit 的独立内核在安卓上要真的开一条媒体管线，
// 一首歌的时长往往要等几百毫秒，遇到音频焦点 / 解码器排队还可能一直拖到
// 3000ms 预算被掐掉；一批新歌就会长时间停在 `-:--`。audio_decoder 已经在
// 频谱链路里装着（Android 走 MediaExtractor、桌面走各自的原生封装），
// `getAudioInfo` 只读容器头，MP3 / FLAC / M4A / WAV 通常几十毫秒就回来。
// 它读不出来的格式（或不支持该容器的平台）再退回 media_kit，行为不变。
import 'package:audio_decoder/audio_decoder.dart';

import 'duration_probe.dart';

/// 原生容器信息优先、media_kit 兜底的时长 opener。
class AudioInfoDurationOpener {
  AudioInfoDurationOpener(
    this._fallback, {
    Future<double> Function(String source)? audioInfo,
  }) : _audioInfo = audioInfo ?? _readAudioInfo;

  final DurationOpener _fallback;
  final Future<double> Function(String source) _audioInfo;

  /// 只在主路径真的给不出正数时才碰 fallback：
  /// 插件异常、容器头里没有时长（0 / NaN）都算「这条读不出来」。
  Future<double> call(String source) async {
    try {
      final seconds = await _audioInfo(source);
      if (seconds.isFinite && seconds > 0) return seconds;
    } catch (_) {
      // 容器解析失败不是结论，交回 media_kit；它若也失败，外层统一归 NaN。
    }
    return _fallback(source);
  }

  static Future<double> _readAudioInfo(String source) async {
    final info = await AudioDecoder.getAudioInfo(source);
    return info.duration.inMicroseconds / 1e6;
  }
}
