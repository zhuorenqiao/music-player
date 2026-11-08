// lib/lyrics/lrc_parser.dart
//
// 对译 React 版 src/lib/lyrics.js 的纯解析部分：parseLRC（61-119）、parseFraction
// （42-49）、dropHeaderLines（129-154）与顶部常量（11-32）。findActiveCue 改写自
// LyricsView.#findIndex（491-506）+ setTime 的容差（462，ACTIVE_TOLERANCE=0.12）；
// plainLyricLines 取 #renderPlain 的分行/trim（360-379），但按 M2a 契约去首尾空行。
// 纯 Dart、无 IO、无 Flutter 依赖，只做解析与当前行判定。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/lyrics/lrc_parser_test.dart）：
// * 行分隔符是 /\r?\n/，不是 Dart 的 LineSplitter —— 后者把 lone \r 也当分隔符，JS 不当；
// * [offset:] 空值等于 0（JS Number('')===0，而 Dart double.tryParse('') 返回 null），
//   且解析失败（null / 非有限）保持上一个 offset，不重置为 0（对齐 Number.isFinite 守卫）；
// * 排序必须稳定：JS Array.sort 自 ES2019 稳定，Dart List.sort 不稳定，故记原始下标、
//   time 相等时比下标，保住同一时刻多行的输入顺序（直接影响高亮与译文对齐）；
// * seconds<60 不成立的标签不进时间轴，但仍从正文剥掉；一行全非法则整行跳过；
// * dropHeaderLines 的 text.length 是 UTF-16 码元数，与 JS String.length 一致，不用 runes.length；
// * findActiveCue 的判定式必须是 cue.time - 0.12 <= now，不能等价改写成 now <= cue.time + 0.12，
//   浮点误差会让边界判定不同。
import 'dart:math' show max;

/// 一条歌词行。纯文本（无时间轴）行的 [time] 为 `double.nan`。
class LyricLine {
  const LyricLine({required this.time, required this.text});

  /// 该行时间（秒）；纯文本行为 `double.nan`。
  final double time;

  /// 剥掉时间标签与逐字标签后的正文。
  final String text;
}

/// [parseLrc] 的结果：排序后的歌词行 + 小写 key 的元信息表。
class ParsedLrc {
  const ParsedLrc({required this.lines, required this.meta});

  final List<LyricLine> lines;

  /// `[ti:] [ar:] [al:] [by:] [offset:] [length:]` 等元信息，key 小写、值已 trim。
  final Map<String, String> meta;
}

/// 一个时间标签：`[mm:ss]` / `[mm:ss.x]` / `[mm:ss.xx]` / `[mm:ss.xxx]`（lyrics.js:12）。
const String _timeTagSource = r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]';

/// 元信息标签（lyrics.js:15），大小写不敏感。
final RegExp _metaTag = RegExp(
  r'^\[(ti|ar|al|by|offset|length)\s*:\s*(.*?)\]$',
  caseSensitive: false,
);

/// 逐字（增强型）LRC 的行内时间标签 `<00:12.345>`（lyrics.js:23），只剥不解析。
final RegExp _wordTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

/// 制作人员署名行（lyrics.js:26），大小写不敏感。
final RegExp _creditLine = RegExp(
  r'^(?:作词|作曲|编曲|词|曲|制作人|出品|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|OP|SP)\s*[:：]',
  caseSensitive: false,
);

/// 只清理开头这么多行，避免误删正文（lyrics.js:29）。
const int _creditScanLimit = 4;

/// 当前行判定容差（秒），避免卡在行边界来回跳（lyrics.js:32）。
const double _activeTolerance = 0.12;

/// 把时间标签的小数部分换算成秒（lyrics.js:42-49）。
///
/// 1 位补 `00`、2 位补 `0`、3 位取前 3，再按毫秒除以 1000。捕获组只含 `\d{1,3}`，
/// int.parse 必然有限，故省去原版的 `Number.isFinite` 兜底。
double _parseFraction(String? raw) {
  if (raw == null || raw.isEmpty) return 0;
  final digits = raw.length == 1
      ? '${raw}00'
      : (raw.length == 2 ? '${raw}0' : raw.substring(0, 3));
  return int.parse(digits) / 1000;
}

