// test/lyrics/opencc_trie_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/opencc/trie.dart';

void main() {
  group('最长前缀匹配', () {
    test('取最长的那个词，不是第一个命中的', () {
      final t = OpenccTrie()..loadDict('幹 干|幹麵 干面');
      expect(t.convert('幹麵好吃'), '干面好吃');
      expect(t.convert('幹活'), '干活');
    });

    test('未匹配字符原样保留，连续未匹配合并', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.convert('乙甲丙丁'), '乙A丙丁');
    });

    test('空词典与空输入', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.convert(''), '');
      expect(t.convert('乙丙'), '乙丙');
    });

    test('增补平面字符按码位匹配，end 走 2 个 UTF-16 单位', () {
      final t = OpenccTrie()..loadDict('𠀀 X');
      expect(t.convert('𠀀尾'), 'X尾');
      final m = t.matchPrefix('𠀀尾', 0);
      expect(m, isNotNull);
      expect(m!.end, 2);
    });
  });

  group('loadDictGroup 逆序加载', () {
    test('reverse 后靠前的词典最后加载、覆盖靠后的（靠前的优先级更高）', () {
      // brief 散文与用例原写「靠后的覆盖靠前的」、期望 'second'，与上游相反：
      // opencc-js loadDictGroup 是 arr.slice().reverse().forEach(loadDict)，
      // reverse 后数组里靠前的词典最后加载，addWord 后写覆盖先写，故靠前的赢。
      // 已用 node 经 opencc-js/core 官方 ESM 导出核实：
      //   loadDictGroup(['甲 first','甲 second']) → 'first'
      //   loadDictGroup(['甲 A','甲 B','甲 C']) → 'A'
      // （证据见 task-4-report.md；实现仍按 brief Step 3 用 dicts.reversed）。
      final t = OpenccTrie()..loadDictGroup(['甲 first', '甲 second']);
      expect(t.convert('甲'), 'first');
    });
  });

  group('loadDict 条目格式', () {
    test('多余 token 丢弃，只取前两个', () {
      final t = OpenccTrie()..loadDict('甲 A extra');
      expect(t.convert('甲'), 'A');
    });

    test('缺替换值抛 FormatException', () {
      expect(() => OpenccTrie()..loadDict('甲'), throwsFormatException);
    });
  });

  group('segment', () {
    test('命中词单独成段，未匹配连续段合并', () {
      final t = OpenccTrie()..loadDict('甲乙 X|丙 Y');
      expect(t.segment('丁甲乙戊丙己'), ['丁', '甲乙', '戊', '丙', '己']);
    });

    test('segment 保留原文，不替换', () {
      final t = OpenccTrie()..loadDict('甲 A');
      expect(t.segment('甲乙').join(), '甲乙');
    });
  });

  group('IDS 感知步长', () {
    test('U+2FF0 二元序列整段跳过', () {
      expect(unmatchedLength('⿰甲乙丙', 0), 3);
    });

    test('U+2FF2 三元序列整段跳过', () {
      expect(unmatchedLength('⿲甲乙丙丁', 0), 4);
    });

    test('嵌套 IDS 递归算长度', () {
      expect(unmatchedLength('⿰⿱甲乙丙丁', 0), 5);
    });

    test('序列不完整时退化成单码位', () {
      expect(unmatchedLength('⿰甲', 0), 1);
    });

    test('普通字符走一个码位；增补平面走 2', () {
      expect(unmatchedLength('甲乙', 0), 1);
      expect(unmatchedLength('𠀀乙', 0), 2);
    });

    test('convert 遇到 IDS 整段原样保留', () {
      final t = OpenccTrie()..loadDict('甲 A');
      // ⿰甲乙 是一个整体，里面的「甲」不该被单独替换
      expect(t.convert('⿰甲乙'), '⿰甲乙');
    });
  });
}
