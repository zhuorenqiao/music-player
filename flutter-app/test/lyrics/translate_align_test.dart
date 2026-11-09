// test/lyrics/translate_align_test.dart
//
// 对表 src/lib/translate-source.js:277-422 的 alignTranslation 全流程。
// 每条期望值都用 node 跑过真实 JS 实现（import 本仓库的 translate-source.js），
// 不是从注释推的；与 brief 初稿期望不一致的四条已在行内注明原因。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';
import 'package:light_music/lyrics/translate_align.dart';

List<LyricLine> cued(List<(double, String)> pairs) => [
  for (final p in pairs) LyricLine(time: p.$1, text: p.$2),
];

List<LyricLine> plain(List<String> texts) => [
  for (final t in texts) LyricLine(time: double.nan, text: t),
];

void main() {
  test('空输入、空译文、译文无正文都返回全空且长度对齐', () {
    expect(alignTranslation(const [], '[00:01]甲'), <String>[]);
    final lines = cued([(1, '你')]);
    expect(alignTranslation(lines, ''), ['']);
    expect(alignTranslation(lines, '[00:01]'), ['']);
  });

  test('同一时间区间的多条译文并成一行', () {
    final lines = cued([(0, '第一句'), (5, '第二句')]);
    const trans = '[00:00]一句\n[00:01]续\n[00:02]再接';
    expect(alignTranslation(lines, trans), ['一句 续 再接', '']);
  });

  test('译文落在「它所属歌词行」的区间里，不足覆盖率则整首退回单语', () {
    // 5 条译文全部落在第 0 行 → 覆盖率 1/5 = 0.2 < 0.25
    final lines = cued([(0, 'a'), (10, 'b')]);
    const trans = '[00:00]1\n[00:01]2\n[00:02]3\n[00:03]4\n[00:04]5';
    expect(alignTranslation(lines, trans), ['', '']);
  });

  test('覆盖率正好 0.25 时保留（严格小于才退回）', () {
    // 4 条译文全部落在第 0 行 → 覆盖率 1/4 = 0.25，不触发闸门
    final lines = cued([(0, 'a'), (10, 'b')]);
    const trans = '[00:00]1\n[00:01]2\n[00:02]3\n[00:03]4';
    expect(alignTranslation(lines, trans), ['1 2 3 4', '']);
  });

  test('起手保护：离下一句更近且 ≤1.5s 时归下一句', () {
    final lines = cued([(0, 'a'), (2, 'b')]);
    // 1.0 离 2.0 只有 1.0s（≤1.5）且 2.0 > 1.0 → 归第二句
    expect(alignTranslation(lines, '[00:01.00]乙'), ['', '乙']);
  });

  test('起手保护正好 1.5s 也归下一句', () {
    final lines = cued([(0, 'a'), (2.5, 'b')]);
    expect(alignTranslation(lines, '[00:01.00]乙'), ['', '乙']);
  });

  test('起手保护不跨过 1.5s', () {
    final lines = cued([(0, 'a'), (3, 'b')]);
    expect(alignTranslation(lines, '[00:01.00]甲'), ['甲', '']);
  });

  test('译文时间正好等于某行时间时归该行（cueIndexAt 用 <=）', () {
    final lines = cued([(0, 'a'), (1, 'b')]);
    // at = 1.0 正好等于第二行时间 → 归第二行；brief 原期望 ['乙',''] 是 `<` 的结果，与 JS 实测不符
    expect(alignTranslation(lines, '[00:01.00]乙'), ['', '乙']);
  });

  test('重复时间戳归到同刻那组的第一行', () {
    final lines = cued([(0, 'a'), (5, 'b1'), (5, 'b2'), (9, 'c')]);
    expect(alignTranslation(lines, '[00:05.00]乙'), ['', '乙', '', '']);
  });

  test('中位数偏移：译文库整体晚 3 秒，对齐时扣掉', () {
    final lines = cued([(0, '甲'), (2, '乙'), (4, '丙'), (10, '丁')]);
    const original = '[00:03]甲\n[00:05]乙\n[00:07]丙';
    const trans = '[00:03]A\n[00:05]B\n[00:07]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C', '']);
  });

  test('偶数个锚点取上中位数（不做平均）', () {
    final lines = cued([(0, '甲'), (20, '乙'), (40, '丙'), (60, '丁')]);
    const original = '[00:01]甲\n[00:22]乙\n[00:48]丙\n[01:09]丁';
    // diffs = [1, 2, 8, 9] → 上中位数 8（下中位数 2 / 平均 5 都会落到第 1 行）
    expect(alignTranslation(lines, '[00:26]A', original), ['A', '', '', '']);
  });

  test('重复歌词行只按首次出现算偏移', () {
    final lines = cued([(0, '甲'), (12, '甲'), (20, '乙'), (30, '丙')]);
    const original = '[00:05]甲\n[00:13]甲\n[00:22]乙\n[00:32]丙';
    // 首次出现：diffs = [5, 13, 2, 2] → 5；若用最后一次出现则 diffs = [-7, 1, 2, 2] → 2
    expect(alignTranslation(lines, '[00:15]A', original), ['A', '', '', '']);
  });

  test('锚点不足 3 个 → 偏移按 0', () {
    final lines = cued([(0, '甲'), (2, '乙'), (4, '丙')]);
    const original = '[00:03]甲\n[00:05]乙';
    const trans = '[00:03]A\n[00:05]B\n[00:07]C';
    // 只有 2 个锚点，若误用则中位数 3 → ['A','B','C']；按 0 时译文 3/5/7 全落到末行并合并
    expect(alignTranslation(lines, trans, original), ['', '', 'A B C']);
  });

  test('|中位偏移| > 20 视为不可信，按 0', () {
    final lines = cued([(0, '甲'), (20, '乙'), (40, '丙')]);
    const original = '[00:30]甲\n[00:50]乙\n[01:10]丙';
    const trans = '[00:30]A\n[00:50]B\n[01:10]C';
    // 中位偏移 30 → 归零：at=30 落在第 1 行（40-30=10 > 1.5），50/70 都在末行合并
    expect(alignTranslation(lines, trans, original), ['', 'A', 'B C']);
  });

  test('|中位偏移| 正好 20 仍算可信', () {
    final lines = cued([(0, '甲'), (20, '乙'), (40, '丙')]);
    const original = '[00:20]甲\n[00:40]乙\n[01:00]丙';
    const trans = '[00:20]A\n[00:40]B\n[01:00]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C']);
  });

  test('偏移为负（译文库更早）也照减', () {
    final lines = cued([(10, '甲'), (20, '乙'), (30, '丙')]);
    const original = '[00:05]甲\n[00:15]乙\n[00:25]丙';
    const trans = '[00:05]A\n[00:15]B\n[00:25]C';
    expect(alignTranslation(lines, trans, original), ['A', 'B', 'C']);
  });

  test('at 钳到 0：译文早于首行时间也不越界', () {
    final lines = cued([(5, '甲'), (10, '乙')]);
    expect(alignTranslation(lines, '[00:00]A'), ['A', '']);
  });

  group('纯文本路径', () {
    final display = plain(['甲', '乙', '丙', '丁']);

    test('按原文配对；覆盖率 ≥50% 时允许部分槽为空', () {
      const original = '[00:00]甲\n[00:02]乙\n[00:04]丙\n[00:06]丁';
      const trans = '[00:00]A\n[00:02]B\n[00:04]C';
      expect(alignTranslation(display, trans, original), ['A', 'B', 'C', '']);
    });

    test('覆盖率 <50% 整首退回单语', () {
      final four = plain(['甲', '乙', '丙', '丁', '戊', '己']);
      const original =
          '[00:00]甲\n[00:02]乙\n[00:04]丙\n[00:06]丁\n[00:08]戊\n[00:10]己';
      const trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(four, trans, original), ['', '', '', '', '', '']);
    });

    test('覆盖率正好 50% 时保留（严格小于才退回）', () {
      const original = '[00:00]甲\n[00:02]乙\n[00:04]丙\n[00:06]丁';
      const trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(display, trans, original), ['A', 'B', '', '']);
    });

    test('没有译文库原文时无法配对 → 全空', () {
      expect(alignTranslation(display, '[00:00]A\n[00:02]B'), ['', '', '', '']);
    });

    test('归一化后同文本的行共用同一份译文（首次出现优先）', () {
      final d = plain(['甲,', '乙', '甲']);
      const original = '[00:00]甲\n[00:02]乙';
      const trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(d, trans, original), ['A', 'B', 'A']);
    });

    test('去噪字符类逐字照抄：半角 ! 去掉，全角 ！ 保留', () {
      const original = '[00:00]甲\n[00:02]乙';
      const trans = '[00:00]A\n[00:02]B';
      expect(alignTranslation(plain(['甲!', '乙']), trans, original), ['A', 'B']);
      // JS 的字符类只列了半角 !，全角 ！ 原样保留 → 配不上（brief 原期望 ['A','B','A'] 与此不符）
      expect(alignTranslation(plain(['甲！', '乙']), trans, original), ['', 'B']);
    });

    test('归一化：先小写、去全角空格、合并多余空白', () {
      // 小写化在剥字符之前
      expect(alignTranslation(plain(['Hello']), '[00:00]A', '[00:00]HELLO'), [
        'A',
      ]);
      // 全角空格 U+3000 与 \s 一并剥掉
      expect(alignTranslation(plain(['甲　乙']), '[00:00]A', '[00:00]甲乙'), ['A']);
      // joinFragments 把 2 个以上空白并成一个
      expect(alignTranslation(plain(['甲']), '[00:00]A  B', '[00:00]甲'), [
        'A B',
      ]);
    });

    test('一行原文对应多条译文时合并', () {
      final d = plain(['甲']);
      const original = '[00:00]甲';
      expect(alignTranslation(d, '[00:00]A\n[00:00]B', original), ['A B']);
    });
  });

  test('混合数组（部分有 time）走纯文本路径', () {
    final mixed = [
      const LyricLine(time: 0, text: '甲'),
      const LyricLine(time: double.nan, text: '乙'),
    ];
    const original = '[00:00]甲\n[00:02]乙';
    const trans = '[00:00]A\n[00:02]B';
    expect(alignTranslation(mixed, trans, original), ['A', 'B']);
  });
}
