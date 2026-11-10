// lib/wave/wave_thumb.dart
//
// 下拉列表里的波形缩略图（M3 T10）：对译 React `src/lib/wave-thumb.ts`——
// 静态一帧（phase 固定 1.2，装饰种子用样式 id），bandCount=max(14, w/3)、
// waveCount=max(64, w)。供 WaveStylePicker 的 17 项列表用。
import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'wave_signal.dart';
import 'wave_styles.dart';

/// 在 [canvas] 上画一个静态缩略帧。
void renderWaveThumb({
  required Canvas canvas,
  required Size size,
  required WaveStyle style,
  required bool colored,
  required Color accent,
  required String lyricColor,
}) {
  final bandCount = _maxInt(14, (size.width / 3).round());
  final waveCount = _maxInt(64, size.width.round());
  final bands = Float32List(bandCount);
  final wave = Float32List(waveCount);
  fallbackBands(style.id, bandCount, 1.2, bands);
  fallbackWave(style.id, waveCount, 1.2, wave);
  final frame = WaveFrame(
    bands: bands,
    wave: wave,
    level: 0,
    phase: 1.2,
    dt: 1 / 60,
    width: size.width,
    height: size.height,
    live: false,
    seed: style.id,
  );
  final accentHsl = waveAccentOf(accent: accent, lyricColor: lyricColor);
  final palette = WavePalette(
    ramp: style.ramp,
    colored: colored,
    accent: accentHsl,
  );
  style.draw(canvas, frame, palette, Float32List(bandCount));
}

int _maxInt(int a, int b) => a > b ? a : b;
