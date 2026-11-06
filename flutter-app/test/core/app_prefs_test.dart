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
      expect(await prefs.readNumber('muted', min: 0, max: 1), isNull);
    });

    test('readBool 只认真假字符串，脏值用 fallback', () async {
      final prefs = AppPrefs.inMemory()
        ..debugSeed('muted', 'true')
        ..debugSeed('waveColored', '也许');
      expect(await prefs.readBool('muted'), isTrue);
      expect(await prefs.readBool('waveColored', fallback: true), isTrue);
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
