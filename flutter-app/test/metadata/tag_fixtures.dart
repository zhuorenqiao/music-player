// test/metadata/tag_fixtures.dart
//
// 内嵌标签（ID3v2 / ID3v1 / FLAC / OGG / MP4）用例共用的字节构造助手。
//
// 每个 helper 的语义逐字对齐 React 版 tests/t-tags.mjs 的同名函数（行号见
// .superpowers/sdd/2026-11-06-flutter-m1-core-playback/task-7-brief.md），
// 这样 Dart 侧造出的字节与 JS 侧完全一致，期望值可以直接照搬。
//
// 【后续 Task（8 / 9 / 10）约定】本文件只许**追加**新 helper，
// 不许改写已有 helper 的签名与字节布局 —— 已有用例的断言钉在这些字节上。
//
// 唯一例外（fix round 1）：`textFrame` / `apicFrame` / `rawTextFrame` 的
// `version: 2` 分支此前照抄 v2.3 的 9 字节帧头、并给 PIC 写了 mime + NUL，
// 与 ID3v2.2 规范和 `lib/metadata/id3.dart` 都不符（解析器读到 0 长度 → 整帧
// 丢弃），现已按规范修正。v2.3 / v2.4 分支的字节一个都没有动。
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

/// 拼接字节片段：`int` / `List<int>` / 能按 Latin-1 编码的 `String`。
List<int> bytes(List<Object> parts) => [
  for (final part in parts)
    ...switch (part) {
      final int b => [b],
      final List<int> list => list,
      final String text => latin1.encode(text),
      _ => throw ArgumentError('unsupported part: $part'),
    },
];

