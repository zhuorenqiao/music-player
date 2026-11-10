// test/theme/theme_state_test.dart
//
// M3 T4：ThemeState 七维读写、legacy 迁移矩阵、frost 回填、clamp、themeKey。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/theme/theme_state.dart';

void main() {
  group('基础读写', () {
    test('缺省值：system / mint / 透明 0 / 磨砂 0 / spectrum / 彩色开 / 高亮空', () async {
      final state = await ThemeState.load(AppPrefs.inMemory(), platformDark: () => false);
      expect(state.mode, ThemeModeSetting.system);
      expect(state.color, ThemeColorSetting.mint);
      expect(state.transparency, 0);
      expect(state.frost, 0);
      expect(state.waveStyleId, 'spectrum');
      expect(state.colored, isTrue);
      expect(state.lyricColor, '');
      expect(state.resolvedMode, 'light');
      expect(state.themeKey, 'light-mint');
      expect(state.legacyApplied, isFalse);
    });

    test('set 系列写 prefs 并通知；同值不通知', () async {
      final prefs = AppPrefs.inMemory();
      final state = await ThemeState.load(prefs, platformDark: () => false);
      var notified = 0;
      state.addListener(() => notified++);

      state.setMode(ThemeModeSetting.dark);
      state.setMode(ThemeModeSetting.dark);
      expect(notified, 1);
      expect(await prefs.readString(StorageKeys.themeMode), 'dark');

      state.setColor(ThemeColorSetting.pink);
      expect(await prefs.readString(StorageKeys.themeColor), 'pink');

      state.setTransparency(40);
      expect(await prefs.readString(StorageKeys.cardTransparency), '40');
      expect(state.glassLevel, closeTo(0.6, 0.001));

      state.setFrost(70);
      expect(await prefs.readString(StorageKeys.cardFrost), '70');
      expect(state.frostLevel, closeTo(0.7, 0.001));

      state.setWaveStyle('ribbon');
      expect(await prefs.readString(StorageKeys.waveStyle), 'ribbon');

      state.setColored(false);
      expect(await prefs.readString(StorageKeys.waveColored), '0');

      state.setLyricColor('#ffe066');
      expect(await prefs.readString(StorageKeys.lyricColor), '#ffe066');
    });

    test('clamp：-5 → 0、150 → 100', () async {
      final state = await ThemeState.load(AppPrefs.inMemory());
      state.setTransparency(-5);
      expect(state.transparency, 0);
      state.setTransparency(150);
      expect(state.transparency, 100);
      state.setFrost(-1);
      expect(state.frost, 0);
      state.setFrost(999);
      expect(state.frost, 100);
    });
  });

  group('resolvedMode 与 themeKey', () {
    test('system 跟随注入的平台亮度；light/dark 直接解析', () async {
      expect(
        (await ThemeState.load(AppPrefs.inMemory(), platformDark: () => true)).resolvedMode,
        'dark',
      );
      expect(
        (await ThemeState.load(AppPrefs.inMemory(), platformDark: () => false)).resolvedMode,
        'light',
      );
      final light = await ThemeState.load(AppPrefs.inMemory())
        ..setMode(ThemeModeSetting.light);
      expect(light.resolvedMode, 'light');
      final dark = await ThemeState.load(AppPrefs.inMemory())
        ..setMode(ThemeModeSetting.dark);
      expect(dark.resolvedMode, 'dark');
    });

    test('themeKey = resolvedMode-colorName', () async {
      final state = await ThemeState.load(AppPrefs.inMemory(), platformDark: () => true)
        ..setColor(ThemeColorSetting.blue);
      expect(state.themeKey, 'dark-blue');
    });
  });

  group('legacy 迁移（theme.tsx:72-95 逐字）', () {
    Future<ThemeState> seeded(Map<String, String> kv) async {
      final prefs = AppPrefs.inMemory();
      kv.forEach(prefs.debugSeed);
      return ThemeState.load(prefs, platformDark: () => false);
    }

    test('theme=system / light / dark → 折进 mode', () async {
      expect((await seeded({'theme': 'system'})).mode, ThemeModeSetting.system);
      expect((await seeded({'theme': 'light'})).mode, ThemeModeSetting.light);
      expect((await seeded({'theme': 'dark'})).mode, ThemeModeSetting.dark);
    });

    test('theme=mint/pink/blue → mode 记 dark 且折进 color', () async {
      final mint = await seeded({'theme': 'mint'});
      expect(mint.mode, ThemeModeSetting.dark);
      expect(mint.color, ThemeColorSetting.mint);
      final pink = await seeded({'theme': 'pink'});
      expect(pink.mode, ThemeModeSetting.dark);
      expect(pink.color, ThemeColorSetting.pink);
      final blue = await seeded({'theme': 'blue'});
      expect(blue.color, ThemeColorSetting.blue);
    });

    test('新键优先：themeMode/themeColor 写过就不看 legacy', () async {
      final state = await seeded({'theme': 'pink', 'themeMode': 'light'});
      expect(state.mode, ThemeModeSetting.light);
      expect(state.color, ThemeColorSetting.pink, reason: 'color 走 legacy');
    });

    test('脏值回默认：system / mint', () async {
      final state = await seeded({'themeMode': 'nonsense', 'themeColor': 'x'});
      expect(state.mode, ThemeModeSetting.system);
      expect(state.color, ThemeColorSetting.mint);
    });
  });

  group('frost 老用户迁移（glass.tsx:37-44）', () {
    test('无 cardFrost 键 → frost = cardTransparency', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed(StorageKeys.cardTransparency, '55');
      final state = await ThemeState.load(prefs);
      expect(state.transparency, 55);
      expect(state.frost, 55, reason: '拆两滑杆前磨砂=透明度');
      expect(prefs.containsKey(StorageKeys.cardFrost), isFalse);
    });

    test('有 cardFrost 键 → 各读各的', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed(StorageKeys.cardTransparency, '20')
        ..debugSeed(StorageKeys.cardFrost, '80');
      final state = await ThemeState.load(prefs);
      expect(state.transparency, 20);
      expect(state.frost, 80);
    });
  });

  group('waveColored 三态', () {
    test('缺省 true；显式 0 关；显式 1 开', () async {
      expect((await ThemeState.load(AppPrefs.inMemory())).colored, isTrue);
      final off = AppPrefs.inMemory()..debugSeed(StorageKeys.waveColored, '0');
      expect((await ThemeState.load(off)).colored, isFalse);
      final on = AppPrefs.inMemory()..debugSeed(StorageKeys.waveColored, '1');
      expect((await ThemeState.load(on)).colored, isTrue);
    });
  });
}
