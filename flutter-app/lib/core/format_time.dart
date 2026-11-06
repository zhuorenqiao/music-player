// lib/core/format_time.dart
const String kTimeUnknown = '--:--';

String _two(int v) => v.toString().padLeft(2, '0');

String _minutesSeconds(int total) {
  final m = total ~/ 60;
  final s = total % 60;
  return '${_two(m)}:${_two(s)}';
}

/// 未知（null / NaN / ±Infinity）判空；负数按 0 处理。
int _floorSeconds(double seconds) => seconds < 0 ? 0 : seconds.floor();

/// 播放进度：`mm:ss`，未知时长返回 `kTimeUnknown`。
String formatTime(double? seconds) {
  if (seconds == null || !seconds.isFinite) return kTimeUnknown;
  return _minutesSeconds(_floorSeconds(seconds));
}

/// 列表总时长：超过一小时才带小时位。
String formatTotal(double? seconds) {
  if (seconds == null || !seconds.isFinite) return kTimeUnknown;
  final total = _floorSeconds(seconds);
  if (total < 3600) return _minutesSeconds(total);
  final h = total ~/ 3600;
  return '$h:${_minutesSeconds(total % 3600)}';
}
