// lib/playback/play_error.dart
//
// 播放错误归一：把「预校验不通过」与「运行期失败」归到原版的四类文案
// （src/lib/player.js:9-20 AUDIO_ERROR_MESSAGES / UNKNOWN_ERROR_MESSAGE）。
// 纯逻辑，不依赖 Flutter material。

/// 原版 MediaError.code 1~4 的四个分类，外加无法归类时的 [unknown]。
enum PlayErrorKind { aborted, network, decode, unsupported, unknown }

/// 各分类的中文提示，逐字对齐原版（player.js:9-20）。
const Map<PlayErrorKind, String> kPlayErrorMessages = {
  PlayErrorKind.aborted: '音频加载被中断，请重试',
  PlayErrorKind.network: '网络错误，无法获取音频文件',
  PlayErrorKind.decode: '音频解码失败，文件可能已损坏',
  PlayErrorKind.unsupported: '格式不支持或音频文件不存在',
  PlayErrorKind.unknown: '音频播放失败，请稍后重试',
};

/// 原版是「浏览器阻止了自动播放」；Flutter 侧对应音频焦点被抢（spec §4）。
const String kAutoplayBlockedMessage = '无法开始播放，请点击播放按钮开始';

/// 可播放的扩展名白名单，11 项与原版一致。
const Set<String> kAudioExtensions = {
  'mp3',
  'wav',
  'ogg',
  'oga',
  'opus',
  'm4a',
  'aac',
  'flac',
  'webm',
  'weba',
  'mp4',
};

/// 判断扩展名是否在白名单内：大小写不敏感，允许带一个前导点、允许首尾空白。
bool isSupportedExtension(String name) {
  var value = name.trim().toLowerCase();
  if (value.startsWith('.')) value = value.substring(1);
  return value.isNotEmpty && kAudioExtensions.contains(value);
}

/// 取路径的最后一段扩展名（不含点、小写）；没有扩展名时返回空串。
String extensionOf(String path) {
  final at = path.lastIndexOf('.');
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  if (at < 0 || at <= slash || at == path.length - 1) return '';
  return path.substring(at + 1).toLowerCase();
}

/// 明确指向「文件不存在 / 路径打不开」的文本，归到「格式不支持或不存在」。
const List<String> _unsupportedMarkers = [
  'no such file',
  'does not exist',
  "doesn't exist",
  'not found',
  'cannot open',
];

/// 媒体本身坏了 / 解不开，归到解码失败。
/// mpv 的 `Failed to open file` 也是这一档（文件在、但打不开解不出）。
const List<String> _decodeMarkers = [
  'invalid data',
  'decode',
  'corrupt',
  'unsupported format',
  'unsupported codec',
  'failed to open',
  'malformed',
  'truncated',
];

/// 主动停止 / 切歌导致的中断。
const List<String> _abortedMarkers = ['interrupt', 'abort', 'cancel'];

/// 网络层原因。
const List<String> _networkMarkers = [
  'network',
  'connection',
  'connect',
  'timed out',
  'timeout',
  'unreachable',
  'dns',
];

bool _hasAny(String message, List<String> markers) =>
    markers.any(message.contains);

/// 把一次播放失败归到四类之一。
///
/// 预校验不通过（[notFound] 或扩展名不在白名单）一律判 unsupported；
/// 运行期按 mpv 的文本粗分：不支持 > 解码 > 中断 > 网络，兜底 unknown。
/// 输入全为 null / 空串时不会抛异常，返回 [PlayErrorKind.unknown]。
PlayErrorKind classifyFailure({
  String? fileName,
  String? rawMessage,
  bool notFound = false,
}) {
  if (notFound) return PlayErrorKind.unsupported;
  final ext = fileName == null ? '' : extensionOf(fileName);
  if (ext.isNotEmpty && !isSupportedExtension(ext)) {
    return PlayErrorKind.unsupported;
  }
  final message = (rawMessage ?? '').trim().toLowerCase();
  if (message.isEmpty) return PlayErrorKind.unknown;
  if (_hasAny(message, _unsupportedMarkers)) return PlayErrorKind.unsupported;
  if (_hasAny(message, _decodeMarkers)) return PlayErrorKind.decode;
  if (_hasAny(message, _abortedMarkers)) return PlayErrorKind.aborted;
  if (_hasAny(message, _networkMarkers)) return PlayErrorKind.network;
  return PlayErrorKind.unknown;
}

/// 取分类对应的中文提示。
String errorMessageFor(PlayErrorKind kind) => kPlayErrorMessages[kind]!;
