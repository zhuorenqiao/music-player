// lib/theme/theme_state.dart
//
// 外观状态机（M3 T4）：七个维度一个 provider 管完，对译 React 的
// theme.tsx（mode/color）+ glass.tsx（transparency/frost）+ wave-style.tsx
// （style/colored/lyricColor）三个 provider —— Flutter 侧合并成一个
// ChangeNotifier，消费方（换肤抽屉 / 玻璃滑块 / 波形 / 歌词行）各取所需。
//
// 持久化键全部已留位（storage_keys.dart）：themeMode / themeColor /
// cardTransparency / cardFrost / waveStyle / waveColored / lyricColor。
//
// 三条移植要点（每条都有用例钉）：
//   * legacy 迁移（theme.tsx:72-95 逐字）：老 `theme` 键为 system/light/dark
//     → 折进 mode；为 mint/pink/blue → mode 记 dark 且折进 color。
//   * frost 老用户迁移（glass.tsx:37-44）：无 cardFrost 键时 frost =
//     cardTransparency（拆两滑杆前磨砂=透明度）。
//   * glass/frost 值域 0~100，clamp 用 round 语义（Math.round → .round()）。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';

/// 明暗模式（theme.tsx:18）。
enum ThemeModeSetting { system, light, dark }

/// 主题色（theme.tsx:19）。
enum ThemeColorSetting { mint, pink, blue }

/// 17 波形样式的 id 合法性由 wave_styles.dart 的注册表把关；本层只存字符串。
class ThemeState extends ChangeNotifier {
  ThemeState._(this._prefs, {bool Function()? platformDark})
    : _platformDark = platformDark ?? (() => false);

  /// 装配入口：先把要用到的键都读完再构造（main() 在 runApp 前 await，
  /// 等价 React useLayoutEffect 的「首帧前挂属性」）。
  static Future<ThemeState> load(
    AppPrefs prefs, {
    bool Function()? platformDark,
  }) async {
    final state = ThemeState._(prefs, platformDark: platformDark);
    await state._reload();
    return state;
  }

  /// 兜底构造（默认值，不读 prefs）：给「直接 new AppBootstrap 的测试路径」
  /// 用 —— 要验主题的测试自己传 [load] 出的真实例。
  factory ThemeState.unloaded({bool Function()? platformDark}) =>
      ThemeState._(AppPrefs.inMemory(), platformDark: platformDark);

  final AppPrefs _prefs;
  final bool Function() _platformDark;

  ThemeModeSetting _mode = ThemeModeSetting.system;
  ThemeColorSetting _color = ThemeColorSetting.mint;
  int _transparency = 0;
  int _frost = 0;
  String _waveStyleId = 'spectrum';
  bool _colored = true;
  String _lyricColor = '';

  /// `system | light | dark`（theme.tsx:18）。
  ThemeModeSetting get mode => _mode;

  /// `mint | pink | blue`。
  ThemeColorSetting get color => _color;

  /// 0~100，越大越透（glass.tsx:22）。
  int get transparency => _transparency;

  /// 0~100，越大越磨砂。
  int get frost => _frost;

  /// 17 样式之一的 id（缺省 'spectrum'）。
  String get waveStyleId => _waveStyleId;

  /// true = 彩色色带；false = 只留歌词高亮色的亮度层次（wave-style.tsx:21）。
  bool get colored => _colored;

  /// 歌词高亮色 `#rrggbb`；空串 = 跟随主题默认（accentLight）。
  String get lyricColor => _lyricColor;

  /// system 解析后的实际明暗（theme.tsx:113）。
  String get resolvedMode => switch (_mode) {
    ThemeModeSetting.light => 'light',
    ThemeModeSetting.dark => 'dark',
    ThemeModeSetting.system => _platformDark() ? 'dark' : 'light',
  };

  /// 明暗 + 主题色的组合 key：波形这类「变了就重画」的地方拿它当依赖
  ///（theme.tsx:144）。
  String get themeKey => '$resolvedMode-${_color.name}';

  /// 卡面 alpha 缩放系数（app.css --glass-level）：1 = 主题原样，0 = 全透。
  double get glassLevel => 1 - _transparency / 100;

  /// 磨砂强度（app.css --frost-level）：0 = 普通卡面，1 = 全磨砂。
  double get frostLevel => _frost / 100;

  /// 测试 / 调试可见：legacy 键是否参与了本次迁移。
  bool legacyApplied = false;

