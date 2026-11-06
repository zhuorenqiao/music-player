// test/core/app_prefs_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';

void main() {
  group('AppPrefs', () {
    test('脏 JSON 回退默认值并清理键', () async {
      final prefs = AppPrefs.inMemory()..debugSeed('playlist', '{bad json');
      expect(await prefs.readJson('playlist'), isNull);
      expect(prefs.debugContains('playlist'), isFalse);
    });

    test('readNumber 越界夹紧、非数值回退', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed('volume', '2.5')
        ..debugSeed('muted', 'not-a-number');
      expect(await prefs.readNumber('volume', min: 0, max: 1), 1);
      // 干净值读取后键仍在：任何「读一次就删键」的变异体必须失败。
      expect(prefs.debugContains('volume'), isTrue);
      expect(await prefs.readNumber('muted', min: 0, max: 1), isNull);
      // 脏值分支确认真的清理了脏键。
      expect(prefs.debugContains('muted'), isFalse);
    });

    test('readBool 只认真假字符串，脏值用 fallback', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed('muted', 'true')
        ..debugSeed('waveColored', '也许');
      expect(await prefs.readBool('muted'), isTrue);
      // 干净 'true' 读取后键仍在。
      expect(prefs.debugContains('muted'), isTrue);
      expect(await prefs.readBool('waveColored', fallback: true), isTrue);
      // 脏值分支确认真的清理了脏键。
      expect(prefs.debugContains('waveColored'), isFalse);
    });

    test('写数字后可读回，remove 之后不存在', () async {
      final prefs = AppPrefs.inMemory();
      await prefs.writeNumber('volume', 0.35);
      expect(await prefs.readNumber('volume'), 0.35);
      await prefs.remove('volume');
      expect(prefs.debugContains('volume'), isFalse);
    });
  });
}
