// test/lyrics/query_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/query.dart';

void main() {
  group('cleanTitle', () {
    test('剥音轨号：01. / 01 - / [01]. / (01)_', () {
      expect(cleanTitle('01. 十年'), '十年');
      expect(cleanTitle('01 - 十年'), '十年');
      expect(cleanTitle('[01]. 十年'), '十年');
      expect(cleanTitle('(01)_十年'), '十年');
    });

    test('裸 [01] 后面没有分隔符时不剥', () {
      expect(cleanTitle('[01] 十年'), '[01] 十年');
    });

    test('剥噪声括号，大小写不敏感、子串匹配、允许错配', () {
      expect(cleanTitle('十年 (Live at Shanghai)'), '十年');
      expect(cleanTitle('十年【OFFICIAL MV】'), '十年');
      expect(cleanTitle('十年（伴奏】'), '十年');
    });

    test('feat 不在噪声词表里，保留', () {
      expect(cleanTitle('十年 (feat. 甲)'), '十年 (feat. 甲)');
    });

    test('折叠多空白、剥尾部 -_ 与空白', () {
      expect(cleanTitle('  十年   -  '), '十年');
      expect(cleanTitle('十年__'), '十年');
    });

    test('噪声括号是单次全局替换：多个噪声括号一遍全剥', () {
      // brief 原写「第一遍剥掉 (Live)，剩下的 (Official) 不再剥」，与原版不符：
      // 原版 .replace(/…/gi, '') 带 g 标志，单次调用即删掉全部匹配，(Live) 与
      // (Official) 都是噪声，一遍后都不剩。已用 node 执行 src/lib/lyrics-source.js
      // :95-169 的逐字源码核实，输出 '十年'（证据见 task-3-report.md）。
      expect(cleanTitle('十年 (Live) (Official)'), '十年');
    });

    test('音轨号只剥一次，不循环到不动点', () {
      // 保住 brief 想钉的「单次、不是循环」：音轨号正则是锚定的非全局替换，
      // 剥掉 01. 之后剩下的 02. 不会再剥（node 核实输出 '02. 十年'）。
      expect(cleanTitle('01. 02. 十年'), '02. 十年');
    });
  });

  group('normalizeQuery', () {
    test('正常歌手原样保留（只 trim）', () {
      final q = normalizeQuery(title: ' 十年 ', artist: ' 陈奕迅 ', duration: 245.5);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
      expect(q.duration, 246);
      expect(q.key, '十年|陈奕迅|246');
    });

    test('key 整串小写', () {
      final q = normalizeQuery(title: 'Hello', artist: 'Adele', duration: 0);
      expect(q.key, 'hello|adele|0');
    });

    test('占位歌手触发文件名反推，反推出来的歌手不再 cleanTitle', () {
      final q = normalizeQuery(title: '陈奕迅 - 十年', artist: '本地文件', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
    });

    test('空歌手与「未知歌手」同样是占位', () {
      expect(
        normalizeQuery(title: '甲 - 乙', artist: '', duration: 0).artistName,
        '甲',
      );
      expect(
        normalizeQuery(title: '甲 - 乙', artist: '未知歌手', duration: 0).artistName,
        '甲',
      );
    });

    test('占位集合大小写敏感：Unknown 不是占位', () {
      final q = normalizeQuery(title: '甲 - 乙', artist: 'Unknown', duration: 0);
      expect(q.artistName, 'Unknown');
      expect(q.trackName, '甲 - 乙');
    });

    test('反推失败时歌手置空', () {
      final q = normalizeQuery(title: '十年', artist: '本地文件', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '');
    });

    test('反推出来的曲名要二次清洗', () {
      final q = normalizeQuery(title: '陈奕迅 - 01. 十年', artist: '', duration: 0);
      expect(q.trackName, '十年');
      expect(q.artistName, '陈奕迅');
    });

    test('时长 NaN / 0 / 负数 / 无穷一律 0', () {
      for (final d in [double.nan, 0.0, -3.0, double.infinity]) {
        expect(normalizeQuery(title: 'x', artist: '', duration: d).duration, 0);
      }
    });
  });
}
