// test/lyrics/opencc_converter_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/opencc/converter.dart';
import 'package:light_music/lyrics/opencc/dicts.dart';

void main() {
  test('生成物完整：五份词典共 6157 条', () {
    expect(kOpenccDictEntryCount, 6157);
    final actual = [
      kDictCjkCompatibility,
      kDictTwVariantsRevPhrases,
      kDictTwVariantsRev,
      kDictTsPhrases,
      kDictTsCharacters,
    ].fold<int>(0, (sum, d) => sum + d.split('|').length);
    expect(actual, kOpenccDictEntryCount);
  });

  test('与 opencc-js 黄金样本逐条一致', () {
    final raw = File('test/fixtures/opencc_golden.json').readAsStringSync();
    final pairs = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    expect(pairs, isNotEmpty);
    for (final pair in pairs) {
      expect(
        tw2s(pair['input'] as String),
        pair['expected'] as String,
        reason: '输入：${pair['input']}',
      );
    }
  });

  test('简体输入原样返回', () {
    expect(tw2s('你好，世界'), '你好，世界');
    expect(tw2s(''), '');
  });

  group('toSimplified 后处理与缓存', () {
    setUp(clearSimplifiedCacheForTest);

    test('妳 → 你、甚么 → 什么', () {
      expect(toSimplified('妳好'), '你好');
      expect(toSimplified('甚么'), '什么');
    });

    test('空串直接返回，不进缓存', () {
      expect(toSimplified(''), '');
      expect(simplifiedCacheLengthForTest, 0);
    });

    test('缓存是 FIFO 不是 LRU：命中不延长寿命', () {
      // 插入 64 条互不相同的输入，中途反复命中第 1 条
      final first = '第0條';
      toSimplified(first);
      for (var i = 1; i < 64; i++) {
        toSimplified('第$i條');
        toSimplified(first); // 反复命中，FIFO 下不改变插入顺序
      }
      expect(simplifiedCacheLengthForTest, 64);
      expect(simplifiedCacheKeysForTest.first, first);
      // 第 65 条触发淘汰：被删的仍是最早插入的 first，而非最近命中的它
      toSimplified('第64條');
      expect(simplifiedCacheLengthForTest, 64);
      expect(simplifiedCacheKeysForTest.contains(first), isFalse);
      expect(simplifiedCacheKeysForTest.first, '第1條');
      // 淘汰后重新转换仍得到正确结果（缓存只影响性能，不影响正确性）
      expect(toSimplified(first), '第0条');
    });
  });
}
