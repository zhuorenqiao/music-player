// test/metadata/audio_tags_test.dart
//
// 对译 React 版 tests/t-tags.mjs 的对外入口用例：畸形输入族（:378-392）与
// mergeTaggedNames 族（:394-398），外加 brief 要求的 `splitArtistTitle`、
// 「ID3v2.4 标签后跟超长音频」与容器分派用例。
//
// 与 JS 的既定差异（裁定 R-YEAR）：`Id3Tag` 没有 `year` 字段，所以 t-tags.mjs
// 的 57 条断言里 4 条 year（id3v23 / id3v1 / id3v1-gbk / flac）无对应物，
// 对表总数 54（见 task-10-report.md 的家族对照表）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/audio_tags.dart';
import 'package:light_music/metadata/byte_reader.dart';

import 'tag_fixtures.dart';

void main() {
  group('readAudioTags 对畸形输入永不抛', () {
    test('空文件：format=unknown，其余字段为空', () async {
      final tags = await readAudioTags(ByteSource.fromBytes(const []));
      expect(tags.format, 'unknown');
    });

    test('随机字节：落回 mp3 默认格式，不抛', () async {
      final random = List<int>.generate(500, (i) => (i * 37) % 251);
      final tags = await readAudioTags(ByteSource.fromBytes(random));
      expect(tags.format, 'mp3');
    });

    test('ID3 声明 9MB 帧区：不抛、不越界读', () async {
      final file = bytes([
        fourcc('ID3'),
        [4, 0, 0],
        synchsafe(9000000),
        List<int>.filled(100, 0),
      ]);
      final tags = await readAudioTags(ByteSource.fromBytes(file));
      expect(tags.format, startsWith('id3v2'));
      expect(tags.title, isEmpty);
    });

    test('fLaC 块长度爆炸：format 已定，字段为空', () async {
      const file = [0x66, 0x4c, 0x61, 0x43, 0x04, 0xff, 0xff, 0xff];
      final tags = await readAudioTags(ByteSource.fromBytes(file));
      expect(tags.format, 'flac');
      expect(tags.title, isEmpty);
    });

    test('MP4 有 ftyp 无 moov：format=mp4，不抛', () async {
      final tags = await readAudioTags(
        ByteSource.fromBytes(mp4File(withMoov: false)),
      );
      expect(tags.format, 'mp4');
      expect(tags.hasAnyText, isFalse);
    });

    test('APIC mime 为空时靠魔数嗅探出 image/jpeg', () async {
      final jpeg = [0xff, 0xd8, 0xff, 0xe0, 9, 9, 9];
      final file = bytes([
        id3v2([apicFrame('', jpeg)], version: 3),
        ...mpegFrame(),
      ]);
      final tags = await readAudioTags(ByteSource.fromBytes(file));
      expect(tags.pictureMime, 'image/jpeg');
      expect(tags.picture, jpeg);
    });
  });

  test('ID3v2.4 标签后跟 9MB 长度字段：解析停在标签边界', () async {
    final file = bytes([
      id3v2([textFrame('TIT2', 'A', version: 4)], version: 4),
      ...u32be(9000000),
      ...mpegFrame(),
    ]);
    final tags = await readAudioTags(ByteSource.fromBytes(file));
    expect(tags.title, 'A');
    expect(tags.format, 'id3v2.4');
  });

  test('容器分派：fLaC / OggS / +4 的 ftyp / ID3 各归各类', () async {
    final flac = flacFile([
      metaBlock(0x00, streamInfo()),
      metaBlock(0x04, vorbisComment(['TITLE=夜曲'])),
    ]);
    final ogg = bytes([
      oggPacket(oggIdent(), bos: true),
      oggPacket(oggComment(['TITLE=大鱼'])),
    ]);
    final m4a = mp4File(
      withMoov: true,
      atoms: [mp4Box('${copyright}nam', [dataAtom(utf8.encode('稻香'))])],
    );
    final id3 = bytes([
      id3v2([textFrame('TIT2', '十年')]),
      ...mpegFrame(),
    ]);

    expect((await readAudioTags(ByteSource.fromBytes(flac))).format, 'flac');
    expect((await readAudioTags(ByteSource.fromBytes(ogg))).format, 'ogg');
    expect((await readAudioTags(ByteSource.fromBytes(m4a))).format, 'mp4');
    expect((await readAudioTags(ByteSource.fromBytes(id3))).format, 'id3v2.3');
  });

  test('ID3v2 只给曲名时用尾部 ID3v1 补歌手/专辑，format 仍是 id3v2.3', () async {
    final tail = bytes([
      fourcc('TAG'),
      latin1.encode('Yellow Submarine'.padRight(30)),
      latin1.encode('The Beatles'.padRight(30)),
      latin1.encode('Revolver'.padRight(30)),
      latin1.encode('1966'),
      List<int>.filled(31, 0),
    ]);
    final file = bytes([
      id3v2([textFrame('TIT2', 'Come Together')]),
      ...mpegFrame(),
      ...tail,
    ]);
    final tags = await readAudioTags(ByteSource.fromBytes(file));
    expect(tags.format, 'id3v2.3');
    expect(tags.title, 'Come Together');
    expect(tags.artist, 'The Beatles');
    expect(tags.album, 'Revolver');
  });

  group('mergeTaggedNames', () {
    test('标签齐全时忽略文件名', () {
      final names = mergeTaggedNames(
        TagResult(format: 'id3v2.3', title: '十年', artist: '陈奕迅'),
        '错的 - 名字',
      );
      expect(names.title, '十年');
      expect(names.artist, '陈奕迅');
      expect(names.usedTags, isTrue);
    });

    test('只有曲名标签时歌手从文件名补', () {
      final names = mergeTaggedNames(
        TagResult(format: 'id3v2.3', title: '十年'),
        '陈奕迅 - 十年',
      );
      expect(names.title, '十年');
      expect(names.artist, '陈奕迅');
    });

    test('albumArtist 兜 artist', () {
      final names = mergeTaggedNames(
        TagResult(format: 'flac', albumArtist: 'Radiohead'),
        'Creep',
      );
      expect(names.artist, 'Radiohead');
    });

    test('完全无标签退回文件名拆分（左歌手、右曲名）', () {
      final names = mergeTaggedNames(TagResult(format: 'mp3'), '陈奕迅 - 孤勇者');
      expect(names.title, '孤勇者');
      expect(names.artist, '陈奕迅');
      expect(names.usedTags, isFalse);
    });
  });

  test('splitArtistTitle 只在有一个分隔符时拆', () {
    expect(splitArtistTitle('陈奕迅 - 十年'), (artist: '陈奕迅', title: '十年'));
    expect(splitArtistTitle('十年'), (artist: '', title: '十年'));
    expect(splitArtistTitle('a - b - c'), (artist: 'a', title: 'b - c'));
  });
}
