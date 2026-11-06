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
  Future<bool> exists();
  Future<int?> sizeBytes();
  Map<String, Object?> toJson();

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
      return SafUriHandle(uri, (json['name'] as String?) ?? '');
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

  @override
  Map<String, Object?> toJson() => {
    'kind': 'saf',
    'uri': rawUri,
    'name': displayName,
  };
}
