// test/metadata/byte_reader_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/byte_reader.dart';

/// 测试用的临时文件放在 test/ 下，用例结束即删，不留在工作区。
Future<File> _tempFile(String name, List<int> bytes) async {
  final file = File('test/.tmp-$name.bin');
  await file.writeAsBytes(bytes);
  addTearDown(() async {
    if (await file.exists()) await file.delete();
  });
  return file;
}

void main() {
  test('签名字节比对', () async {
    final src = ByteSource.fromBytes([0x49, 0x44, 0x33, 0x03]);
    expect(await src.matches(0, [0x49, 0x44, 0x33]), isTrue);
    expect(await src.matches(1, [0x49, 0x44, 0x33]), isFalse);
    expect(await src.matchesText(0, 'ID3'), isTrue);
    // 签名超出可用字节时按不匹配处理，不抛。
    expect(await src.matches(2, [0x33, 0x03, 0x00]), isFalse);
    expect(await src.matches(-1, [0x49]), isFalse);
  });

  test('三种长度读法', () async {
    final src = ByteSource.fromBytes([
      0x00, 0x00, 0x01, 0x02, // u32be = 258
      0x00, 0x00, 0x00, 0x12, // u32le = 0x12000000
      0x12, 0x00, 0x00, 0x00, // u32le = 0x12
      0x00, 0x00, 0x02, 0x01, // synchsafe = 0x101
      0xff, 0xff, 0xff, 0xff, // u32be = 0xffffffff（无符号）
      0xff, 0xff, 0xff, 0x7f, // synchsafe 每字节只留 7 位 = 0x0fffffff
    ]);
    expect(await src.u32be(0), 258);
    expect(await src.u32le(4), 0x12000000);
    expect(await src.u32le(8), 0x12);
    expect(await src.synchsafe(12), 0x101);
    expect(await src.u32be(16), 0xffffffff);
    expect(await src.synchsafe(20), 0x0fffffff);
    // 高位被掩掉：0x80 只算低 7 位 0。
    expect(
      await ByteSource.fromBytes([0x00, 0x00, 0x00, 0x80]).synchsafe(0),
      0,
    );
  });

  test('越界不抛，只给可用部分', () async {
    final src = ByteSource.fromBytes([1, 2, 3]);
    expect(await src.read(2, 100), [3]);
    expect(await src.read(99, 4), isEmpty);
    expect(await src.read(-1, 4), isEmpty);
    expect(await src.read(0, 0), isEmpty);
    expect(await src.u32be(2), 0);
    expect(await src.readTail(2), [2, 3]);
    expect(await src.readTail(99), [1, 2, 3]);
    expect(await src.readTail(0), isEmpty);
    expect(await src.matches(2, [1, 2, 3]), isFalse);
  });

  test('文件源只读需要的那段', () async {
    final file = await _tempFile('bytes', 'hello'.codeUnits);
    final src = ByteSource.fromFile(file.path);
    expect(src.length, 5);
    expect(await src.read(0, 2), [0x68, 0x65]);
    expect(await src.read(3, 100), [0x6c, 0x6f]);
    expect(await src.readTail(2), [0x6c, 0x6f]);
    expect(await src.matchesText(0, 'he'), isTrue);
  });

  test('文件源只限制单次读取长度，不限制起点', () async {
    final file = await _tempFile('capped', List<int>.generate(9, (i) => i + 1));
    final src = ByteSource.fromFile(file.path, maxBytes: 4);
    // 长度按文件真实大小如实报告，读取才受上限约束。
    expect(src.length, 9);
    // 请求长度超过上限时截断到 maxBytes。
    expect(await src.read(0, 10), [1, 2, 3, 4]);
    // 起点超过上限也照读：旧实现按 offset 截断，这里只会给 2 字节。
    expect(await src.read(2, 4), [3, 4, 5, 6]);
    // 越界（偏移 >= 长度）返回空。
    expect(await src.read(9, 2), isEmpty);
    expect(await src.read(99, 4), isEmpty);
    // 尾部在 offset > maxBytes 处：旧实现返回空，ID3v1 因此丢失。
    expect(await src.readTail(2), [8, 9]);
    // 超出 EOF 只给可用前缀。
    expect(await src.read(7, 100), [8, 9]);
  });

  test('超过 8MB 的文件仍能读到末尾标记', () async {
    // 9MB 零字节，末尾 4 字节写 'TAG!'：旧实现把上限套在偏移上，
    // readTail(4) 会返回空，ID3v1 与尾部 moov 的 MP4 因此静默丢失。
    const marker = [0x54, 0x41, 0x47, 0x21];
    const size = 9 * 1024 * 1024;
    final file = File('test/.tmp-large.bin');
    final handle = file.openSync(mode: FileMode.write);
    try {
      handle.writeFromSync(Uint8List(size - marker.length));
      handle.writeFromSync(Uint8List.fromList(marker));
    } finally {
      handle.closeSync();
    }
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final src = ByteSource.fromFile(file.path);
    expect(src.length, size);
    expect(await src.readTail(marker.length), marker);
  });

  test('文件不存在时长度 0、读取不抛', () async {
    final src = ByteSource.fromFile(
      'test/.tmp-missing-${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    expect(src.length, 0);
    expect(await src.read(0, 16), isEmpty);
    expect(await src.readTail(16), isEmpty);
    expect(await src.u32be(0), 0);
    expect(await src.matchesText(0, 'ID3'), isFalse);
  });

  test('64KB 头窗口内外的读取都正确', () async {
    final raw = List<int>.generate(70 * 1024, (i) => i & 0xff);
    final file = await _tempFile('head', raw);
    final src = ByteSource.fromFile(file.path);
    expect(src.length, 70 * 1024);
    // 完全落在 64KB 头窗口内
    expect(await src.read(0, 4), [0x00, 0x01, 0x02, 0x03]);
    // 跨越窗口边界：65536 起要落到真实文件读取
    expect(await src.read(65534, 4), [0xfe, 0xff, 0x00, 0x01]);
    // 窗口之后的尾部
    expect(await src.read(70 * 1024 - 2, 8), [0xfe, 0xff]);
  });
}
