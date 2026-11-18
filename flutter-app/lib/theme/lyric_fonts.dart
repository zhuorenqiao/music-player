// lib/theme/lyric_fonts.dart
//
// 「T」面板里可选的歌词字体：对译 React 版 `src/lib/lyric-fonts.ts` 的
// `LYRIC_FONTS`（9 款，id 与 React 一字不差 —— 只影响本机 prefs，跨端不必互通，
// 但同一套 id 让两边的设置项看起来是同一件事）。
//
// 两种来源：
//   * 系统已装字体（思源宋 / 汉仪黑 / Noto 黑 / 等线细 / 楷体 / 等宽码）——
//     即时生效、零体积，缺了按 `fallback` 逐级落到同气质的字上；
//   * 随包内置的开源字体（得意黑 / 霞鹜文楷）—— 放在 `assets/fonts`，pubspec
//     里注册成 `LyricSmiley` / `LyricWenKai` 两个家族，离线可用。
//
// 与 React 版的差别只在「怎么找到字体」：Web 那边按 `font-family` 栈逐个试，
// Flutter 这边是 `fontFamily` + `fontFamilyFallback`（引擎按**字形**逐字降级，
// 主家族没有的字自动落到后面几个）；家族名带 Lyric 前缀同样是为了不和用户系统
// 里装的同名开源字体打架。
import 'package:flutter/painting.dart';

/// 一款可选字体。
class LyricFontOption {
  const LyricFontOption({
    required this.id,
    required this.name,
    required this.hint,
    this.family = '',
    this.fallback = const <String>[],
  });

  /// 存进 prefs 的 id；改名会让旧值失效，由 [findLyricFont] 兜回默认。
  final String id;

  /// 面板按钮上的文字（用该字体自己渲染）与读屏名。
  final String name;

  /// 提示里的补充说明：这款字是什么气质。
  final String hint;

  /// 主字体家族；空串表示跟随界面默认字体。
  final String family;

  /// 主家族缺字时的降级链（同一套「气质」的字按优先级排）。
  final List<String> fallback;

  /// true = 跟随界面字体（React 的 `stack: ''`）。
  bool get isDefault => family.isEmpty;
}

/// 字体清单（顺序即面板里 3 列网格的排布，默认那款排第一）。
const List<LyricFontOption> kLyricFonts = <LyricFontOption>[
  LyricFontOption(id: 'default', name: '默认', hint: '界面字体'),
  LyricFontOption(
    id: 'song',
    name: '思源宋',
    hint: '粗衬线，海报/杂志感',
    family: 'Source Han Serif SC',
    fallback: <String>['Noto Serif SC', 'Songti SC', 'SimSun', 'serif'],
  ),
  LyricFontOption(
    id: 'hyhei',
    name: '汉仪黑',
    hint: '商业黑体，块面硬朗',
    family: 'HYZhongHei 197',
    fallback: <String>['Noto Sans SC', 'Microsoft YaHei', 'sans-serif'],
  ),
  LyricFontOption(
    id: 'noto',
    name: 'Noto 黑',
    hint: '中性无衬线，干净',
    family: 'Noto Sans SC',
    fallback: <String>['PingFang SC', 'Microsoft YaHei', 'sans-serif'],
  ),
  LyricFontOption(
    id: 'deng',
    name: '等线细',
    hint: '极细笔画，轻盈',
    family: 'DengXian Light',
    fallback: <String>['DengXian', 'Noto Sans SC', 'Microsoft YaHei'],
  ),
  LyricFontOption(
    id: 'kai',
    name: '楷体',
    hint: '手写书法，笔锋',
    family: 'KaiTi',
    fallback: <String>['STKaiti', 'Kaiti SC', 'Noto Serif SC'],
  ),
  LyricFontOption(
    id: 'mono',
    name: '等宽码',
    hint: '终端等宽，科技感',
    family: 'Cascadia Code',
    fallback: <String>['Consolas', 'Noto Sans SC', 'Microsoft YaHei', 'monospace'],
  ),
  LyricFontOption(
    id: 'smiley',
    name: '得意黑',
    hint: '倾斜显示体，最有潮流感',
    // pubspec 里注册的家族名（权重与 React 版一致：它就是唯一的字重）。
    family: 'LyricSmiley',
    fallback: <String>['Smiley Sans Oblique', 'Noto Sans SC', 'Microsoft YaHei'],
  ),
  LyricFontOption(
    id: 'wenkai',
    name: '霞鹜文楷',
    hint: '文楷手写体，温润有笔锋',
    family: 'LyricWenKai',
    fallback: <String>['LXGW WenKai', 'Noto Serif SC', 'KaiTi'],
  ),
];

/// 默认那款（跟随界面字体），也是找不到已存 id 时的兜底。
///
/// 直接取清单第一条，不再另写一份常量：两份定义一旦分叉，面板上的选中态
/// 就会和「当前实际字体」对不上。
final LyricFontOption kDefaultLyricFont = kLyricFonts.first;

/// 按 id 取一款；不认识就兜回默认。
LyricFontOption findLyricFont(String? id) {
  for (final font in kLyricFonts) {
    if (font.id == id) return font;
  }
  return kDefaultLyricFont;
}

/// 歌词字号缩放的取值范围（百分比）。100 = 设计稿原值（React 版
/// `wave-style.tsx:21-23` 同值）。
const int kLyricScaleMin = 70;
const int kLyricScaleMax = 150;
const int kLyricScaleDefault = 100;

/// 字号滑杆的步长（React 版 `step={5}`）。
const int kLyricScaleStep = 5;

/// 百分比 → 缩放系数（1.0 = 原值）。
double lyricScaleFactor(int percent) => percent / 100;

/// 文本样式最后一次装配：主家族 + 降级链，默认那款原样返回（跟随界面字体）。
///
/// `fontFamily` 传空串在 Flutter 里等于「用主题字体」，所以默认那款直接不写。
TextStyle applyLyricFont(TextStyle style, LyricFontOption font) {
  if (font.isDefault) return style;
  return style.copyWith(
    fontFamily: font.family,
    fontFamilyFallback: font.fallback.isEmpty ? null : font.fallback,
  );
}