  Future<void> _reload() async {
    _mode = await _readMode();
    _color = await _readColor();
    _transparency = _clamp(
      await _readNumber(StorageKeys.cardTransparency, fallback: 0),
    );
    // frost 老用户迁移（glass.tsx:37-44）：无 cardFrost 键时按透明度回填。
    final hasFrost = _prefs.containsKey(StorageKeys.cardFrost);
    _frost = hasFrost
        ? _clamp(await _readNumber(StorageKeys.cardFrost, fallback: 0))
        : _transparency;
    _waveStyleId =
        (await _prefs.readString(StorageKeys.waveStyle)) ?? 'spectrum';
    // wave-style.tsx:37：`Storage.read(key, true) !== false` —— 只有显式 false 才关。
    _colored = (await _prefs.readString(StorageKeys.waveColored)) != '0';
    _lyricColor = (await _prefs.readString(StorageKeys.lyricColor)) ?? '';
  }

  Future<int> _readNumber(String key, {required int fallback}) async {
    final raw = await _prefs.readString(key);
    return int.tryParse(raw ?? '') ?? fallback;
  }

  int _clamp(int v) => v.clamp(0, 100);

  /// legacy 迁移（theme.tsx:72-95 逐字）。
  Future<ThemeModeSetting> _readMode() async {
    final stored = await _prefs.readString(StorageKeys.themeMode);
    final parsed = _modeFrom(stored);
    if (parsed != null) return parsed;
    final legacy = await _prefs.readString(StorageKeys.theme);
    switch (legacy) {
      case 'system':
        legacyApplied = true;
        return ThemeModeSetting.system;
      case 'light':
        legacyApplied = true;
        return ThemeModeSetting.light;
      case 'dark':
        legacyApplied = true;
        return ThemeModeSetting.dark;
      case 'mint':
      case 'pink':
      case 'blue':
        // 老的四套主题里，浅色归到 light，其余三色都是深色底。
        legacyApplied = true;
        return ThemeModeSetting.dark;
    }
    return ThemeModeSetting.system;
  }

  Future<ThemeColorSetting> _readColor() async {
    final stored = await _prefs.readString(StorageKeys.themeColor);
    final parsed = _colorFrom(stored);
    if (parsed != null) return parsed;
    final legacy = await _prefs.readString(StorageKeys.theme);
    final legacyColor = _colorFrom(legacy);
    if (legacyColor != null) {
      legacyApplied = true;
      return legacyColor;
    }
    return ThemeColorSetting.mint;
  }

  static ThemeModeSetting? _modeFrom(String? v) => switch (v) {
    'system' => ThemeModeSetting.system,
    'light' => ThemeModeSetting.light,
    'dark' => ThemeModeSetting.dark,
    _ => null,
  };

  static ThemeColorSetting? _colorFrom(String? v) => switch (v) {
    'mint' => ThemeColorSetting.mint,
    'pink' => ThemeColorSetting.pink,
    'blue' => ThemeColorSetting.blue,
    _ => null,
  };

  void setMode(ThemeModeSetting next) {
    if (_mode == next) return;
    _mode = next;
    unawaited(_prefs.writeString(StorageKeys.themeMode, next.name));
    notifyListeners();
  }

  void setColor(ThemeColorSetting next) {
    if (_color == next) return;
    _color = next;
    unawaited(_prefs.writeString(StorageKeys.themeColor, next.name));
    notifyListeners();
  }

  void setTransparency(int value) {
    final v = _clamp(value);
    if (_transparency == v) return;
    _transparency = v;
    unawaited(_prefs.writeString(StorageKeys.cardTransparency, '$v'));
    notifyListeners();
  }

  void setFrost(int value) {
    final v = _clamp(value);
    if (_frost == v) return;
    _frost = v;
    unawaited(_prefs.writeString(StorageKeys.cardFrost, '$v'));
    notifyListeners();
  }

  void setWaveStyle(String id) {
    if (_waveStyleId == id) return;
    _waveStyleId = id;
    unawaited(_prefs.writeString(StorageKeys.waveStyle, id));
    notifyListeners();
  }

  void setColored(bool value) {
    if (_colored == value) return;
    _colored = value;
    unawaited(_prefs.writeString(StorageKeys.waveColored, value ? '1' : '0'));
    notifyListeners();
  }

  void setLyricColor(String hex) {
    if (_lyricColor == hex) return;
    _lyricColor = hex;
    unawaited(_prefs.writeString(StorageKeys.lyricColor, hex));
    notifyListeners();
  }
}
