// lib/lyrics/lyrics_credits.dart
//
// 各歌词源共用的「开头署名清理」：网易云 / 汽水 / 酷狗 的 LRC 开头常带一串
// 带时间轴的制作署名（作词、作曲、编曲、录音师、Lyrics by …），而解析器的
// 署名清理只扫前 4 行（lrc_parser.dart 的 _creditScanLimit），多出来的会在
// 歌词页顶上排成一片。这里在入库前先把开头连续的署名行剥掉。
//
// 规则刻意收紧过：
// * 冒号后必须还有内容，避免把「鼓声响起：……」这类正文当成署名；
// * OP / SP 单独一条大小写敏感规则，否则英文歌词的 `Open your eyes:` 会被误判；
// * 英文 `Lyrics by:` / `Composed by:` 也认，酷狗的英文歌词常见这种写法。

/// 开头署名行的扫描上限（正常 LRC 的署名不会超过十来行）。
const int creditScanLimit = 12;

/// 时间标签：`[00:01]` / `[00:01.2]` / `[00:01.23]` / `[00:01.234]`（与 lrc_parser 同款）。
final RegExp timeTag = RegExp(r'\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]');

/// 中文制作署名：`作曲 :` / `录音师 :` / `混音工程师 :` ……（冒号前半段取前缀词）。
final RegExp _creditLine = RegExp(
  r'^(?:作词|作曲|编曲|词|曲|制作人|制作|出品|监制|混音|母带|录音|和声|合声|伴唱|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|演唱|原唱|配唱|编写)[^:：]{0,14}[:：]\s*\S',
  caseSensitive: false,
);

/// 英文制作署名：`Lyrics by：` / `Composed by:` / `Arranged by:` ……
final RegExp _creditLatinWords = RegExp(
  r'^(?:lyrics|composed|arranged|written|produced|mixed|mastered|recorded|performed|translated)\s*(?:by\s*)?[:：]\s*\S',
  caseSensitive: false,
);

/// OP / SP 是唱片公司的版权标记，必须大写且紧跟冒号才算。
final RegExp _creditLatin = RegExp(r'^(?:OP|SP)\s*[:：]\s*\S');

/// 正文里有没有任意一条时间标签（用来决定 synced / plain 两栏）。
bool hasTimeTag(String lyric) => timeTag.hasMatch(lyric);

/// 剥掉开头连续的制作署名行（带不带时间轴都剥），最多扫 [creditScanLimit] 行。
///
/// 空行跳过但不终止扫描（网易云会在署名之间夹空行）；遇到第一条正文即停。
/// 一行都没剥时原样返回（避免无谓的字符串重建）。
String stripLeadingCredits(String lyric) {
  final lines = lyric.split(RegExp(r'\r?\n'));
  var index = 0;
  while (index < lines.length && index < creditScanLimit) {
    final text = lines[index].replaceAll(timeTag, '').trim();
    if (text.isEmpty) {
      index += 1;
      continue;
    }
    if (!_creditLine.hasMatch(text) &&
        !_creditLatinWords.hasMatch(text) &&
        !_creditLatin.hasMatch(text)) {
      break;
    }
    index += 1;
  }
  if (index == 0) {
    return lyric;
  }
  return lines.sublist(index).join('\n').trim();
}

/// 去掉开头那行「歌名 - 歌手」（酷狗 LRC 常见的第一行）。
///
/// 酷狗下载回来的 LRC 第一行经常是 `[00:00.00]晴天 - 周杰伦 (Jay Chou)`：
/// 它带时间轴，会被解析器当成第一句歌词，歌词页顶上就多出一行「歌名 - 歌手」。
/// 只认「歌名和歌手都出现在同一行、且中间有空白破折号」这一种形态，
/// 避免误删正文第一句（比如《十年》的首句「十年之前」）。
String stripLeadingTitleLine(
  String lyric, {
  required String trackName,
  required String artistName,
}) {
  if (trackName.isEmpty || artistName.isEmpty) {
    return lyric;
  }
  final lines = lyric.split(RegExp(r'\r?\n'));
  var first = -1;
  for (var index = 0; index < lines.length; index += 1) {
    if (lines[index].replaceAll(timeTag, '').trim().isNotEmpty) {
      first = index;
      break;
    }
  }
  if (first < 0) {
    return lyric;
  }
  final text = lines[first].replaceAll(timeTag, '').trim();
  if (!RegExp(r'\s[-–—]\s').hasMatch(text)) {
    return lyric;
  }
  final normalized = text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final name = trackName.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final artist = artistName.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (name.isEmpty ||
      artist.isEmpty ||
      !normalized.contains(name) ||
      !normalized.contains(artist)) {
    return lyric;
  }
  lines.removeAt(first);
  return lines.join('\n');
}
