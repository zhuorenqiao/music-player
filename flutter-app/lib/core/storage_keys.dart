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
  static const String cardTransparency = 'cardTransparency';
  static const String cardFrost = 'cardFrost';
  static const String themeMode = 'themeMode';
  static const String themeColor = 'themeColor';
  /// 老版本的单值主题键，只用于迁移读取（spec §6.3）
  static const String theme = 'theme';
  static const String recent = 'recent';
  static const String bilingual = 'bilingual';
}
