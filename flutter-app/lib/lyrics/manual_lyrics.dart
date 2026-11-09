// lib/lyrics/manual_lyrics.dart
//
// 对译 React 版 src/state/lyrics-file.ts 全文（MAX_LYRICS_BYTES 15、normalizeName
// 17、stripExtension 19-23、isRealArtist 26-29、matchLyricsTrack 42-76、
// readLyricsFile 82-99）与 src/state/library.tsx:69-108（applyLyricsFiles 的那一轮
// 「读 → 配 → 写回活对象 → 提示」循环，以及 105-107 的汇总句）。
//
// 手动歌词优先级最高：挂上后 `lyricsSource = 'manual'`，T13 的自动匹配会显式跳过
// 它（lyrics.tsx 同一条规则）；反过来自动匹配的结果也不许伪装成手动歌词。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/manual_lyrics_test.dart）：
// * normalizeName 是「**压缩**空白」不是「删空白」（`replace(/\s+/g, ' ')`）。这与
//   lrc_parser 的 _dropHeaderLines（删空白）、translate_align 的 _normalizeLine
//   （删标点）是**三套不同的字符集**，别互相复用 —— 复用会把
//   `the   beatles - yesterday` 与 `the beatles - yesterday` 判成不同名字；
// * stripExtension 的条件是 `dot > 0`，`.lrc` 这种首字符就是点的名字整串当 base
//   （于是 matchLyricsTrack('.lrc') 走「base 非空但谁也对不上」→ null 那条路）；
// * 打分是 **Math.max 叠加**而不是覆盖：三条规则可能先后命中同一首曲目，先写的
//   40 分与后写的 30 分取大；`score > bestScore` 是**严格**大于，所以同分取列表里
//   靠前的那首；`bestScore > 0` 才返回曲目，一分都没有就给 null ——
//   「宁可跳过，也别把 N 份歌词轮流盖到同一首正在播的歌上」（原版注释）；
// * hasArtist 排除「本地文件」与「未知歌手」两个占位名：本地导入没有标签时
//   artist 正是这个占位值，若参与 50 分判定，`<artist> - <title>` 就成了恒真的
//   兜底匹配，会把真正该赢的 40 分候选挤掉；
// * 组合名用 normalizeName('${track.artist} - ${track.title}')，**只认半角 `-`**；
//   而 splitArtistTitle 认的是 [-–—]（三处规则各不相同，别统一）；
// * 512KB 是**字节**闸（`File.length()`），不是字符数 —— GBK 文件一个汉字两字节，
//   拿 text.length 比会把上限放宽一倍；
// * 解码走 `utf8.decode(allowMalformed: true)`，等价于 `Blob.text()`：GBK 歌词解出
//   乱码之后由「没有可识别的时间轴」这一步拦下，读取路径绝不抛；
// * 三条失败话术 + 两条成功话术逐字照抄（含全角「」与 `N 行` 的空格）；
// * 配对成功写的是**列表里的活对象**（`Playlist.tracks` 里那个），不落库：
//   React 在循环里 `refresh(); persist();` 每条落一次，Flutter 侧改由调用方
//   （`LibraryState.applyLyricsFiles`）在整批结束后落一次，见 [ManualLyrics.apply]。
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import '../core/name_split.dart';
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/transport_controller.dart' show ToastSink;
import 'lrc_parser.dart';

/// 单个歌词文件的体积上限（512KB 够放任何正规歌词，超了多半是选错文件）。
const int kMaxLyricsBytes = 512 * 1024;

/// 手动歌词链路的提示停留时长（毫秒）。
///
/// 原版这条链路的四处提示（读取失败 / 配对失败 / 汇总 / 成功）都传 6000 ——
/// 比默认的 3200 长一倍，因为文件名配对失败时用户需要读完整句才知道是哪个文件。
const int _lyricsToastMs = 6000;

/// 逐条点名「没找到同名曲目」的上限，其余合成一句汇总（library.tsx:82-88 / 105-107）。
const int _maxNamedUnmatched = 2;

/// 空白压缩用的正则。与 [_normalizeName] 的注释同一条：这里只是**压缩**。
final RegExp _whitespace = RegExp(r'\s+');

