// lib/lyrics/opencc/trie.dart
//
// 对译 opencc-js 的码位 Trie：node_modules/opencc-js/dist/esm-lib/core.js 的
// Trie 类（22-170）与码位/IDS 辅助函数 getCodePointLength、
// getIdeographicDescriptionArity、getIdeographicDescriptionSequenceEnd、
// getUnmatchedLength（172-207）。纯 Dart、无 IO、无状态、无 Flutter 依赖；
// Task 5 会往里灌真实内嵌词典并搭 tw2s，本文件只负责算法，API 签名不随之改动。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/lyrics/opencc_trie_test.dart）：
// * Trie 的 key 是码位（code point），matchPrefix 逐码位下行，但返回的 end 是
//   UTF-16 下标 —— 增补平面字符（如 𠀀）一步走 2，不能拿 runes 计数当 end；
// * 最长前缀匹配：记录「最后一个」有值的节点，不是第一个命中（幹 / 幹麵 取 幹麵）；
// * trie_val 用 undefined 判定是否有值，空串替换值也算命中；Dart 用 String? 的
//   null 表达「无值」，'' 是合法值，判命中要用 != null 而非 isEmpty；
// * loadDictGroup 是 arr.reverse() 后逐个 loadDict：reverse 后数组里「靠前」的
//   词典最后加载，addWord 后写覆盖先写，故靠前的优先级更高（brief 散文与用例原写
//   「靠后覆盖靠前 / 期望 second」与上游相反，已按 node 核实改成 first，见用例注释）；
// * loadDict 按 | 切条目、按第一个空格切 src/dst（line.split(' ') 取前两个，多余
//   token 丢弃）；缺 dst（parts.length < 2）抛错（JS TypeError → Dart FormatException）；
// * convert 与 segment 唯一区别：前者把命中段换成词典值，后者保留原文切片；两者
//   未匹配都按 unmatchedLength 前进，并把连续未匹配合并成一段（orig_i 哨兵）；
// * IDS（表意文字描述序列，operator 仅 U+2FF0–U+2FFF）：完整序列整段递归跳过，
//   子项不够时返回 0、退化成单码位；_idsEnd 返回 0 表示「不是完整序列」。
//   U+31C0–U+31EF 是 CJK 笔画，属普通叶子字符（arity 0），不是 operator；
// * 孤立高代理项：JS codePointAt 返回代理项本身，_codePointAt 与之一致。

/// 码位 Trie：key 为码位，节点挂可空替换值。对译 core.js 的 Trie 类。
class OpenccTrie {
  final _Node _root = _Node();

  /// 加入一个词：逐码位下行建节点，末节点挂替换值（后写覆盖先写）。
  void addWord(String word, String value) {
    var node = _root;
    for (var i = 0; i < word.length;) {
      final cp = _codePointAt(word, i);
      i += cp > 0xFFFF ? 2 : 1;
      node = node.children.putIfAbsent(cp, _Node.new);
    }
    node.value = value;
  }

  /// 读字典文本："src dst|src dst"。按 | 切条目、按第一个空格切 src/dst，
  /// 多余 token 丢弃；缺 dst 抛 FormatException（对译 JS 的 TypeError）。
  void loadDict(String dict) {
    for (final line in dict.split('|')) {
      final parts = line.split(' ');
      if (parts.length < 2) {
        throw FormatException('Invalid dictionary entry: $line');
      }
      addWord(parts[0], parts[1]);
    }
  }

  /// 逆序加载词典组：reverse 后逐个 loadDict，故数组里靠前的词典最后加载、
  /// 覆盖靠后的（靠前的优先级更高）。对译 core.js 的 loadDictGroup。
  void loadDictGroup(List<String> dicts) {
    for (final dict in dicts.reversed) {
      loadDict(dict);
    }
  }

