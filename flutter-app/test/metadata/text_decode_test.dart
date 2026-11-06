// test/metadata/text_decode_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/text_decode.dart';

// 下面这些字节是离线用 fast_gbk / 码点算出来后固化进用例的常量，
// 测试运行时不再调用同一个库去生成 fixture（否则嗅探用例等于自证。
// 生成方式与原始字节见 test/fixtures/README.md）。

/// GBK 的 `好久不见`（8 字节，全部 >= 0x80，构成连续高位字节串）。
const List<int> gbkHaoJiuBuJian = [
  0xba, 0xc3, 0xbe, 0xc3, 0xb2, 0xbb, 0xbc, 0xfb, //
];

/// `十年` = U+5341 U+5E74。
/// UTF-16LE 带 BOM：0xff 0xfe 后跟 0x41 0x53（U+5341）、0x74 0x5e（U+5E74）。
const List<int> utf16leShiNian = [0xff, 0xfe, 0x41, 0x53, 0x74, 0x5e];

/// 同一个 `十年` 的 UTF-16BE（无 BOM）：0x53 0x41、0x5e 0x74。
const List<int> utf16beShiNian = [0x53, 0x41, 0x5e, 0x74];

void main() {
  test('ID3 四种编码', () {
    expect(decodeId3Text(latin1.encode('Abbe'), 0), 'Abbe');
    // encoding=1：BOM 决定字节序
    expect(decodeId3Text(utf16leShiNian, 1), '十年');
    expect(decodeId3Text([0xfe, 0xff, ...utf16beShiNian], 1), '十年');
    // encoding=2：UTF-16BE，无 BOM
    expect(decodeId3Text(utf16beShiNian, 2), '十年');
    expect(decodeId3Text(utf8.encode('十年'), 3), '十年');
    // encoding=0 不盲信声明：GBK 字节照样要嗅探成中文
    expect(decodeId3Text(gbkHaoJiuBuJian, 0), '好久不见');
  });

  test('纯 ASCII 走最快路径', () {
    expect(decodeLegacyText(latin1.encode('Hello')), 'Hello');
  });

  test('合法 UTF-8 优先于 GBK', () {
    final utf8Bytes = utf8.encode('白玫瑰');
    expect(decodeLegacyText(utf8Bytes), '白玫瑰');
    // 同一串字符的 GBK 形式（0xb0 0xd7 ...）本身也是合法 GBK 双字节串，
    // 但它不是合法 UTF-8，所以会走 GBK 分支而不是被 UTF-8 抢走。
    expect(decodeLegacyText([0xb0, 0xd7, 0xc3, 0xb5, 0xb9, 0xe5]), '白玫瑰');
  });

  test('GBK 连续高位字节被识别且不乱码', () {
    expect(decodeLegacyText(gbkHaoJiuBuJian), '好久不见');
  });

  test('既非 UTF-8 也非可信 GBK 时退回 Latin-1，不抛', () {
    final result = decodeLegacyText([0xff, 0xfe, 0x41]);
    expect(result, 'ÿþA');
    expect(result.contains('\uFFFD'), isFalse);
    // 孤立的西文重音字母没有「连续高位字节」特征，不能被当成 GBK。
    expect(decodeLegacyText(latin1.encode('Motörhead')), 'Motörhead');
  });

  test('终止符之后的字节不参与解码', () {
    expect(
      decodeId3Text([...latin1.encode('A'), 0x00, ...latin1.encode('B')], 0),
      'A',
    );
    // UTF-8 也在首个单字节 NUL 处截断
    expect(decodeId3Text([0x41, 0x00, 0x42], 3), 'A');
    // UTF-16 只在 2 字节边界上认双 NUL
    expect(decodeId3Text([0xff, 0xfe, 0x41, 0x00, 0x00, 0x00], 1), 'A');
  });

  test('图片魔数嗅探', () {
    expect(sniffImageMime([0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg');
    expect(
      sniffImageMime([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      'image/png',
    );
    expect(sniffImageMime([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), 'image/gif');
    expect(
      sniffImageMime([
        0x52,
        0x49,
        0x46,
        0x46,
        0,
        0,
        0,
        0,
        0x57,
        0x45,
        0x42,
        0x50,
      ]),
      'image/webp',
    );
    expect(sniffImageMime([1, 2, 3, 4]), '');
    expect(sniffImageMime(const []), '');
    // RIFF 但不是 WEBP（例如 WAV）不算图片
    expect(
      sniffImageMime([
        0x52,
        0x49,
        0x46,
        0x46,
        0,
        0,
        0,
        0,
        0x57,
        0x41,
        0x56,
        0x45,
      ]),
      '',
    );
  });

  test('严格 UTF-8 与连续高位字节判定', () {
    expect(canDecodeStrictlyUtf8(utf8.encode('十年')), isTrue);
    expect(canDecodeStrictlyUtf8(latin1.encode('Hello')), isTrue);
    expect(canDecodeStrictlyUtf8(gbkHaoJiuBuJian), isFalse);
    expect(hasHighByteRun(gbkHaoJiuBuJian), isTrue);
    expect(hasHighByteRun(latin1.encode('Motörhead')), isFalse);
    expect(hasHighByteRun(latin1.encode('Hello')), isFalse);
    expect(hasHighByteRun(const []), isFalse);
  });
}
