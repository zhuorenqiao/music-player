// lib/core/name_split.dart
//
// 对译 React 版 src/lib/lyrics-source.js 的 splitArtistTitle（117-139）与
// CJK_PATTERN（106）。原版这一份是共享基础设施，被 state/library.tsx:134（文件名
// 拆分）、state/lyrics-file.ts:48（手动歌词配对）与 normalizeQuery（146-169）三处
// 复用；Flutter 侧 metadata/ 与 lyrics/ 都要它，放 core/ 才不会让这两层互相依赖。
// 纯 Dart、无 IO、无状态、无 Flutter 依赖。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/core/name_split_test.dart）：
// * 分隔符集合只有 [-–—]（U+002D / U+2013 / U+2014），不含全角 －（U+FF0D）、不含 U+2212；
// * 带空格版优先，而且一旦匹配就定局：任一侧 trim 后为空即返回 null，**不再回退紧凑版**；
// * 紧凑版要求两侧都「含」汉字 —— 是 hasMatch 而非全串匹配，所以「初音ミク」这种
//   汉字混假名的左侧照样算含汉字（纯假名的「ミク-歌名」才不算）；
// * CJK_PATTERN 只覆盖 U+3400-U+9FFF 与 U+F900-U+FAFF，不含假名、不含谚文；
// * 两个左侧量词都是懒惰的（`.{1,60}?`），故在**第一个**分隔符处拆，右侧可以再见分隔符；
// * Dart 的 RegExp 与 JS 同源（irregexp），`.` 默认不匹配换行 —— 不要开 dotAll，
//   否则含换行的名字会被拆出跨行的歌手/曲名，原版不会。

/// 带空格版：`歌手 - 曲名`，也认 ` – ` / ` — `（lyrics-source.js:123）。
final RegExp _spaced = RegExp(r'^(.{1,60}?)\s+[-–—]\s+(.{1,80})$');

/// 紧凑版：无空格，还要两侧都含汉字才认（lyrics-source.js:130）。
final RegExp _tight = RegExp(r'^(.{1,60}?)[-–—](.{1,80})$');

/// 汉字判定（lyrics-source.js:106）。防 `track-02`、`Jay-Z` 被紧凑版误拆。
final RegExp _cjk = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');

/// 从「歌手 - 曲名」形式的名字里拆出歌手与曲名，拆不出返回 null。
///
/// 原版入参可为 null/undefined（`String(raw ?? '')`），Dart 侧签名是非空 String，
/// 空串与纯空白走同一条 null 分支，语义不变。
({String artist, String title})? splitArtistTitleOrNull(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  final spaced = _spaced.firstMatch(value);
  if (spaced != null) {
    final artist = spaced.group(1)!.trim();
    final title = spaced.group(2)!.trim();
    // 原版这里直接 return（三元），紧凑版不再试 —— 不要改成 fallthrough。
    return artist.isNotEmpty && title.isNotEmpty
        ? (artist: artist, title: title)
        : null;
  }

  final tight = _tight.firstMatch(value);
  if (tight != null) {
    final artist = tight.group(1)!.trim();
    final title = tight.group(2)!.trim();
    if (artist.isNotEmpty &&
        title.isNotEmpty &&
        _cjk.hasMatch(artist) &&
        _cjk.hasMatch(title)) {
      return (artist: artist, title: title);
    }
  }
  return null;
}