/// 一位歌词文件读下来的结论：文本 + 解析出的行数，或一句拒绝话术。
///
/// 与 [LyricsFileRead] 对应的原版返回值是 `{text, lineCount} | {error}`
/// （lyrics-file.ts:82）—— Dart 侧收成一个类，用 [isError] 判分支，省掉
/// 调用处每次 `is` 判断两次。
class LyricsFileRead {
  const LyricsFileRead({this.text = '', this.lineCount = 0, this.error = ''});

  /// 原始文件文本（UTF-8 解码后的样子，不去 BOM、不归一换行：原版写回曲目的是
  /// `File.text()` 的原文，这里必须一模一样，否则同一份歌词“手动导入”与
  /// “重启读回”的字节不同）。
  final String text;

  /// [parseLrc] 解析出的行数（用于「已为「X」加载 N 行歌词」）。
  final int lineCount;

  /// 拒绝原因（逐字对齐原版三条话术）；空串表示这次读成功了。
  final String error;

  bool get isError => error.isNotEmpty;
}

/// 取名字（压缩空白 + 小写）。
///
/// 原版 `String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ')`。
/// Dart 的 `String.trim()` 与 JS `.trim()` 对 U+FEFF 有差异（T3 记过同一类坑），
/// 但这里的两侧（文件名、曲目字段）都来自同一个 App，不跨来源比较，不额外处理。
String _normalizeName(String value) =>
    value.trim().toLowerCase().replaceAll(_whitespace, ' ');

/// 去掉最后一段扩展名；`dot > 0` 才切，`.lrc` / `.hidden` 这类整串保留。
///
/// 与 `import_service.dart` 的私有同名函数同规则，但那边是私有实现、此处不引
/// 依赖（lyrics 层不该 import library 层），故各留一份。
String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 本地文件的占位歌手名没有匹配价值（lyrics-file.ts:26-29）。
bool _isRealArtist(String artist) {
  final value = _normalizeName(artist);
  return value.isNotEmpty && value != '本地文件' && value != '未知歌手';
}

/// 路径 → 展示用文件名（含扩展名）。
///
/// 手动歌词只走「用户挑文件」这一条路，选择器给的都是真实路径（桌面绝对路径 /
/// Android 缓存副本路径），所以这里只切分隔符，不做 `displayNameForSource` 那套
/// SAF 百分号解码 —— 歌词文件不经 SAF 批量导入。
String _displayNameOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// 为一个 `.lrc` 文件名找目标曲目，按可信度取最高分（lyrics-file.ts:42-76）。
///
/// 四档分数一字不改：50 = 「歌手 - 歌名」组合名完全一致；45 = 拆出的歌名与歌手
/// 都对得上；40 = 曲名完全一致；30 = 只有拆出的歌名一致。
/// 一分都没有就返回 null —— **不兜底挂到当前曲目**（原版 66-67 的注释：
/// 名字对不上的歌词很可能属于另一首歌，覆盖上去比不挂更糟）。
Track? matchLyricsTrack(String fileName, List<Track> tracks) {
  final raw = _stripExtension(fileName);
  final base = _normalizeName(raw);
  if (base.isEmpty) return null;
  final split = splitArtistTitleOrNull(raw);
  final titleOnly = split == null ? '' : _normalizeName(split.title);
  final artistOnly = split == null ? '' : _normalizeName(split.artist);

  Track? best;
  var bestScore = 0;
  for (final track in tracks) {
    final title = _normalizeName(track.title);
    final artist = _normalizeName(track.artist);
    final hasArtist = _isRealArtist(track.artist);
    // 三条规则依次取 max —— 不要改成 `if/else if` 或带提前 continue 的写法：
    // 同一首可能同时命中 40 与 30，取大才与原版一致。
    var score = 0;
    if (title == base) {
      score = 40;
    }
    if (hasArtist &&
        _normalizeName('${track.artist} - ${track.title}') == base) {
      score = max(score, 50);
    }
    if (titleOnly.isNotEmpty && title == titleOnly) {
      score = max(
        score,
        artistOnly.isNotEmpty && hasArtist && artist == artistOnly ? 45 : 30,
      );
    }
    // 严格大于：同分保留先出现的那首（列表顺序即用户看到的顺序）。
    if (score > bestScore) {
      best = track;
      bestScore = score;
    }
  }
  return bestScore > 0 ? best : null;
}

