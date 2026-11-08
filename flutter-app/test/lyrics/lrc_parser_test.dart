// test/lyrics/lrc_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lrc_parser.dart';

void main() {
  group('parseLrc 时间轴', () {
    test('一行多个时间标签展开成多行，正文相同', () {
      final parsed = parseLrc('[00:01.00][00:05.00]同一句');
      expect(parsed.lines.map((l) => l.time), [1.0, 5.0]);
      expect(parsed.lines.map((l) => l.text), ['同一句', '同一句']);
    });

    test('小数位按毫秒补齐：.3 → 0.300，.34 → 0.340，.345 → 0.345', () {
      final parsed = parseLrc('[00:01.3]a\n[00:02.34]b\n[00:03.345]c');
      expect(parsed.lines[0].time, closeTo(1.3, 1e-9));
      expect(parsed.lines[1].time, closeTo(2.34, 1e-9));
      expect(parsed.lines[2].time, closeTo(3.345, 1e-9));
    });

    test('冒号也当小数分隔符：[00:01:250]', () {
      expect(parseLrc('[00:01:250]x').lines.single.time, closeTo(1.25, 1e-9));
    });

    test('秒 ≥60 的标签不进时间轴，但仍从正文剥掉', () {
      final parsed = parseLrc('[00:60][00:02]正文');
      expect(parsed.lines.map((l) => l.time), [2.0]);
      expect(parsed.lines.single.text, '正文');
    });

    test('一行里所有标签都非法 → 整行跳过', () {
      expect(parseLrc('[00:99]只有非法标签').lines, isEmpty);
    });

    test('逐字增强型行内标签被剥掉', () {
      final parsed = parseLrc('[00:01.00]<00:01.00>你<00:01.50>好');
      expect(parsed.lines.single.text, '你好');
    });

    test('offset 正值让歌词提前，且钳到 0', () {
      final parsed = parseLrc('[offset:500]\n[00:01.00]a\n[00:00.20]b');
      expect(parsed.lines.map((l) => l.time), [0.0, 0.5]);
    });

    test('offset 空串等于 0（JS Number(\'\') === 0）', () {
      final parsed = parseLrc('[offset:]\n[00:01.00]a');
      expect(parsed.lines.single.time, 1.0);
    });

    test('offset 脏值保持上一个有效值，不重置', () {
      final parsed = parseLrc('[offset:500]\n[offset:abc]\n[00:01.00]a');
      expect(parsed.lines.single.time, closeTo(0.5, 1e-9));
    });

    test('乱序自动排序，且同一时刻保持输入顺序（稳定排序）', () {
      final parsed = parseLrc('[00:03]c\n[00:01]a\n[00:01]b');
      expect(parsed.lines.map((l) => l.text), ['a', 'b', 'c']);
    });

    test('lone \\r 不是行分隔符（与 JS /\\r?\\n/ 一致）', () {
      final parsed = parseLrc('[00:01]a\r[00:02]b');
      // 整串是一行：两个标签都收，正文剥完是 'a\rb'
      expect(parsed.lines.length, 2);
      expect(parsed.lines.every((l) => l.text == 'a\rb'), isTrue);
    });

    test('元信息进 meta，key 小写、值 trim', () {
      final parsed = parseLrc('[TI: 歌名 ]\n[ar:歌手]\n[00:01]正文');
      expect(parsed.meta['ti'], '歌名');
      expect(parsed.meta['ar'], '歌手');
    });

    test('空输入与非歌词文本返回空', () {
      expect(parseLrc('').lines, isEmpty);
      expect(parseLrc('   \n  ').lines, isEmpty);
      expect(parseLrc('没有时间标签的一行').lines, isEmpty);
    });
  });

  group('dropHeaderLines 署名与标题行', () {
    String body(int n) =>
        [for (var i = 0; i < n; i++) '[00:0$i]第$i句'].join('\n');

    test('剔除开头的「词：」「曲：」署名行', () {
      // brief 原构造用 String.replaceAll(regex, fn)，但 Dart 的 replaceAll 第二参
      // 只能是 String（函数版是 replaceAllMapped）；按 Step 4 授权写死等价输入，断言不变。
      final parsed = parseLrc(
        '[00:00]词：方文山\n[00:00]曲：周杰伦\n'
        '[00:00]第0句\n[00:01]第1句\n[00:02]第2句\n[00:03]第3句',
      );
      expect(parsed.lines.map((l) => l.text), ['第0句', '第1句', '第2句', '第3句']);
    });

    test('第 5 行起的署名行不再剔除（窗口按已保留行数算）', () {
      final parsed = parseLrc('${body(4)}\n[00:09]词：某人');
      expect(parsed.lines.last.text, '词：某人');
    });

    test('标题行要同时含歌名与歌手、且长度 ≤60 才剔除', () {
      final parsed = parseLrc(
        '[00:00]十年 - 陈奕迅\n${body(4)}',
        title: '十年',
        artist: '陈奕迅',
      );
      expect(parsed.lines.first.text, '第0句');
    });

    test('清理后不足 3 行就整体回滚', () {
      final parsed = parseLrc('[00:00]词：甲\n[00:01]曲：乙\n[00:02]丙\n[00:03]丁');
      // 剔两行只剩 2 行 < 3 → 回滚成原样 4 行
      expect(parsed.lines.length, 4);
      expect(parsed.lines.first.text, '词：甲');
    });

    test('总行数 ≤3 时完全不清洗', () {
      final parsed = parseLrc('[00:00]词：甲\n[00:01]乙');
      expect(parsed.lines.length, 2);
      expect(parsed.lines.first.text, '词：甲');
    });

    test('context 缺失时回退 meta.ti / meta.ar', () {
      final parsed = parseLrc('[ti:十年]\n[ar:陈奕迅]\n[00:00]十年 - 陈奕迅\n${body(4)}');
      expect(parsed.lines.first.text, '第0句');
    });
  });

  group('plainLyricLines', () {
    test('CRLF 归一、去首尾空行、逐行 trim、保留中间空行', () {
      expect(plainLyricLines('\r\n  \r\n 甲 \r\n\r\n 乙 \r\n \r\n'), [
        '甲',
        '',
        '乙',
      ]);
    });

    test('全空白返回空列表', () {
      expect(plainLyricLines('  \n \n'), isEmpty);
      expect(plainLyricLines(''), isEmpty);
    });
  });

  group('findActiveCue', () {
    List<LyricLine> cues(List<double> times) => [
      for (final t in times) LyricLine(time: t, text: '$t'),
    ];

    test('空列表返回 -1', () {
      expect(findActiveCue([], 10), -1);
    });

    test('早于首行容差返回 -1', () {
      expect(findActiveCue(cues([1, 2]), 0.87), -1);
      expect(findActiveCue(cues([1, 2]), 0.88), 0);
    });

    test('重复时间戳取最后一个（ceil 中点二分）', () {
      expect(findActiveCue(cues([0, 10, 20, 20, 30]), 19.88), 3);
    });

    test('容差判定式必须是 time - 0.12 <= now，不能等价改写', () {
      // 0.121 - 0.12 = 0.0010000000000000009 > 0.001 → 还没到
      expect(findActiveCue(cues([0.121]), 0.001), -1);
      // 若写成 now <= time + 0.12，0.001 <= 0.241 恒真，会错判成 0
    });

    test('远超末行仍返回末行', () {
      expect(findActiveCue(cues([0, 10]), 999), 1);
    });
  });
}
