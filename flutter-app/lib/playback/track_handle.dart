// lib/playback/track_handle.dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// 已是完整 URI（带 scheme 与 `//` 权限段）的输入不再当路径二次编码。
final RegExp _schemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

/// 把文件路径拼成 file URI。
///
/// 不直接用 `p.toUri`：Windows 上它对相对路径产出没有 scheme 的 URI
/// （`test/a.flac`），对 `/a.flac` 这类 POSIX 绝对路径会补当前盘符
/// （`file:///C:/a.flac`）——同一份存档在两个平台读出的 uri 就不一致了。
/// 这里固定三条规则：已是 URI 的原样返回；`/` 开头的按 posix 风格拼；
/// 其余（含 Windows 盘符与 UNC）先转绝对路径再交给 `p.toUri`。
String _toFileUri(String input) {
  if (_schemePattern.hasMatch(input)) return input;
  final absolute = p.isAbsolute(input) ? input : p.absolute(input);
  if (input.startsWith('/')) {
    return p.posix.toUri(absolute.replaceAll(r'\', '/')).toString();
  }
  return p.toUri(absolute).toString();
}

/// 音频来源。桌面是绝对路径，Android 是 SAF 持久 URI。
sealed class TrackHandle {
  const TrackHandle();

  String get uri;
  String get displayName;

  /// 能直接交给本地读写的形态：文件句柄给真实路径，SAF 给原 URI。
  ///
  /// 播放一律走 [uri]，这个只给「用 `dart:io` 读字节 / 探时长」的调用方
  /// 当标识用 —— 它可能是一个 `content://` 串，读不出来就是读不出来。
  String get pathish => uri;

  Future<bool> exists();
  Future<int?> sizeBytes();
  Map<String, Object?> toJson();

  /// 这条来源**值不值得**交给时长探测（终审 R7）。
  ///
  /// 探测器（`MediaKitDurationOpener`）只会把来源包成 `Media(FilePathHandle(source).uri)`，
  /// 而 M1 没有 ContentResolver 通道 —— `content://` 这种 SAF 句柄在它手里
  /// 根本开不了，排队 + 白等满 3000ms 预算，换来一个和「文件没有时长」一样的
  /// NaN。既然注定没有信息，就别让它进队列：句柄自己说清楚。
  bool get canProbeDuration;

  /// 反序列化必须「脏字段返回 null，绝不抛」：坏存档经 `Track.fromJson` →
  /// `normalizeTrack` 一路读到列表，抛出去就是把整个列表加载页搞崩。
  /// 因此这里一律用 `is` 判定，不做 `as String?` 之类的强制转换。
  static TrackHandle? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final kind = json['kind'];
    if (kind == 'file') {
      final path = json['path'];
      if (path is! String || path.isEmpty) return null;
      return FilePathHandle(path);
    }
    if (kind == 'saf') {
      final uri = json['uri'];
      if (uri is! String || uri.isEmpty) return null;
      final name = json['name'];
      return SafUriHandle(uri, name is String ? name : '');
    }
    return null;
  }
}

class FilePathHandle extends TrackHandle {
  const FilePathHandle(this.path);
  final String path;

  @override
  String get uri => _toFileUri(path);

  @override
  String get pathish => path;

  @override
  String get displayName => p.basename(path);

  @override
  Future<bool> exists() async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int?> sizeBytes() async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// 本地文件路径可以；`content://` 之类被当路径塞进来的（Android 选择器
  /// 给的就是这种，见 `ImportService._buildTrack` 的注释）不行。
  @override
  bool get canProbeDuration =>
      !_schemePattern.hasMatch(path) || path.startsWith('file:');

  @override
  Map<String, Object?> toJson() => {'kind': 'file', 'path': path};
}

class SafUriHandle extends TrackHandle {
  const SafUriHandle(this.rawUri, this.displayName);
  final String rawUri;

  @override
  String get uri => rawUri;

  @override
  final String displayName;

  /// SAF 的存在性无法用 dart:io 判定，交由平台通道在 T22 之后补；
  /// M1 里返回 true，失效由播放错误路径（T11 的 code 4）捕获。
  @override
  Future<bool> exists() async => true;

  @override
  Future<int?> sizeBytes() async => null;

  /// M1 没有读 SAF 内容的能力（要平台通道 / ContentResolver），探测器
  /// 拿到这种句柄只会白等满预算（终审 R7）。
  @override
  bool get canProbeDuration => false;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'saf',
    'uri': rawUri,
    'name': displayName,
  };
}
