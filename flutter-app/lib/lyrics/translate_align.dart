// lib/lyrics/translate_align.dart
//
// 对译 React 版 src/lib/translate-source.js:277-422：normalizeLine、headOfSameTime、
// cueIndexAt、estimateShift、joinFragments 与 alignTranslation 全流程。
// 纯函数、无 IO，只消费 T2 的 parseLrc / LyricLine。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉）：
// * cueIndexAt 的中点取 Math.ceil((low+high)/2)（同 findActiveCue），命中后回卷到
//   同刻那组的第一行；headOfSameTime 用 === 比较 time，NaN 不等于 NaN；
// * 带时间轴路径的覆盖率分母是 translated.length，不是 lines.length；
// * 中位数是上中位数 diffs[floor(n/2)]（偶数个不做平均），|median| > 20 才归零；
// * 纯文本路径 matched / lines.length 严格小于 0.5 才整首退回单语。
import 'dart:math' show max;

import 'lrc_parser.dart';

/// 整体偏移的可信范围（秒），translate-source.js:41。
const int _maxShift = 20;

/// 对齐质量下限，translate-source.js:44-45。
const double _minTimedCoverage = 0.25;
const double _minPlainCoverage = 0.5;

/// 起手保护（秒），translate-source.js:51。
const double _leadIn = 1.5;

/// 归一化行文本用于锚点匹配，translate-source.js:282。
///
/// 先小写再剥：`\s` 与全角空格 U+3000 之外，删 `,.;:!?·、。，．：；!?'"「」『』（）()【】[]<>-`。
/// 字符类逐字照抄（只有半角 `!`，没有全角 `！`），与 needsTranslation 的字符集是两套。
final RegExp _lineNoise = RegExp(
  r'''[\s　,.;:!?·、。，．：；!?'"「」『』（）()【】\[\]<>-]''',
);

/// 同一区间内多条译文合并时的多余空白，translate-source.js:342。
final RegExp _multiSpace = RegExp(r'\s{2,}');

String _normalizeLine(String text) =>
    text.toLowerCase().replaceAll(_lineNoise, '');

/// 同一时刻可能挂着原文 + 另一语种：译文要挂在这一组的第一行上（translate-source.js:286）。
///
/// `time == time` 对 NaN 恒为 false，与 JS 的 `===` 一致。
int _headOfSameTime(List<LyricLine> lines, int index) {
  var at = index;
  while (at > 0 && lines[at - 1].time == lines[at].time) {
    at -= 1;
  }
  return at;
}

/// 二分：返回 time 落在哪一行（早于首行算第 0 行；同一时刻多行时取第一行）。
///
/// 改写自 translate-source.js:295-310，中点必须向上取整，否则走不到最后一格。
int _cueIndexAt(List<LyricLine> lines, double time) {
  if (lines.isEmpty || time <= lines[0].time) return 0;
  var low = 0;
  var high = lines.length - 1;
  while (low < high) {
    final mid = ((low + high) / 2).ceil();
    if (lines[mid].time <= time) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return _headOfSameTime(lines, low);
}

/// 用两边原文里文本相同的行，估「译文库时间轴 − 手上歌词时间轴」的整体偏移。
///
/// 对齐 translate-source.js:318-339：`firstAt` 只记首次出现（重复副歌行都用第一行），
/// 锚点不足 3 个或中位偏移超过 ±[_maxShift] 都按 0。
double _estimateShift(List<LyricLine> lines, List<LyricLine> anchors) {
  final firstAt = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final key = _normalizeLine(lines[i].text);
    if (key.isNotEmpty && !firstAt.containsKey(key)) firstAt[key] = i;
  }
  final diffs = <double>[];
  for (final anchor in anchors) {
    final index = firstAt[_normalizeLine(anchor.text)];
    if (index == null) continue;
    if (!anchor.time.isFinite) continue;
    if (!lines[index].time.isFinite) continue;
    diffs.add(anchor.time - lines[index].time);
  }
  if (diffs.length < 3) return 0;
  diffs.sort();
  final median = diffs[diffs.length ~/ 2];
  return median.abs() > _maxShift ? 0 : median;
}

/// 同一个时间区间里的多条译文并成一行（translate-source.js:342）。
String _joinFragments(List<String> texts) =>
    texts.join(' ').replaceAll(_multiSpace, ' ').trim();

/// 把译文 LRC 落到展示行上（translate-source.js:351-422）。
///
/// [lines] 是展示行：带时间轴的 cues，或纯文本行（`time` 为 `double.nan`）；
/// 混合数组（部分有 time）按纯文本路径走。返回与 [lines] 等长的列表，
/// 没有对应译文的位置是空串。
List<String> alignTranslation(
  List<LyricLine> lines,
  String translatedLrc, [
  String originalLrc = '',
]) {
  final slots = List<String>.filled(lines.length, '');
  if (lines.isEmpty || translatedLrc.isEmpty) return slots;
  final translated = [
    for (final line in parseLrc(translatedLrc).lines)
      if (line.text.isNotEmpty) line,
  ];
  if (translated.isEmpty) return slots;
  final original = originalLrc.isEmpty
      ? <LyricLine>[]
      : [
          for (final line in parseLrc(originalLrc).lines)
            if (line.text.isNotEmpty) line,
        ];

  if (lines.every((line) => line.time.isFinite)) {
    final shift = _estimateShift(lines, original);
    final buckets = [for (var i = 0; i < lines.length; i++) <String>[]];
    for (final line in translated) {
      final at = max(0.0, line.time - shift);
      var index = _cueIndexAt(lines, at);
      if (index + 1 < lines.length) {
        final next = lines[index + 1];
        // 起手保护：离下一句更近（且不早于本句起始）时归给下一句，并回到那一组的首行。
        if (next.time > at && next.time - at <= _leadIn) {
          index = _headOfSameTime(lines, index + 1);
        }
      }
      buckets[index].add(line.text);
    }
    for (var i = 0; i < buckets.length; i++) {
      slots[i] = _joinFragments(buckets[i]);
    }
    final covered =
        slots.where((slot) => slot.isNotEmpty).length / translated.length;
    return covered < _minTimedCoverage
        ? List<String>.filled(lines.length, '')
        : slots;
  }

  // 纯文本歌词没有时间轴，只能借译文库自己那份原文的对应关系：
  // 先把译文按时间落到原文行上，再拿我们这行的文本去配那行原文。
  final buckets = [for (var i = 0; i < original.length; i++) <String>[]];
  if (original.isNotEmpty) {
    for (final line in translated) {
      var index = 0;
      while (index + 1 < original.length &&
          original[index + 1].time <= line.time) {
        index += 1;
      }
      buckets[index].add(line.text);
    }
  }
  final byKey = <String, String>{};
  for (var i = 0; i < original.length; i++) {
    final key = _normalizeLine(original[i].text);
    final text = _joinFragments(buckets[i]);
    if (key.isNotEmpty && text.isNotEmpty && !byKey.containsKey(key)) {
      byKey[key] = text;
    }
  }
  var matched = 0;
  for (var i = 0; i < lines.length; i++) {
    final found = byKey[_normalizeLine(lines[i].text)];
    if (found != null) {
      slots[i] = found;
      matched += 1;
    }
  }
  if (matched / lines.length >= _minPlainCoverage) return slots;
  return List<String>.filled(lines.length, '');
}
