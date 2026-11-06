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

/// ID3v2 文本帧：帧头 = id(4) + 长度(4) + flags(2)，长度在 v2.4 是 synchsafe。
List<int> textFrame(
  String id,
  String value, {
  int encoding = 3,
  int version = 3,
}) {
  final payload = [encoding, ..._textBytes(value, encoding)];
  final size = version == 4 ? synchsafe(payload.length) : u32be(payload.length);
  return [...fourcc(id), ...size, 0, 0, ...payload];
}

/// APIC 帧（v2.3 / v2.4 布局；v2.2 用 3 字符格式码而不是 mime 字符串）。
List<int> apicFrame(
  String mime,
  List<int> picture, {
  int coverType = 3,
  String description = '',
  int encoding = 3,
  int version = 3,
}) {
  final payload = <int>[
    encoding,
    ...latin1.encode(mime),
    0,
    coverType,
    ..._textBytes(description, encoding),
    0,
    ...picture,
  ];
  final size = version == 4 ? synchsafe(payload.length) : u32be(payload.length);
  return [...fourcc(version == 2 ? 'PIC' : 'APIC'), ...size, 0, 0, ...payload];
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
}) {
  final body = [encodingByte, ...payload];
  final size = version == 4 ? synchsafe(body.length) : u32be(body.length);
  return [...fourcc(id), ...size, 0, 0, ...body];
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
