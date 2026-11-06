// test/metadata/id3_test.dart
//
// 对译 React 版 tests/t-tags.mjs 的 8 个 ID3 家族，合计 25 条断言：
//   id3v23 / id3v24-unsync / id3v1 / id3v23-enc0-gbk / id3v23-enc0-utf8 /
//   id3v23-enc0-latin1 / id3v23-enc0-latin1-ambig / id3v1-gbk
// 字节布局与期望字符串逐条照搬 JS 侧（那边的 fixture 是字节级权威）。
//
// 两处结构性差异（Dart 的 Id3Tag 按 task-7-brief 的 interface 不含
// `format` / `year`）：JS 的 `format: 'mp3'` 改钉 `version`（'id3v2.3' /
// 'id3v1'）；JS 的 `year` 没有对应字段，id3v1 家族改用「不设置 albumArtist」
// 补足第 5 条断言。详见 task-7-report.md 的偏差表。
//
// 另外第 9 个用例（id3v22）不是 JS 家族的对译，而是 fix round 1 的回归证明：
// JS 侧没有 v2.2 夹具，此前 v2.2 分支的字节布局只在临时探针里验过。上面 8 个
// 用例的名字与断言一律未改。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/id3.dart';

import 'tag_fixtures.dart';

Future<Id3Tag?> parse(List<int> file) => parseId3v2(ByteSource.fromBytes(file));

Future<Id3Tag?> parseV1(List<int> file) =>
    parseId3v1(ByteSource.fromBytes(file));

// GBK 字节：离线用 `TextDecoder('gbk')` 反查后固化（与 t-tags.mjs 的 gbk() 同源）。
// 测试运行时不再用 fast_gbk 现算 —— 否则等于用被测的同一个库给自己出题。
const List<int> gbkYeQu = [0xd2, 0xb9, 0xc7, 0xfa]; // 夜曲
const List<int> gbkZhouJieLun = [0xd6, 0xdc, 0xbd, 0xdc, 0xc2, 0xd7]; // 周杰伦
const List<int> gbkShiYiYueDeXiaoBang = [
  0xca, 0xae, 0xd2, 0xbb, 0xd4, 0xc2, //
  0xb5, 0xc4, 0xcf, 0xf4, 0xb0, 0xee, // 十一月的萧邦
];