/// 大端 24 位：v2.2 的帧长度字段。
List<int> u24be(int v) => [(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

List<int> u32be(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

List<int> u32le(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

/// ID3v2 的 synchsafe 整数：每字节只用低 7 位。
List<int> synchsafe(int v) => [
  (v >> 21) & 0x7f,
  (v >> 14) & 0x7f,
  (v >> 7) & 0x7f,
  v & 0x7f,
];

List<int> fourcc(String s) => latin1.encode(s);

List<int> cstr(String s) => [...latin1.encode(s), 0];

const List<int> pngHeader = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// 与 JS 侧 `PNG` 常量同构：8 字节文件头 + 4 字节伪数据。
List<int> pngBody() => [...pngHeader, 1, 2, 3, 4];

/// ID3 之后的一小段「真实音频数据」（0xff 0xfb = MPEG-1 Layer III 帧头）。
List<int> mpegFrame() => [0xff, 0xfb, 0x90, 0x64, ...List<int>.filled(400, 0)];

/// ID3v2 文本帧。帧头随版本走（见 [_frame]）：v2.2 是 `TT2` 这类 3 字符 id +
/// 3 字节长度、**没有 flags**；v2.3 / v2.4 是 4 字符 id + 4 字节长度 + 2 字节
/// flags，长度在 v2.4 是 synchsafe。
List<int> textFrame(
  String id,
  String value, {
  int encoding = 3,
  int version = 3,
}) {
  final payload = [encoding, ..._textBytes(value, encoding)];
  return _frame(id, payload, version);
}

/// APIC / PIC 帧。
///
/// - v2.3 / v2.4（`APIC`）：encoding(1) + mime（NUL 结尾）+ 封面类型(1) +
///   描述（NUL 结尾）+ 图片。
/// - v2.2（`PIC`）：encoding(1) + **3 字符图片格式码**（`JPG` / `PNG`，定长
///   3 字节、**没有 NUL**）+ 封面类型(1) + 描述（NUL 结尾）+ 图片。
///
/// 格式码后面紧跟的是封面类型字节 —— 多写一个 NUL 会把封面类型读成 0
/// （ID3v2.2 规范的 PIC 布局，`lib/metadata/id3.dart` 与 JS 原版都按此解析）。
List<int> apicFrame(
  String mime,
  List<int> picture, {
  int coverType = 3,
  String description = '',
  int encoding = 3,
  int version = 3,
}) {
  final payload = version == 2
      ? <int>[
          encoding,
          ...latin1.encode(_v2ImageFormat(mime)),
          coverType,
          ..._textBytes(description, encoding),
          0,
          ...picture,
        ]
      : <int>[
          encoding,
          ...latin1.encode(mime),
          0,
          coverType,
          ..._textBytes(description, encoding),
          0,
          ...picture,
        ];
  return _frame(version == 2 ? 'PIC' : 'APIC', payload, version);
}

/// 10 字节标签头 + 帧区；`ID3` + 主版本 + 修订 0 + flags + synchsafe 长度。
List<int> id3v2(List<List<int>> frames, {int version = 3, int flags = 0}) {
  final body = [for (final frame in frames) ...frame];
  return [
    0x49,
    0x44,
    0x33,
    version,
    0,
    flags,
    ...synchsafe(body.length),
    ...body,
  ];
}

/// 文本帧的字节（不含 encoding 字节）：0 latin1 / 1 utf-16le+BOM / 2 utf-16be / 3 utf-8。
List<int> _textBytes(String value, int encoding) => switch (encoding) {
  0 => latin1.encode(value),
  1 => [0xff, 0xfe, ...utf16leBytes(value)],
  2 => utf16beBytes(value),
  _ => utf8.encode(value),
};

List<int> utf16leBytes(String s) => [
  for (final code in s.codeUnits) ...[code & 0xff, (code >> 8) & 0xff],
];

List<int> utf16beBytes(String s) => [
  for (final code in s.codeUnits) ...[(code >> 8) & 0xff, code & 0xff],
];

/// GBK 反查表：只为在测试里造出真实的 GBK 字节，不进产品代码。
///
/// 需要新字符时往这里追加，不要把已有条目改成别的东西。
final Map<String, List<int>> gbkTable = {
  for (final ch in '陈奕迅十年白玫瑰好久不见孤勇者夜曲周杰伦十一月的萧邦'.split('')) ch: gbk.encode(ch),
};

/// 把字符串转成 GBK 字节（字符必须在 [gbkTable] 里）。
List<int> gbkText(String text) => [
  for (final ch in text.split('')) ...gbkTable[ch]!,
];

/// 指定编码字节的文本帧：用于「声明与字节不符」的样本（encoding 位照写，字节自己给）。
List<int> rawTextFrame(
  String id,
  List<int> payload, {
  int encodingByte = 0,
  int version = 3,
}) => _frame(id, [encodingByte, ...payload], version);

/// 帧头 + 载荷，按版本选布局：
/// - v2.2：id(3) + 长度(3, 大端) + **没有标志位** —— 帧头共 6 字节；
/// - v2.3：id(4) + 长度(4, 大端) + flags(2)；
/// - v2.4：同 v2.3，但长度是 synchsafe。
List<int> _frame(String id, List<int> payload, int version) {
  if (version == 2) {
    if (id.length != 3) {
      throw ArgumentError('v2.2 的帧 id 必须是 3 个字符：$id');
    }
    return [...fourcc(id), ...u24be(payload.length), ...payload];
  }
  final size = version == 4 ? synchsafe(payload.length) : u32be(payload.length);
  return [...fourcc(id), ...size, 0, 0, ...payload];
}

/// mime → v2.2 PIC 的 3 字符图片格式码（定长、无 NUL 结尾）。
String _v2ImageFormat(String mime) {
  final lower = mime.toLowerCase();
  if (lower.endsWith('png')) return 'PNG';
  if (lower.endsWith('jpg') || lower.endsWith('jpeg')) return 'JPG';
  throw ArgumentError('v2.2 的 PIC 只有 PNG / JPG 两种格式码：$mime');
}

/// ID3v1 的定长字段：定长**字节**（NUL 填充），不是定长字符。
List<int> v1Field(String text, int width) {
  final encoded = gbk.encode(text);
  return [...encoded, ...List<int>.filled(width - encoded.length, 0)];
}

/// 同上，但字节由调用方给（用于把 API 钉住的字面量与断言对齐）。
List<int> v1FieldBytes(List<int> raw, [int width = 30]) => [
  ...raw,
  ...List<int>.filled(width - raw.length, 0),
];

// ---------------------------------------------------------------------------
// FLAC / OGG（Task 8 追加，语义对齐 JS 的 vorbisComment / flacPictureBlock /
// metaBlock / streaminfo / flacFile / oggPacket / oggIdent / oggComment）
// ---------------------------------------------------------------------------

/// Vorbis Comment 块内容：`vendor 长度 + vendor + 条目数 + 每条[长度 + 字节]`。
///
/// JS 侧 vendor 与条目都按 UTF-8（`TextEncoder`）写，这里同样默认 UTF-8；
/// GBK 样本（非标准但真实存在）自己给字节，所以 [entries] 也接受 `List<int>`。
List<int> vorbisComment(
  List<Object> entries, {
  String vendor = 'test-tagging',
}) {
  final vendorBytes = utf8.encode(vendor);
  final body = <int>[...u32le(vendorBytes.length), ...vendorBytes];
  body.addAll(u32le(entries.length));
  for (final entry in entries) {
    final raw = entry is String ? utf8.encode(entry) : entry as List<int>;
    body.addAll(u32le(raw.length));
    body.addAll(raw);
  }
  return body;
}

/// FLAC PICTURE 块内容：type + mime + description + 宽/高/位深/调色板数 + 数据。
///
/// 宽高与位深照抄 JS 夹具（120 / 120 / 24 / 0），解析器不看这些值。
List<int> flacPictureBlock(
  String mime,
  List<int> picture, {
  String description = '',
}) {
  final mimeBytes = latin1.encode(mime);
  final descBytes = latin1.encode(description);
  return [
    ...u32be(3), // 封面类型 3 = 正面封面
    ...u32be(mimeBytes.length),
    ...mimeBytes,
    ...u32be(descBytes.length),
    ...descBytes,
    ...u32be(120),
    ...u32be(120),
    ...u32be(24),
    ...u32be(0),
    ...u32be(picture.length),
    ...picture,
  ];
}

/// FLAC 元数据块：1 字节（type）+ 3 字节大端长度 + 内容。
///
/// last-flag（0x80）不在这里写，交给 [flacFile] 给最后一块补 —— 与 JS 夹具
/// `metaBlock(0x86 / 0x84, …)` 造出的字节一致。
List<int> metaBlock(int type, List<int> content) => [
  type,
  ...u32be(content.length).sublist(1),
  ...content,
];

/// STREAMINFO 34 字节全 0：解析器只按长度跳过，内容无关。
List<int> streamInfo() => List<int>.filled(34, 0);

/// FLAC 文件：`fLaC` 魔数 + 块链（最后一块打 last-flag）+ 64 字节音频区。
List<int> flacFile(List<List<int>> blocks) => [
  ...fourcc('fLaC'),
  for (var i = 0; i < blocks.length; i += 1) ...[
    blocks[i][0] | (i == blocks.length - 1 ? 0x80 : 0),
    ...blocks[i].sublist(1),
  ],
  ...List<int>.filled(64, 0),
];

/// Ogg 页：27 字节页头 + 段表 + 负载。
///
/// 段表照抄 JS 夹具：只写一个 `payload.length ~/ 255` 的条目（小于 255 字节
/// 的报文就是 0），页头其余字段一律 0（serial 0、序号 1）。原版解析器根本不
/// 看页头，是直接扫 `0x03 'vorbis'` 魔数，所以这里以「字节与 JS 一致」为准。
List<int> oggPacket(
  List<int> payload, {
  int granule = 0,
  int serial = 0,
  int seq = 1,
  bool bos = false,
}) => [
  ...fourcc('OggS'),
  0,
  bos ? 0x02 : 0x00,
  ...u32le(granule), // granule 低 32 位
  ...u32le(0), // granule 高 32 位
  ...u32le(serial),
  ...u32le(seq),
  ...List<int>.filled(4, 0), // 校验和（原版不校验）
  (payload.length ~/ 255) & 0xff,
  ...payload,
];

/// Vorbis identification 报文：`0x01 'vorbis'` + 40 字节版本/声道/采样率区。
List<int> oggIdent() => [0x01, ...fourcc('vorbis'), ...List<int>.filled(40, 0)];

/// Vorbis comment 报文：`0x03 'vorbis'` + Vorbis Comment。
///
/// [base64Pictures] 里的每一项都会追加成一条 `METADATA_BLOCK_PICTURE=<base64>`
/// （OGG 的封面约定，值是 base64 的 FLAC PICTURE 块）。
List<int> oggComment(
  List<String> entries, {
  List<String> base64Pictures = const [],
}) => [
  0x03,
  ...fourcc('vorbis'),
  ...vorbisComment([
    ...entries,
    for (final picture in base64Pictures) 'METADATA_BLOCK_PICTURE=$picture',
  ]),
];

// ---------------------------------------------------------------------------
// MP4 / M4A（Task 9 追加，语义对齐 JS 的 mp4Box / dataAtom / m4a）
// ---------------------------------------------------------------------------

/// iTunes 的版权符：latin-1 单字节 `0xA9`。
///
/// 用 UTF-8 写会变成两字节 `0xC2 0xA9`，box 名就对不上了 —— JS 侧同样用
/// `latin1('©nam')` 造字节。
const String copyright = '\u00A9';

/// MP4 box：`长度(大端) + 4 字符类型 + 内容`。[type] 按 Latin-1 编码，
/// 所以 `'${copyright}nam'` 造出来的就是 `0xA9 'n' 'a' 'm'`。
List<int> mp4Box(String type, List<List<int>> parts) {
  final body = [for (final part in parts) ...part];
  return [...u32be(body.length + 8), ...latin1.encode(type), ...body];
}

/// `data` 子 box：`长度 + 'data' + version/flags(4) + locale(4) + 载荷`。
///
/// [flags] 写进整个 4 字节字段（高 8 位名义上是 version，夹具一律 0），
/// 与 JS 的 `u32be(flags)` 字节一致。13 = JPEG、14 = PNG。
List<int> dataAtom(List<int> payload, {int flags = 1}) => [
  ...u32be(payload.length + 16),
  ...fourcc('data'),
  ...u32be(flags),
  ...u32be(0),
  ...payload,
];

/// ilst 容器：条目列表（每个条目本身是一个 box）。
List<int> ilst(List<List<int>> atoms) => mp4Box('ilst', atoms);

/// M4A 文件：`ftyp` + 可选 `moov.mvhd / moov.udta.meta(u32be 0).ilst` + 音频字节。
///
/// `mvhd` 是 udta 之前的兄弟 box（对齐 JS 夹具），用来钉住「按长度跳过无关
/// box」；`meta` 里的 4 字节是 version/flags 占位，真正的子 box 从第 12 字节起。
List<int> mp4File({
  required bool withMoov,
  List<List<int>> atoms = const [],
}) => [
  ...mp4Box('ftyp', [
    [...latin1.encode('M4A '), ...u32be(0), ...latin1.encode('M4A ')],
  ]),
  if (withMoov)
    ...mp4Box('moov', [
      mp4Box('mvhd', [List<int>.filled(100, 0)]),
      mp4Box('udta', [
        mp4Box('meta', [u32be(0), ilst(atoms)]),
      ]),
    ]),
  ...mpegFrame(),
];