/// 读一个歌词文件并过三道闸（lyrics-file.ts:82-99）。
///
/// 顺序与原版一致：先比**字节**大小，再读，最后解析。任何失败都只返回一句
/// [LyricsFileRead.error]，绝不抛 —— 一键导入几十个文件时，一个坏文件不许
/// 带走整批。
///
/// [displayName] 由调用方给（文件名），用于话术；不直接由 [path] 推，是因为
/// 反序列化 / 上层调用可能拿到的是别种来源串。
Future<LyricsFileRead> readLyricsFile(
  String path, {
  required String displayName,
}) async {
  final file = File(path);
  try {
    final length = await file.length();
    // 512KB 是字节闸：先拒绝就不必把几百 MB 的文件读进内存。
    if (length > kMaxLyricsBytes) {
      return LyricsFileRead(error: '歌词文件过大，已跳过：$displayName');
    }
    final bytes = await file.readAsBytes();
    // Blob.text() 等价：UTF-8 解码、坏字节替换成 U+FFFD，不抛。
    final text = utf8.decode(bytes, allowMalformed: true);
    final parsed = parseLrc(text);
    if (parsed.lines.isEmpty) {
      return LyricsFileRead(error: '「$displayName」里没有可识别的时间轴歌词，已跳过');
    }
    return LyricsFileRead(text: text, lineCount: parsed.lines.length);
  } catch (_) {
    // 文件不在 / 权限不足 / 路径是个目录 / 磁盘错误：统一成一句「读取失败」。
    return LyricsFileRead(error: '读取歌词失败：$displayName');
  }
}

/// 手动 `.lrc` 的批量应用：逐条读、逐条配对、成功就改活对象并提示。
///
/// **不落库**：返回 `(matched, unmatched)`，由调用方（`LibraryState`）在整批结束后
/// 落一次。这是与原版唯一的**有意差异** —— React 在循环里每成功一条就
/// `refresh(); persist();`（library.tsx:94-95），Flutter 侧收成批量一次，理由：
/// 同一批导入的结果本来就一起可见，一批几十条却写几十遍整库档案纯属白写盘；
/// 用户可见行为完全一致（提示照样逐条发）。
class ManualLyrics {
  ManualLyrics({required this.playlist, required this.toasts});

  final Playlist playlist;
  final ToastSink toasts;

  /// 应用一批歌词文件，返回 (命中, 未命中)。
  ///
  /// 提示级别与时长对齐原版三处：
  ///   - 读取 / 解析失败 → [ToastSink.error]、6000ms（原版 'error' 色）；
  ///   - 配对失败、汇总、成功 → [ToastSink.show]、6000ms（文案不含「失败 /
  ///     不支持 / 无法」，自然落在 info 色，与 React 传 'info' 等价）。
  Future<({int matched, int unmatched})> apply(List<String> paths) async {
    var matched = 0;
    var unmatched = 0;
    // 当前曲目只影响成功话术的措辞。配对与写回都不移动光标，所以整个循环里
    // current 不变，读一次就够（原版在循环内读，值相同）。
    final currentId = playlist.current?.id;

    for (final path in paths) {
      final displayName = _displayNameOf(path);
      final read = await readLyricsFile(path, displayName: displayName);
      if (read.isError) {
        toasts.error(read.error, durationMs: _lyricsToastMs);
        continue;
      }
      final target = matchLyricsTrack(displayName, playlist.tracks);
      if (target == null) {
        unmatched += 1;
        // 只点名前两个，其余交给循环外的汇总句（原版 `unmatched <= 2`）。
        if (unmatched <= _maxNamedUnmatched) {
          toasts.show(
            '未找到与「$displayName」同名的曲目，已拒绝替换',
            durationMs: _lyricsToastMs,
          );
        }
        continue;
      }

      // 改的是列表里的活对象：改副本等于没改，界面与落库都看不到。
      target.lyrics = read.text;
      target.lyricsPlain = '';
      target.lyricsSource = 'manual';
      matched += 1;

      toasts.show(
        target.id == currentId
            ? '已为「${target.title}」加载 ${read.lineCount} 行歌词'
            : '已为「${target.title}」配好 ${read.lineCount} 行歌词，切到这首即可查看',
        durationMs: _lyricsToastMs,
      );
    }

    // 汇总句里的 N 是**剩余**个数（总数减去已经点名的那两个），不是总数。
    if (unmatched > _maxNamedUnmatched) {
      toasts.show(
        '另有 ${unmatched - _maxNamedUnmatched} 个歌词文件没有找到对应曲目',
        durationMs: _lyricsToastMs,
      );
    }
    return (matched: matched, unmatched: unmatched);
  }
}
