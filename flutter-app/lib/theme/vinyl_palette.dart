// lib/theme/vinyl_palette.dart
//
// 黑胶碟面用到的**字面量**颜色（app.css 里不是变量的那几条）。
//
// 为什么单独一张表、不进 AppTokens：
//   * AppTokens 里那套 `--vinyl-*`（vinylLow / vinylMid / vinylHi / vinylLine）
//     是 CSS 变量，六套主题各写一遍、同值 —— 黑胶是「实体唱片」，两套主题下都
//     保持深色反光（app.css:84-88 的注释）。
//   * 而下面这几条在 app.css 里是**字面量**（没有变量名），只在盘面这一处用：
//     纹路三色、弧形高光、反光、标签落影。它们同样与主题无关，所以这里只放一份，
//     不必在六套主题表里重复抄六遍。
//
// 规矩上「ui/ 内不许出现颜色字面量」指的是 ui/ 目录；配色归 theme/ 管
// （app_tokens.dart 本身就是这么干的）。
import 'package:flutter/material.dart';

/// 黑胶盘面的字面量配色（app.css:789-999）。
class VinylPalette {
  const VinylPalette._();

  /// 粗纹第一段：`#0b0c0e`（app.css:803）—— 纹路的最深一档。
  static const Color grooveA = Color(0xFF0B0C0E);

  /// 粗纹第二段：`#14161a`（app.css:805）—— 纹路里的亮一档。
  static const Color grooveB = Color(0xFF14161A);

  /// 粗纹第三段：`#0a0b0d`（app.css:806）—— 纹路的最深一档，
  /// 同时也是标签位外圈暗环的色（app.css:976 的 `0 0 0 4px #0a0b0d`）。
  static const Color grooveC = Color(0xFF0A0B0D);

  /// 弧形高光：`rgba(255, 255, 255, 0.07)`（app.css:812）——
  /// 唱片轻微翘起时扫过的那道光，很淡，转起来才看得出盘面在动。
  static const Color arc = Color(0x12FFFFFF);

  /// 斜向反光的亮段：`rgba(255, 255, 255, 0.085)`（app.css:824）。
  static const Color reflection = Color(0x16FFFFFF);

  /// 标签位的落影：`rgba(0, 0, 0, 0.95)`（app.css:978）。
  static const Color labelShadow = Color(0xF2000000);
}
