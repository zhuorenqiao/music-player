// lib/lyrics/query.dart
//
// 对译 React 版 src/lib/lyrics-source.js 的 cleanTitle（95-103）与 normalizeQuery
// （146-169）。名称拆分复用 core/name_split.dart（对译同文件 117-139），本层不
// 依赖 metadata/，也不依赖 Track —— 只收 title/artist/duration 三个字段，纯函数。
// 纯 Dart、无 IO、无状态、无 Flutter 依赖。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/lyrics/query_test.dart）：
// * 噪声词表没有 feat，`(feat. X)` 保留；关键词是子串匹配，`(Live at Shanghai)`
//   整段被删；括号开闭字符集允许错配（`[（(【[]` … `[）)】\]]`）；
// * 噪声括号替换带 /g：单次调用即删全部匹配（Dart 用 replaceAll），不是循环到
//   不动点；音轨号正则锚定 ^ 且无 /g，只剥一次（replaceFirst），`01. 02. 歌名`
//   剥完还剩 `02. 歌名`；
// * 音轨号要求数字后必须有 [.\-、_] 分隔符，裸 `[01] 歌名` 不剥；
// * 占位歌手集合只有 {'', '本地文件', '未知歌手'}，精确相等、大小写敏感 ——
//   与译文侧那份含 lowercase 的 5 项集合不同，不要共用；
// * 反推时 artist = split.artist 不再 cleanTitle，trackName = cleanTitle(split.title)
//   是二次清洗；反推用的入参是已清洗过的 title，不是原始 title；
// * duration 守卫是 isFinite && > 0（NaN / 0 / 负数 / 无穷都得 0）；Dart 的
//   double.round() 与 JS Math.round 在正数上同规则（.5 向上），此处恒正无需特判；
// * key 是整串 toLowerCase，不只 lower 歌手或曲名。
import '../core/name_split.dart';

/// 开头音轨号：`01. ` / `01 - ` / `[01]. ` / `(01)_`（lyrics-source.js:98）。
final RegExp _trackNo = RegExp(r'^\s*[[(]?\d{1,3}[)\]]?\s*[.\-、_]\s*');

/// 括号噪声说明（lyrics-source.js:100），大小写不敏感、全局替换。
final RegExp _noiseBracket = RegExp(
  r'[（(【[][^）)】\]]*(?:official|mv|hd|hq|live|remix|伴奏|纯音乐|高音质|无损|完整版|超清|动态歌词|原唱|翻唱)[^）)】\]]*[）)】\]]',
  caseSensitive: false,
);

/// 连续空白折叠成单个空格（lyrics-source.js:102，/g）。
final RegExp _multiSpace = RegExp(r'\s{2,}');

/// 尾部的 -_ 与空白（lyrics-source.js:102，锚定 $、无 /g）。
final RegExp _tailJunk = RegExp(r'[-_\s]+$');

/// 去掉标题里的常见噪声（音质、官方版、伴奏等标记）。
///
/// 原版入参可为 null/undefined（`String(title ?? '')`），Dart 侧签名是非空
/// String，语义不变。
String cleanTitle(String title) {
  var value = title.trim();
  value = value.replaceFirst(_trackNo, '');
  value = value.replaceAll(_noiseBracket, '');
  value = value.replaceAll(_multiSpace, ' ');
  return value.replaceFirst(_tailJunk, '').trim();
}

/// 一条歌词查询的归一化参数（原版 normalizeQuery 的返回同构）。
class LyricsQuery {
  const LyricsQuery({
    required this.trackName,
    required this.artistName,
    required this.duration,
    required this.key,
  });

  final String trackName;
  final String artistName;

  /// 秒，四舍五入；未知为 0。
  final int duration;

  /// `"<trackName>|<artistName>|<duration>".toLowerCase()`。
  final String key;
}

/// 把三个曲目字段归一化成查询参数（原版 normalizeQuery，lyrics-source.js:146）。
///
/// 不依赖 Track：调用方传 track.title / track.artist / track.duration 即可。
LyricsQuery normalizeQuery({
  required String title,
  required String artist,
  required double duration,
}) {
  final cleaned = cleanTitle(title);
  var artistName = artist.trim();

  // 本地文件默认 artist 是「本地文件」，没有信息量，尝试从文件名反推。
  final isPlaceholder =
      artistName.isEmpty || artistName == '本地文件' || artistName == '未知歌手';
  var trackName = cleaned;
  if (isPlaceholder) {
    final split = splitArtistTitleOrNull(cleaned);
    if (split != null) {
      artistName = split.artist;
      trackName = cleanTitle(split.title);
    } else {
      artistName = '';
    }
  }

  final seconds = duration.isFinite && duration > 0 ? duration.round() : 0;
  final key = '$trackName|$artistName|$seconds'.toLowerCase();
  return LyricsQuery(
    trackName: trackName,
    artistName: artistName,
    duration: seconds,
    key: key,
  );
}
