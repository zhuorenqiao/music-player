// lib/playback/play_mode.dart
/// 三种播放模式（对译 src/lib/playlist.js:9-13 PLAY_MODES）。
enum PlayMode { list, one, shuffle }

/// 模式循环切换顺序：列表循环 → 单曲循环 → 随机播放 → 列表循环（playlist.js:16）。
const List<PlayMode> kModeOrder = [PlayMode.list, PlayMode.one, PlayMode.shuffle];

String playModeId(PlayMode mode) => mode.name;

/// 模式的中文文案（playlist.js:19-23 MODE_LABELS）。
String playModeLabel(PlayMode mode) => switch (mode) {
      PlayMode.list => '列表循环',
      PlayMode.one => '单曲循环',
      PlayMode.shuffle => '随机播放',
    };

/// 存档里的模式 id 反解析；非法值一律退回列表循环（playlist.js:121）。
PlayMode playModeFromId(Object? id) => kModeOrder.firstWhere(
      (m) => m.name == id,
      orElse: () => PlayMode.list,
    );
