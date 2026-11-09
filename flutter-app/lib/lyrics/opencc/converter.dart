// lib/lyrics/opencc/converter.dart
//
// tw2s 管线与 toSimplified 后处理。对译 node_modules/opencc-js 的
// preset/t2cn.js configs.tw2s + core.js ConverterFactoryWithSegmentation，
// 以及 src/lib/chinese.ts 的 妳/甚么 后处理与 FIFO-64 缓存。
// 词典组按上游顺序传入（词组在前、单字在后）：loadDictGroup 逆序加载，
// 靠前的词典最后写入、优先级更高（R14 裁定，见 trie.dart 注释）。
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'dicts.dart';
import 'trie.dart';

OpenccTrie _build(List<String> group) => OpenccTrie()..loadDictGroup(group);

final OpenccTrie _normalize = _build([kDictCjkCompatibility]);
final OpenccTrie _segmenter = _build([kDictTsPhrases]);
final OpenccTrie _chain1 = _build([
  kDictTwVariantsRevPhrases,
  kDictTwVariantsRev,
]);
final OpenccTrie _chain2 = _build([kDictTsPhrases, kDictTsCharacters]);

/// 纯 OpenCC tw2s：归一 → 分词 → 逐段过 chain1、chain2，无缓存、无后处理。
String tw2s(String text) {
  final normalized = _normalize.convert(text);
  final segments = _segmenter.segment(normalized);
  return segments.map((s) => _chain2.convert(_chain1.convert(s))).join();
}

const int _cacheLimit = 64;

// LinkedHashMap 默认插入顺序；FIFO 不是 LRU：命中不刷新顺序，超限删 keys.first。
final Map<String, String> _cache = {};

/// 繁体转简体 + 妳→你 / 甚么→什么，带 FIFO-64 缓存（对译 src/lib/chinese.ts）。
String toSimplified(String text) {
  if (text.isEmpty) {
    return text;
  }
  final hit = _cache[text];
  if (hit != null) {
    return hit;
  }
  final converted = tw2s(text).replaceAll('妳', '你').replaceAll('甚么', '什么');
  _cache[text] = converted;
  if (_cache.length > _cacheLimit) {
    _cache.remove(_cache.keys.first);
  }
  return converted;
}

@visibleForTesting
void clearSimplifiedCacheForTest() {
  _cache.clear();
}

@visibleForTesting
int get simplifiedCacheLengthForTest => _cache.length;

/// 插入顺序的键快照，供用例断言 FIFO 淘汰顺序。
@visibleForTesting
List<String> get simplifiedCacheKeysForTest => _cache.keys.toList();