  /// 从 start 起最长前缀匹配。end 是 UTF-16 下标（增补平面走 2）；无匹配返回 null。
  ({int end, String value})? matchPrefix(String s, int start) {
    final n = s.length;
    var curr = _root;
    var k = 0;
    String? v;
    for (var j = start; j < n;) {
      final x = _codePointAt(s, j);
      j += x > 0xFFFF ? 2 : 1;
      final next = curr.children[x];
      if (next == null) {
        break;
      }
      curr = next;
      final vCurr = curr.value;
      if (vCurr != null) {
        k = j;
        v = vCurr;
      }
    }
    if (k > 0) {
      return (end: k, value: v!);
    }
    return null;
  }

  /// 分词：命中词单独成段（保留原文切片），连续未匹配合并成一段。
  List<String> segment(String s) {
    final n = s.length;
    final segments = <String>[];
    int? origI;
    for (var i = 0; i < n;) {
      final matched = matchPrefix(s, i);
      if (matched != null) {
        if (origI != null) {
          segments.add(s.substring(origI, i));
          origI = null;
        }
        segments.add(s.substring(i, matched.end));
        i = matched.end;
      } else {
        origI ??= i;
        i += unmatchedLength(s, i);
      }
    }
    if (origI != null) {
      segments.add(s.substring(origI, n));
    }
    return segments;
  }

  /// 转换：与 segment 同循环，但命中段换成词典值，最后 join。
  String convert(String s) {
    final n = s.length;
    final arr = <String>[];
    int? origI;
    for (var i = 0; i < n;) {
      final matched = matchPrefix(s, i);
      if (matched != null) {
        if (origI != null) {
          arr.add(s.substring(origI, i));
          origI = null;
        }
        arr.add(matched.value);
        i = matched.end;
      } else {
        origI ??= i;
        i += unmatchedLength(s, i);
      }
    }
    if (origI != null) {
      arr.add(s.substring(origI, n));
    }
    return arr.join();
  }
}

/// Trie 节点：children 的 key 是码位，value 是可空替换值（null 表示无值）。
class _Node {
  final Map<int, _Node> children = {};
  String? value;
}

/// 读 s 在 UTF-16 下标 i 处的码位。Dart 无 codePointAt，自己写；
/// 孤立高代理项（后面不是低代理项）返回代理项本身，与 JS 一致。
int _codePointAt(String s, int i) {
  final hi = s.codeUnitAt(i);
  if (hi >= 0xD800 && hi <= 0xDBFF && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF) {
      return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
    }
  }
  return hi;
}

/// i 处码位占几个 UTF-16 单位（增补平面 2，其余 1）。
int _codePointLength(String s, int i) => _codePointAt(s, i) > 0xFFFF ? 2 : 1;

/// IDS operator 的元数：U+2FF0–2FF1 二元、2FF2–2FF3 三元、2FF4–2FFF 二元，其余 0。
int _idsArity(int cp) {
  if (cp >= 0x2FF0 && cp <= 0x2FF1) {
    return 2;
  }
  if (cp >= 0x2FF2 && cp <= 0x2FF3) {
    return 3;
  }
  if (cp >= 0x2FF4 && cp <= 0x2FFF) {
    return 2;
  }
  return 0;
}

/// 完整 IDS 的末尾 UTF-16 下标；返回 0 表示「不是完整序列」（非 operator 或子项不够）。
int _idsEnd(String s, int i) {
  final cp = _codePointAt(s, i);
  final arity = _idsArity(cp);
  if (arity == 0) {
    return 0;
  }
  var end = i + _codePointLength(s, i);
  for (var n = 0; n < arity; n += 1) {
    if (end >= s.length) {
      return 0;
    }
    final childEnd = _idsEnd(s, end);
    end = childEnd != 0 ? childEnd : end + _codePointLength(s, end);
  }
  return end;
}

/// 未匹配时的步长（UTF-16 单位）：完整 IDS 整段跳过，否则跳一个码位。
int unmatchedLength(String s, int i) {
  final idsEnd = _idsEnd(s, i);
  if (idsEnd > i) {
    return idsEnd - i;
  }
  return _codePointLength(s, i);
}
