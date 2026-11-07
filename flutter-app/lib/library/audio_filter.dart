// lib/library/audio_filter.dart
//
// 导入流程的前半段：把用户挑中的路径过一遍白名单，再把文件夹扫成候选列表。
// 两步都只做「哪些文件算音频、它们按什么顺序进列表」，不碰播放也不碰界面。
//
// 两条硬约束：
//   - 排序结果直接成为播放列表顺序，用户看得见，所以必须是确定的：
//     数字段按数值比，同值（如 `2` 与 `02`）用整串兜底，绝不依赖 List.sort
//     的稳定性——Dart 的排序本身不稳定，同分元素顺序随实现走。
//   - 扫描只读不写，目录不存在 / 读不了时交回空列表而不是抛出去：导入是
//     用户点的按钮，选择器给的路径可能已经失效，不该整页崩掉。
import 'dart:io';

import 'package:path/path.dart' as p;

import '../playback/play_error.dart';

/// 扫描命中的一个音频文件。
///
/// [name] 单独留着：导入后要拿它去猜「歌手 - 标题」，而 Android 的 SAF
/// 路径（content://）上取文件名比在桌面上麻烦，扫描时顺手取好最省事。
class ScannedAudio {
  ScannedAudio(this.path, this.name);

  /// 可播放的完整路径（桌面是绝对路径）。
  final String path;

  /// 展示用文件名，含扩展名。
  final String name;

  @override
  String toString() => 'ScannedAudio($path)';
}

bool _isAudioPath(String path) => isSupportedExtension(extensionOf(path));

/// 只留白名单内的路径，保持输入顺序。
List<String> filterSupported(List<String> paths) =>
    paths.where(_isAudioPath).toList();

/// 按白名单把路径分成两支，两支各自保持输入顺序。
///
/// 拒绝的那一支也要交回去：导入时要把跳过的文件名汇总提示给用户，
/// 静默丢弃会让人以为文件已经加进列表了。
({List<String> accepted, List<String> rejected}) partitionByExtension(
  List<String> paths,
) {
  final accepted = <String>[];
  final rejected = <String>[];
  for (final path in paths) {
    (_isAudioPath(path) ? accepted : rejected).add(path);
  }
  return (accepted: accepted, rejected: rejected);
}

/// 自然排序：数字段按数值比，文本段按码位比。
///
/// `track-2` 排在 `track-10` 前面；数字段取值相同时（`2` 与 `02`）用整串
/// 兜底比一次，让同一份输入永远得到同一个顺序。
List<String> naturalSort(List<String> paths) {
  final sorted = [...paths];
  sorted.sort((a, b) {
    final cmp = _compareNatural(a, b);
    return cmp != 0 ? cmp : _compareCodePoints(a, b);
  });
  return sorted;
}

int _compareNatural(String a, String b) {
  final left = _tokenize(a);
  final right = _tokenize(b);
  final common = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < common; i++) {
    final x = left[i];
    final y = right[i];
    final int cmp;
    if (x.numeric && y.numeric) {
      cmp = _compareDigits(x.text, y.text);
    } else if (x.numeric != y.numeric) {
      // 混排时数字段在前：`track-2` 排在 `track-a` 前面，直观且确定。
      return x.numeric ? -1 : 1;
    } else {
      cmp = _compareCodePoints(x.text, y.text);
    }
    if (cmp != 0) return cmp;
  }
  return left.length - right.length;
}

/// 一段连续的同质字符：要么全是 ASCII 数字，要么全是其它字符。
class _Run {
  const _Run(this.text, {required this.numeric});

  final String text;
  final bool numeric;
}

List<_Run> _tokenize(String text) {
  final runs = <_Run>[];
  final buffer = StringBuffer();
  bool? numeric;
  void flush() {
    if (buffer.isEmpty) return;
    runs.add(_Run(buffer.toString(), numeric: numeric ?? false));
    buffer.clear();
  }

  for (final rune in text.runes) {
    final isDigit = rune >= 0x30 && rune <= 0x39;
    if (numeric != null && numeric != isDigit) flush();
    numeric = isDigit;
    buffer.writeCharCode(rune);
  }
  flush();
  return runs;
}

/// 纯数字段按数值比：先剥前导零，长度长的更大，等长再逐位比。
/// 不走 int.parse——文件名里的数字段可以长过 64 位，解析失败会退化成字典序。
int _compareDigits(String a, String b) {
  final x = a.replaceFirst(_leadingZeros, '');
  final y = b.replaceFirst(_leadingZeros, '');
  if (x.length != y.length) return x.length - y.length;
  return x.compareTo(y);
}

final RegExp _leadingZeros = RegExp(r'^0+');

/// 逐码位比较。`String.compareTo` 比的是 UTF-16 码元，增补平面字符
/// （码位 > U+FFFF）会被排到 U+E000~U+FFFF 之间，与码位顺序不符。
int _compareCodePoints(String a, String b) {
  final x = a.runes.toList(growable: false);
  final y = b.runes.toList(growable: false);
  final common = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < common; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// 扫一个目录下的音频文件，默认递归。
///
/// - 隐藏项一律跳过：相对于 [root] 的路径里任何一段以 `.` 开头都算
///   （`.git`、`.cache` 这类目录，以及 `.DS_Store` 这类文件）；
/// - 只收白名单扩展名（[isSupportedExtension]）；
/// - 符号链接一律跳过，文件和目录都算：`followLinks: false` 下链接以
///   [Link] 出现，被下面的 `is File` 一并过滤，不会绕回来把同一批文件扫两遍。
///   这是已知限制而非疏漏——Android 的 SAF 路径（content://）根本不暴露符号
///   链接，桌面端把音乐库摆在符号链接目录下又是极少见用法，为它承担「同一首
///   歌出现两次 / 成环」的风险不划算；
/// - 目录不存在或读不了：返回已扫到的部分（通常是空），不抛异常；
/// - [maxFiles] 是硬上限，但截断发生在**自然排序之后**：先把整个目录枚举成
///   路径列表，排好序再取前 [maxFiles] 个。不在枚举途中提前 break，是因为
///   留哪几个不能由文件系统的枚举顺序决定——NTFS 大致按字典序、ext4 常常
///   是哈希序，提前停会让桌面和 Android 留下不同的歌，再被自然排序排成一份
///   看着合理的列表。代价是超大目录要全部枚举一遍（只存路径，不读文件内容）。
Future<List<ScannedAudio>> scanAudioDirectory(
  String root, {
  int maxFiles = 2000,
  bool recursive = true,
}) async {
  if (maxFiles <= 0) return const [];
  final found = <String>[];
  try {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (_hasHiddenSegment(entity.path, root)) continue;
      if (!_isAudioPath(entity.path)) continue;
      found.add(entity.path);
    }
  } on FileSystemException {
    // 权限不足 / 目录在枚举途中被删：把已经扫到的交出去，导入流程继续跑。
  }
  return [
    for (final path in naturalSort(found).take(maxFiles))
      ScannedAudio(path, p.basename(path)),
  ];
}

bool _hasHiddenSegment(String path, String root) =>
    p.split(p.relative(path, from: root)).any((seg) => seg.startsWith('.'));
