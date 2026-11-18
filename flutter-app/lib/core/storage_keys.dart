// lib/core/storage_keys.dart
/// 与 React 版 src/state/constants.ts 的 STORAGE_KEYS 一一对应。
abstract final class StorageKeys {
  static const String playlist = 'playlist';
  static const String currentId = 'currentId';
  static const String mode = 'mode';
  static const String volume = 'volume';
  static const String muted = 'muted';
  static const String order = 'order';
  static const String waveStyle = 'waveStyle';
  static const String waveColored = 'waveColored';
  static const String lyricColor = 'lyricColor';
  /// 歌词字号缩放（百分比，100 = 默认；「T」面板里的字号滑杆）
  static const String lyricScale = 'lyricScale';
  /// 歌词字体 id（「T」面板里的字体那一排；default = 跟随界面字体）
  static const String lyricFont = 'lyricFont';
  static const String cardTransparency = 'cardTransparency';
  static const String cardFrost = 'cardFrost';
  /// 睡眠定时器的截止时刻（时间戳 ms）；缺失 = 未启用
  static const String sleepTimer = 'sleepTimer';
  static const String themeMode = 'themeMode';
  static const String themeColor = 'themeColor';
  /// 老版本的单值主题键，只用于迁移读取（spec §6.3）
  static const String theme = 'theme';
  static const String recent = 'recent';
  static const String bilingual = 'bilingual';
}
