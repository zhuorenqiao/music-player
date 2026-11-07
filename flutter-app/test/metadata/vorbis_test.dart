// test/metadata/vorbis_test.dart
//
// 对译 React 版 tests/t-tags.mjs 的 flac(7) / flac-gbk(4) / ogg(5) 三族，
// 合计 16 条断言 —— 字节布局与期望字符串逐条照搬 JS 侧（那边是字节级权威）。
//
// 两处结构性差异（Id3Tag 按 task-7 的裁定不含 `format` / `year`）：
//   * JS 的 `format: 'flac' / 'ogg'` 改钉 `version`；
//   * JS flac 家族的 `year: '2005'` 没有对应字段，改用封面字节断言顶替。
// 详见 task-8-report.md 的「家族 → 用例 → 断言」对照表。
//
// 末尾三条用例不是 JS 家族的对译，是 brief 点名要求保住的两处行为
// （块长度爆炸不抛、非法 base64 只丢封面）与 parseVorbisComment 的 key 契约。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/vorbis.dart';

import 'tag_fixtures.dart';

// 与 id3_test.dart 同源的 GBK 字节（离线反查后固化，运行时不再用 fast_gbk 现算）。
const List<int> gbkYeQu = [0xd2, 0xb9, 0xc7, 0xfa]; // 夜曲
const List<int> gbkZhouJieLun = [0xd6, 0xdc, 0xbd, 0xdc, 0xc2, 0xd7]; // 周杰伦
const List<int> gbkShiYiYueDeXiaoBang = [
  0xca, 0xae, 0xd2, 0xbb, 0xd4, 0xc2, //
  0xb5, 0xc4, 0xcf, 0xf4, 0xb0, 0xee, // 十一月的萧邦
];

/// GBK 条目：ASCII 的 `KEY=` 前缀 + 固化的 GBK 值字节。
List<int> gbkEntry(String key, List<int> value) => [
  ...latin1.encode(key),
  ...value,
];

void main() {
  test('flac：Vorbis Comment + PICTURE 块', () async {
    final file = flacFile([
      metaBlock(0x00, streamInfo()),
      metaBlock(
        0x04,
        vorbisComment([
          'TITLE=夜曲',
          'ARTIST=周杰伦',
          'ALBUM=十一月的萧邦',
          'DATE=2005',
          'ALBUMARTIST=周杰伦',
        ]),
      ),
      metaBlock(0x06, flacPictureBlock('image/png', pngBody())),
    ]);
    final tag = (await parseFlacMeta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '夜曲');
    expect(tag.artist, '周杰伦');
    expect(tag.album, '十一月的萧邦');
    expect(tag.albumArtist, '周杰伦');
    expect(tag.version, 'flac');
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('flac-gbk：非标准 GBK 的 Vorbis Comment', () async {
    final file = flacFile([
      metaBlock(0x00, streamInfo()),
      metaBlock(
        0x04,
        vorbisComment([
          gbkEntry('TITLE=', gbkYeQu),
          gbkEntry('ARTIST=', gbkZhouJieLun),
          gbkEntry('ALBUM=', gbkShiYiYueDeXiaoBang),
        ]),
      ),
    ]);
    final tag = (await parseFlacMeta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '夜曲');
    expect(tag.artist, '周杰伦');
    expect(tag.album, '十一月的萧邦');
    expect(tag.version, 'flac');
  });

  test('ogg：identification + comment + base64 PICTURE', () async {
    final picture = base64.encode(flacPictureBlock('image/png', pngBody()));
    final file = bytes([
      oggPacket(oggIdent(), bos: true),
      oggPacket(
        oggComment([
          'TITLE=大鱼',
          'ARTIST=周深',
          'ALBUM=深的深',
        ], base64Pictures: [picture]),
      ),
      List<int>.filled(32, 0),
    ]);
    final tag = (await parseOggMeta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '大鱼');
    expect(tag.artist, '周深');
    expect(tag.album, '深的深');
    expect(tag.version, 'ogg');
    expect(tag.pictureMime, 'image/png');
  });

  test('flac：块长度爆炸时停止扫描，已解析字段照常返回', () async {
    final file = bytes([
      fourcc('fLaC'),
      metaBlock(0x04, vorbisComment(['TITLE=夜曲'])),
      // 下一块的头部声称 1000 字节，但文件只剩 8 字节：越界即停，不抛。
      [0x04, 0x00, 0x03, 0xe8],
      List<int>.filled(8, 0),
    ]);
    final tag = (await parseFlacMeta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '夜曲');
  });

  test('ogg：非法 base64 只丢封面，文本字段保留', () async {
    final file = bytes([
      oggPacket(oggIdent(), bos: true),
      oggPacket(
        oggComment(
          ['TITLE=大鱼'],
          base64Pictures: ['这不是 base64!!!'],
        ),
      ),
    ]);
    final tag = (await parseOggMeta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '大鱼');
    expect(tag.picture, isNull);
  });

  test('vorbisComment：key 一律小写且先到先得', () {
    final fields = parseVorbisComment(
      vorbisComment(['TITLE=夜曲', 'title=后到', 'ARTIST=周杰伦']),
    );
    expect(fields, {'title': '夜曲', 'artist': '周杰伦'});
  });
}
