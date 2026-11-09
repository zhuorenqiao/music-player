// lib/lyrics/translate_lang.dart
//
// 对译 React 版 src/lib/translate-source.js:57-101：SCRIPT_PATTERNS、lyricBody、
// needsTranslation。只判字符集、不分词，纯函数、无 IO。
//
// 移植时守住的两个非显而易见点：
// * latin 区间是 \u0041-\u007a（JS 原文），跨过 `Z` 与 `a`，**包含** `[ \ ] ^ _ \``
//   （0x5B–0x60）。逐字照抄，不要「修正」成 A-Za-z。
// * 计数用 allMatches：JS 那边是带 g 标志的 pattern.match()，返回全部命中。

/// 汉字（含扩展 A 与兼容区），translate-source.js:59。
final RegExp _han = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');

/// 平假名 + 片假名，translate-source.js:60。
final RegExp _kana = RegExp(r'[\u3040-\u30ff]');

/// 谚文字母 + 兼容字母 + 音节，translate-source.js:61。
final RegExp _hangul = RegExp(r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]');

/// 拉丁字母，translate-source.js:62（区间逐字照抄，见文件头）。
final RegExp _latin = RegExp(r'[\u0041-\u007a\u00c0-\u024f]');

/// 方括号标签：时间轴、元信息、`[chorus]` 之类，translate-source.js:68。
final RegExp _bracketTag = RegExp(r'\[[^\]\n]*\]');

/// 逐字（增强型）LRC 的行内时间标签，translate-source.js:69。
final RegExp _wordTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

/// 剥掉标签只留正文（translate-source.js:66-70）。
///
/// 不需要 multiLine：`[^\]\n]` 已排除换行，整串替换与逐行等价。
String _lyricBody(String text) =>
    text.replaceAll(_bracketTag, '').replaceAll(_wordTag, '');

/// 这首歌的歌词需不需要配中文译文（translate-source.js:80-101）。
///
/// 假名 / 谚文出现即判外语；汉字够多且占比够高才算中文歌词（中文歌常夹英文 hook）。
bool needsTranslation(String text) {
  final body = _lyricBody(text);
  if (body.trim().isEmpty) return false;
  final kana = _kana.allMatches(body).length;
  final hangul = _hangul.allMatches(body).length;
  if (kana >= 3 || hangul > 0) return true;
  final han = _han.allMatches(body).length;
  final latin = _latin.allMatches(body).length;
  if (han + latin == 0) {
    // 西里尔、阿拉伯、泰文等：既无汉字也无拉丁，一律当外语。
    // JS 原式即 body.trim().length > 0 && han === 0，进入本分支后恒为真，照抄不化简。
    return body.trim().isNotEmpty && han == 0;
  }
  if (han < 8) return latin > 0;
  return han / (han + latin) < 0.35;
}
