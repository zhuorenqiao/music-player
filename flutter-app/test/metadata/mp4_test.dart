// test/metadata/mp4_test.dart
//
// 对译 React 版 tests/t-tags.mjs 的 m4a 族（5 条断言，t-tags.mjs:329-352）与
// 畸形输入的「MP4 有 ftyp 无 moov」（t-tags.mjs:384）。字节布局照搬 JS 夹具：
// `ftyp` + `moov.mvhd` + `moov.udta.meta(u32be 0).ilst`，`©` 是 latin-1 单字节。
//
// 两处结构性差异（Id3Tag 按 T7 裁定不含 `format` / `year`）：
//   * JS 的 `format: 'm4a'` 改钉 `version: 'mp4'`；
//   * JS 的 `©day → year` 在本移植不解析（见「aART / ©day」用例，只钉不抛）。
// 夹具的 covr 用 flags 14（PNG）：JS 夹具写 13 但原版忽略 flags，本移植按
// task-9 brief 的契约「13=JPEG / 14=PNG」，照抄 13 会解出 image/jpeg。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';
import 'package:light_music/metadata/mp4.dart';

import 'tag_fixtures.dart';

void main() {
  test('m4a：©nam / ©ART / ©alb / covr', () async {
    final file = mp4File(
      withMoov: true,
      atoms: [
        mp4Box('${copyright}nam', [dataAtom(utf8.encode('稻香'))]),
        mp4Box('${copyright}ART', [dataAtom(utf8.encode('周杰伦'))]),
        mp4Box('${copyright}alb', [dataAtom(utf8.encode('魔杰座'))]),
        mp4Box('covr', [dataAtom(pngBody(), flags: 14)]),
      ],
    );
    final tag = (await parseMp4Meta(ByteSource.fromBytes(file)))!;
    expect(tag.version, 'mp4'); // JS 的 format: 'm4a'
    expect(tag.title, '稻香');
    expect(tag.artist, '周杰伦');
    expect(tag.album, '魔杰座');
    expect(tag.pictureMime, 'image/png'); // JS 的 picture.type
    expect(tag.picture, pngBody());
  });

  test('ftyp 有 moov 无：返回 null，不抛', () async {
    final file = mp4File(withMoov: false);
    expect(await parseMp4Meta(ByteSource.fromBytes(file)), isNull);
  });

  test('covr：flags 不是 13/14 时按魔数嗅探', () async {
    final file = mp4File(
      withMoov: true,
      atoms: [
        mp4Box('${copyright}nam', [dataAtom(utf8.encode('稻香'))]),
        mp4Box('covr', [dataAtom(pngBody())]), // flags 默认 1
      ],
    );
    final tag = (await parseMp4Meta(ByteSource.fromBytes(file)))!;
    expect(tag.pictureMime, 'image/png');
    expect(tag.picture, pngBody());
  });

  test('covr：载荷不是图片时丢弃封面，文本字段照常返回', () async {
    final file = mp4File(
      withMoov: true,
      atoms: [
        mp4Box('${copyright}nam', [dataAtom(utf8.encode('稻香'))]),
        mp4Box('covr', [dataAtom(utf8.encode('not an image'))]),
      ],
    );
    final tag = (await parseMp4Meta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '稻香');
    expect(tag.picture, isNull);
    expect(tag.pictureMime, '');
  });

  test('aART 落 albumArtist；©day（原版 year）不解析也不抛', () async {
    final file = mp4File(
      withMoov: true,
      atoms: [
        mp4Box('aART', [dataAtom(utf8.encode('周杰伦'))]),
        mp4Box('${copyright}day', [dataAtom(utf8.encode('2008'))]),
      ],
    );
    final tag = (await parseMp4Meta(ByteSource.fromBytes(file)))!;
    expect(tag.albumArtist, '周杰伦');
    expect(tag.album, '');
    expect(tag.picture, isNull);
  });

  test('ilst 子 box 长度越界：停止扫描，已解析字段照常返回', () async {
    final file = mp4File(
      withMoov: true,
      atoms: [
        mp4Box('${copyright}nam', [dataAtom(utf8.encode('稻香'))]),
        // 声明 0xFFFF 字节，远超父容器剩余空间：整条链必须停下且不抛。
        [...u32be(0xffff), ...fourcc('${copyright}alb'), 1, 2, 3],
      ],
    );
    final tag = (await parseMp4Meta(ByteSource.fromBytes(file)))!;
    expect(tag.title, '稻香');
    expect(tag.album, '');
  });
}
