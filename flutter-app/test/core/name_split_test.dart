// test/core/name_split_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/name_split.dart';

void main() {
  test('带空格版优先，三种破折号都认', () {
    expect(splitArtistTitleOrNull('陈奕迅 - 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitleOrNull('陈奕迅 – 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitleOrNull('陈奕迅 — 十年'), (artist: '陈奕迅', title: '十年'));
  });

  test('紧凑版要求两侧都含汉字', () {
    expect(splitArtistTitleOrNull('周杰倫-十年'), (artist: '周杰倫', title: '十年'));
    expect(splitArtistTitleOrNull('track-02'), isNull);
    expect(splitArtistTitleOrNull('Jay-Z'), isNull);
    // brief 原写 isNull／「左侧无汉字」，与原版不符：初（U+521D）与音（U+97F3）
    // 都落在 CJK_PATTERN 的 U+3400-U+9FFF 里，而判定是「含一个汉字」不是「全是汉字」，
    // 所以原版照拆。已用 node 执行 src/lib/lyrics-source.js:95-169 的逐字源码核实，
    // 输出 {artist:'初音ミク', title:'歌名'}（证据见 task-3-report.md）。
    expect(splitArtistTitleOrNull('初音ミク-歌名'), (artist: '初音ミク', title: '歌名'));
    // 保住 brief 想钉的那条规则：左侧纯假名（一个汉字都没有）才不拆。
    expect(splitArtistTitleOrNull('ミク-歌名'), isNull);
    // 谚文同样不在 CJK_PATTERN 里；右侧不含汉字也不拆（「两侧都含」不是只看左侧）。
    expect(splitArtistTitleOrNull('한국-歌名'), isNull);
    expect(splitArtistTitleOrNull('陈奕迅-ミク'), isNull);
  });

  test('全角减号与 U+2212 不是分隔符', () {
    expect(splitArtistTitleOrNull('陈奕迅－十年'), isNull);
    expect(splitArtistTitleOrNull('陈奕迅−十年'), isNull);
  });

  test('带空格版匹配但一侧为空 → null，不回退紧凑版', () {
    expect(splitArtistTitleOrNull(' - 十年'), isNull);
    expect(splitArtistTitleOrNull('陈奕迅 - '), isNull);
  });

  test('空串与纯空白 → null', () {
    expect(splitArtistTitleOrNull(''), isNull);
    expect(splitArtistTitleOrNull('   '), isNull);
  });

  test('没有分隔符 → null', () {
    expect(splitArtistTitleOrNull('十年'), isNull);
  });

  test('第一个分隔符处拆，右侧可再含分隔符', () {
    expect(splitArtistTitleOrNull('a - b - c'), (artist: 'a', title: 'b - c'));
  });

  test('长度上限：歌手 >60 或曲名 >80 不拆', () {
    expect(splitArtistTitleOrNull('${'甲' * 61} - 乙'), isNull);
    expect(splitArtistTitleOrNull('甲 - ${'乙' * 81}'), isNull);
  });

  test('长度上限是闭区间：正好 60 / 80 仍拆（防 off-by-one）', () {
    expect(splitArtistTitleOrNull('${'甲' * 60} - 乙'), (
      artist: '甲' * 60,
      title: '乙',
    ));
    expect(splitArtistTitleOrNull('甲 - ${'乙' * 80}'), (
      artist: '甲',
      title: '乙' * 80,
    ));
  });
}