/// 解析 LRC 文本（lyrics.js:61-119）。
///
/// 支持一行多时间标签、`[offset:]` 整体偏移（毫秒，正值让歌词提前）、空行与纯元信息行
/// 跳过、时间乱序自动排序。[title] / [artist] 用于剔除开头的标题行，缺省时回退 meta.ti / meta.ar。
ParsedLrc parseLrc(String text, {String title = '', String artist = ''}) {
  final meta = <String, String>{};
  if (text.trim().isEmpty) {
    return ParsedLrc(lines: const [], meta: meta);
  }

  // 每条记原始下标 order，供稳定排序在 time 相等时回落比较。
  final collected = <({double time, String text, int order})>[];
  var offset = 0.0;

  // 用 /\r?\n/ 切行：lone \r 不是分隔符（LineSplitter 会误切，见头部说明）。
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final metaMatch = _metaTag.firstMatch(line);
    if (metaMatch != null) {
      final key = metaMatch.group(1)!.toLowerCase();
      final value = metaMatch.group(2)!.trim();
      meta[key] = value;
      if (key == 'offset') {
        // JS Number('')===0；Dart double.tryParse('') 返回 null，必须显式补 0。
        final parsed = value.isEmpty ? 0.0 : double.tryParse(value);
        // 解析失败（null / 非有限）保持上一个 offset，不重置（对齐 Number.isFinite 守卫）。
        if (parsed != null && parsed.isFinite) offset = parsed;
      }
      continue;
    }

    // 每行新建一次，allMatches 与 replaceAll 复用同一对象（对齐原版 new RegExp(..., 'g')）。
    final tagPattern = RegExp(_timeTagSource);
    final times = <double>[];
    for (final m in tagPattern.allMatches(line)) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      // seconds<60 才入时间轴；非法标签仍会被下面的 replaceAll 从正文剥掉。
      if (seconds < 60) {
        times.add(minutes * 60 + seconds + _parseFraction(m.group(3)));
      }
    }
    if (times.isEmpty) continue;

    final content = line
        .replaceAll(tagPattern, '')
        .replaceAll(_wordTag, '')
        .trim();
    for (final time in times) {
      collected.add((time: time, text: content, order: collected.length));
    }
  }

  final shift = offset / 1000;
  final sorted = [
    for (final e in collected)
      (time: max(0.0, e.time - shift), text: e.text, order: e.order),
  ];
  // 稳定排序：time 相等时比原始下标，保住同一时刻多行的输入顺序。
  sorted.sort((a, b) {
    final byTime = a.time.compareTo(b.time);
    return byTime != 0 ? byTime : a.order.compareTo(b.order);
  });
  final lines = [for (final e in sorted) LyricLine(time: e.time, text: e.text)];

  final resolvedTitle = title.isNotEmpty ? title : (meta['ti'] ?? '');
  final resolvedArtist = artist.isNotEmpty ? artist : (meta['ar'] ?? '');
  return ParsedLrc(
    lines: _dropHeaderLines(lines, resolvedTitle, resolvedArtist),
    meta: meta,
  );
}

/// 去掉开头的制作署名行与「歌名 - 歌手」标题行（lyrics.js:129-154）。
///
/// 只在开头几行里判断，且清理后至少保留 3 行，避免把正文误删。
List<LyricLine> _dropHeaderLines(
  List<LyricLine> lines,
  String title,
  String artist,
) {
  if (lines.length <= 3) return lines;

  String norm(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final normTitle = norm(title);
  final normArtist = norm(artist);

  final kept = <LyricLine>[];
  for (final line in lines) {
    final text = line.text.trim();
    // 窗口按「已保留」行数算，不是已扫描行数（对齐 kept.length < CREDIT_SCAN_LIMIT）。
    final scanned = kept.length < _creditScanLimit;
    final isCredit = _creditLine.hasMatch(text);
    final isTitleLine =
        normTitle.isNotEmpty &&
        normArtist.isNotEmpty &&
        // text.length 是 UTF-16 码元数，与 JS String.length 一致，不用 runes.length。
        text.length <= 60 &&
        norm(text).contains(normTitle) &&
        norm(text).contains(normArtist);
    if (scanned && (isCredit || isTitleLine)) continue;
    kept.add(line);
  }

  return kept.length >= 3 ? kept : lines;
}

/// 纯文本歌词分行：CRLF 归一、去首尾空行、逐行 trim、保留中间空行。
///
/// 取 #renderPlain 的分行/trim，但按 M2a 契约把首尾连续空行整段去掉（原版只去首尾各一行）。
List<String> plainLyricLines(String plain) {
  if (plain.isEmpty) return const [];
  final parts = plain.replaceAll('\r\n', '\n').split('\n');
  var start = 0;
  var end = parts.length;
  while (start < end && parts[start].trim().isEmpty) {
    start++;
  }
  while (end > start && parts[end - 1].trim().isEmpty) {
    end--;
  }
  return [for (var i = start; i < end; i++) parts[i].trim()];
}

/// 二分查找当前应高亮的行下标（改写自 #findIndex + setTime 容差）。
///
/// 取最后一个满足 `cue.time - 0.12 <= time` 的行；重复时间戳取最后一个（ceil 中点）。
/// 空列表或早于首行容差返回 -1。判定式不能等价改写成 `time <= cue.time + 0.12`（浮点误差不同）。
int findActiveCue(List<LyricLine> cues, double time) {
  if (cues.isEmpty) return -1;
  var low = 0;
  var high = cues.length - 1;
  while (low < high) {
    final mid = ((low + high) / 2).ceil();
    if (cues[mid].time - _activeTolerance <= time) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return cues[low].time - _activeTolerance <= time ? low : -1;
}
