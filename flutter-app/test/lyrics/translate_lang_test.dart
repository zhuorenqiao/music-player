// test/lyrics/translate_lang_test.dart
//
// 对表 src/lib/translate-source.js:58-101 的 needsTranslation。每条期望值都用
// node 跑过真实 JS 实现（node --input-type=module，import 本仓库的 translate-source.js），
// 不是从注释推的。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/translate_lang.dart';

void main() {
  test('纯中文不翻译', () {
    expect(needsTranslation('[00:01]我们一起看月亮爬上来'), isFalse);
  });

  test('假名 ≥3 要翻译', () {
    expect(needsTranslation('きみのこえ'), isTrue);
    // 11 个汉字 + 3 个假名：只看汉字占比会是 1.0（判成中文），必须由假名分支拦下。
    expect(needsTranslation('今日天気予報会場案内の歌です'), isTrue);
    // 2 个假名 + 2 个汉字：不到 3 个假名 → 落到汉字/拉丁分支（han<8 且无拉丁 → 不翻译）。
    expect(needsTranslation('君の声が'), isFalse);
    // 纯假名（2 个）：han+latin==0 分支，仍判外语（JS 实测 true）。
    expect(needsTranslation('きみの'), isTrue);
  });

  test('谚文 ≥1 要翻译', () {
    expect(needsTranslation('사랑해'), isTrue);
    // 谚文 + 汉字：去掉谚文分支后会落到 han<8 → latin>0 = false。
    expect(needsTranslation('사랑해 我们'), isTrue);
  });

  test('纯英文要翻译', () {
    expect(needsTranslation('Hello darkness my old friend'), isTrue);
  });

  test('汉字占比 <35% 要翻译', () {
    // 只有 3 个汉字：走 han<8 分支（有拉丁 → 翻）。
    expect(needsTranslation('I love you 我爱你'), isTrue);
    // 8 个汉字 + 15 个拉丁字母：8/23 ≈ 0.348 < 0.35，走占比分支。
    expect(needsTranslation('心若向阳无畏悲伤 abcdefghijklmno'), isTrue);
  });

  test('汉字占比 ≥35% 不翻译', () {
    // 8 个汉字 + 14 个拉丁字母：8/22 ≈ 0.364 ≥ 0.35。
    expect(needsTranslation('心若向阳无畏悲伤 abcdefghijklmn'), isFalse);
    // 正好 35%（14/40）：strict `<` 才翻，等于 0.35 不翻。
    expect(
      needsTranslation('我们一起走过春夏秋冬看遍世间 abcdefghijklmnopqrstuvwxyz'),
      isFalse,
    );
  });

  test('拉丁区间是 A–z（含 `[ \\ ] ^ _ 反引号`），不是 A-Za-z', () {
    // 14 个字母 + 1 个下划线：按 JS 区间 latin=15 → 8/23 ≈ 0.348 < 0.35 → 要翻；
    // 若「顺手修正」成 A-Za-z 则 latin=14 → 8/22 ≈ 0.364 → 不翻。
    expect(needsTranslation('心若向阳无畏悲伤 abcdefghijklmn_'), isTrue);
  });

  test('汉字 <8 时只看有没有拉丁字母', () {
    expect(needsTranslation('天空 abc'), isTrue);
    expect(needsTranslation('天空'), isFalse);
  });

  test('只有空白/时间标签 → 不翻译', () {
    expect(needsTranslation('   '), isFalse);
    expect(needsTranslation('[00:01]'), isFalse);
  });

  test('方括号标签与逐字标签不计入语种统计', () {
    // [ti:Hello] 里的 latin 若漏剥，han<8 分支会判成需要翻译。
    expect(needsTranslation('[ti:Hello]\n[00:01]你好世界'), isFalse);
    expect(needsTranslation('[00:01]<00:01:000>你好世界'), isFalse);
  });

  test('一个汉字都没有、但有符号 → 仍判为需要翻译（han+latin==0 分支）', () {
    // 韩文/假名已在前面拦掉；这里用西里尔字母与纯标点验证该分支。
    expect(needsTranslation('Привет'), isTrue);
    expect(needsTranslation('……！？'), isTrue);
  });
}