void main() {
  test('id3v23：文本帧与 APIC 全覆盖', () async {
    final file = bytes([
      id3v2([
        textFrame('TIT2', '光年之外', encoding: 1),
        textFrame('TPE1', 'G.E.M. 邓紫棋', encoding: 1),
        textFrame('TALB', '另一个城市'),
        textFrame('TPE2', 'G.E.M.'),
        textFrame('TYER', '2016'),
        apicFrame('image/png', pngBody()),
      ]),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.title, '光年之外');
    expect(tag.artist, 'G.E.M. 邓紫棋');
    expect(tag.album, '另一个城市');
    expect(tag.albumArtist, 'G.E.M.');
    expect(tag.version, 'id3v2.3');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('id3v24-unsync：帧长 synchsafe 且 unsync 还原', () async {
    // JS 侧手工拼头：flags = 0x80（整标签 unsynchronisation），
    // APIC 里故意塞 0xff 0x00 让还原后少一个字节。
    final unsyncBody = bytes([
      textFrame('TIT2', 'Unsync 测试', version: 4),
      apicFrame('image/png', [0xff, 0x00, 0xd8, 0xff, 0xe0], version: 4),
    ]);
    final file = bytes([
      fourcc('ID3'),
      [4, 0, 0x80],
      synchsafe(unsyncBody.length),
      unsyncBody,
      ...mpegFrame(),
    ]);
    final tag = await parse(file);
    expect(tag?.title, 'Unsync 测试');
    expect(tag?.version, 'id3v2.4');
  });

  test('id3v22：3 字节帧头 + PIC 格式码（TT2 / PIC 均解出）', () async {
    // 回归（fix round 1）：v2.2 的帧头是 3 字节 id + 3 字节大端长度、**没有
    // flags**；PIC 里 mime 的位置是 3 字符格式码（PNG），格式码后面直接是
    // 封面类型字节。夹具若按 v2.3 布局写 4 字节长度 + 2 字节 flags，解析器读
    // 到的帧长恒为 0，整标签一个字段都解不出来 —— 本用例钉住这条端到端路径。
    final file = bytes([
      id3v2([
        textFrame('TT2', '十年', version: 2),
        apicFrame('image/png', pngBody(), version: 2),
      ], version: 2),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.version, 'id3v2.2');
    expect(tag.title, '十年');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('id3v1：尾部 128 字节 TAG（无编码位，Latin-1 兜底）', () async {
    // t-tags.mjs: bytes(MPEG_FRAME, 'TAG', 3×30 字节空格填充, '1966', 31 个 0)
    final file = bytes([
      ...mpegFrame(),
      fourcc('TAG'),
      latin1.encode('Yellow Submarine'.padRight(30)),
      latin1.encode('The Beatles'.padRight(30)),
      latin1.encode('Revolver'.padRight(30)),
      latin1.encode('1966'),
      List<int>.filled(31, 0),
    ]);
    final tag = (await parseV1(file))!;
    expect(tag.title, 'Yellow Submarine');
    expect(tag.artist, 'The Beatles');
    expect(tag.album, 'Revolver');
    expect(tag.version, 'id3v1');
    // ID3v1 没有 albumArtist（JS 这里断言的是 year，Dart 结构未暴露该字段）
    expect(tag.albumArtist, '');
  });

  test('id3v23-enc0-gbk：声明 encoding=0 实为 GBK', () async {
    final file = bytes([
      id3v2([
        rawTextFrame('TIT2', gbkYeQu),
        rawTextFrame('TPE1', gbkZhouJieLun),
      ]),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.title, '夜曲');
    expect(tag.artist, '周杰伦');
  });

  test('id3v23-enc0-utf8：声明 encoding=0 实为 UTF-8', () async {
    final file = bytes([
      id3v2([
        rawTextFrame('TIT2', utf8.encode('夜曲')),
        rawTextFrame('TPE1', utf8.encode('周杰伦')),
      ]),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.title, '夜曲');
    expect(tag.artist, '周杰伦');
  });

  test('id3v23-enc0-latin1：真 Latin-1 不被当 GBK 解', () async {
    final file = bytes([
      id3v2([rawTextFrame('TIT2', latin1.encode('Café del Mar'))]),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.title, 'Café del Mar');
  });

  test('id3v23-enc0-latin1-ambig：高位歧义不抛、不乱码', () async {
    // Motörhead 的 ö(0xF6) + r(0x72) 恰好是合法 GBK 双字节，必须有别的信号挡住误判
    final file = bytes([
      id3v2([
        rawTextFrame('TIT2', latin1.encode('Motörhead')),
        rawTextFrame('TPE1', latin1.encode('Sigur Rós')),
      ]),
      ...mpegFrame(),
    ]);
    final tag = (await parse(file))!;
    expect(tag.title, 'Motörhead');
    expect(tag.artist, 'Sigur Rós');
  });

  test('id3v1-gbk：ID3v1 无编码位，GBK 嗅探', () async {
    final file = bytes([
      ...mpegFrame(),
      fourcc('TAG'),
      v1FieldBytes(gbkYeQu),
      v1FieldBytes(gbkZhouJieLun),
      v1FieldBytes(gbkShiYiYueDeXiaoBang),
      latin1.encode('2005'),
      List<int>.filled(31, 0),
    ]);
    final tag = (await parseV1(file))!;
    expect(tag.title, '夜曲');
    expect(tag.artist, '周杰伦');
    expect(tag.album, '十一月的萧邦');
    expect(tag.version, 'id3v1');
  });
}
