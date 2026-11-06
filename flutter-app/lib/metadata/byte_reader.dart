// lib/metadata/byte_reader.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 只读需要的字节：文件源带 8MB 上限，任何越界读取都返回可用部分或空。
///
/// 对应 React 版 src/lib/audio-tags.js 的 `readSlice` 契约 —— 那里的注释写明
/// 「只读需要的那段字节（头部 64KB 判断格式，标签区按需再读），不会把整首歌
/// 读进内存。全部接口不抛异常」。本类同样只在被要求时读取：
///
/// * 首次读取文件时把开头 [headProbeBytes]（64KB）缓存下来，后续在窗口内的
///   小读取都不再开文件句柄 —— 判格式、扫帧头正是这种「大量小读取」；
/// * 窗口之外的读取走真正的偏移读取，但**单次读取长度不超过 [maxBytes]**，防止
///   畸形标签里的超大长度把内存吃光。上限约束的是「一次读多少」而不是「从哪儿读」
///   —— 原版 `readSlice` 就是这个语义（尾部标签用 `file.size - tailSize` 起读），
///   否则大于上限的文件连末尾 128 字节的 ID3v1 都读不到；
/// * 越界、负数、文件不存在、句柄打开失败，统统退化成「空 / 可用前缀」，绝不抛出，
///   也绝不返回 null —— 调用方拿到的一定是可迭代的字节。
class ByteSource {
  ByteSource._(this._bytes, this._path, int maxBytes)
    : _maxBytes = maxBytes < 0 ? 0 : maxBytes {
    final bytes = _bytes;
    if (bytes != null) {
      _length = bytes.length;
    }
  }

  /// 内存源：不设上限（调用方已经把字节读进来了）。
  factory ByteSource.fromBytes(List<int> bytes) =>
      ByteSource._(Uint8List.fromList(bytes), null, defaultMaxBytes);

  /// 文件源：读取量上限 [maxBytes]（默认 8MB）。
  factory ByteSource.fromFile(String path, {int maxBytes = defaultMaxBytes}) =>
      ByteSource._(null, path, maxBytes);

  /// 标签区（含内嵌封面）最多读这么多，与原版 `MAX_TAG_BYTES` 对齐。
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  /// 判断格式时先读的字节数，与原版 `PROBE_BYTES` 对齐。
  static const int headProbeBytes = 64 * 1024;

  final Uint8List? _bytes;
  final String? _path;
  final int _maxBytes;

  int? _length;
  Uint8List? _head;

  /// 数据总长度。文件源报告**文件真实大小**（不是被上限截断的长度），
  /// 好让调用方能据此算「末尾 128 字节」这类偏移；[maxBytes] 只限制单次读取量，
  /// 所以任意偏移都读得到，超长区间由调用方分段读。
  int get length {
    final cached = _length;
    if (cached != null) return cached;
    try {
      return _length = File(_path!).lengthSync();
    } catch (_) {
      // 文件不存在 / 无权限：按空文件处理。
      return _length = 0;
    }
  }

  /// 读 [count] 字节；不够就只给可用的前缀。
  ///
  /// 越界（偏移 >= 长度）、负数偏移、非正长度都返回空列表，不抛。
  /// 文件源的**单次读取长度**还会被 [maxBytes] 截断：只要偏移在文件内，从任何
  /// 位置（含末尾）起读都可行，但一次最多给 [maxBytes] 字节。
  Future<List<int>> read(int offset, int count) async {
    if (count <= 0 || offset < 0) return Uint8List(0);
    final total = length;
    if (offset >= total) return Uint8List(0);
    var want = offset + count > total ? total - offset : count;
    final bytes = _bytes;
    if (bytes != null) return bytes.sublist(offset, offset + want);

    // 上限只约束「这一次读多少」，不约束起点：大文件的尾部（ID3v1、尾部 moov）
    // 同样可达，与原版 `readSlice(file, Math.max(0, size - 128), 128)` 一致。
    if (want > _maxBytes) want = _maxBytes;
    final head = await _headBytes();
    // 命中 64KB 头窗口就不开文件句柄；返回副本，避免调用方改写缓存。
    if (offset + want <= head.length) {
      return head.sublist(offset, offset + want);
    }
    return _readRange(offset, want);
  }

  /// 读末尾 [count] 字节（ID3v1 的 128 字节尾巴靠它）。文件比 [count] 短就取整段；
  /// 一次最多给 [maxBytes] 字节（与 [read] 的上限一致）。
  Future<List<int>> readTail(int count) async {
    if (count <= 0) return Uint8List(0);
    final total = length;
    if (total == 0) return Uint8List(0);
    final take = count > total ? total : count;
    return read(total - take, take);
  }

  /// [offset] 处是否是指定字节序列。越界一律 false。
  Future<bool> matches(int offset, List<int> signature) async {
    if (offset < 0 || offset + signature.length > length) return false;
    if (signature.isEmpty) return true;
    final bytes = await read(offset, signature.length);
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i += 1) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  /// 按 ASCII 比较某段字节（MP4 的 fourcc 都用这个）。
  ///
  /// 非 Latin-1 字符直接判 false：fourcc 本来就是 ASCII，宁可判不匹配也不抛。
  Future<bool> matchesText(int offset, String text) async {
    final signature = _encodeLatin1(text);
    if (signature == null) return false;
    return matches(offset, signature);
  }

  Future<int> u32be(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  }

  Future<int> u32le(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }

  /// ID3v2.4 的 synchsafe 整数：每字节只保留低 7 位（与原版 `readSynchsafe` 一致）。
  Future<int> synchsafe(int offset) async {
    final b = await read(offset, 4);
    if (b.length < 4) return 0;
    return ((b[0] & 0x7f) << 21) |
        ((b[1] & 0x7f) << 14) |
        ((b[2] & 0x7f) << 7) |
        (b[3] & 0x7f);
  }

  /// 懒惰加载的 64KB 头窗口：同样受 [maxBytes] 约束。
  Future<Uint8List> _headBytes() async {
    final cached = _head;
    if (cached != null) return cached;
    final total = length;
    var size = total < headProbeBytes ? total : headProbeBytes;
    if (size > _maxBytes) size = _maxBytes;
    final head = size <= 0 ? Uint8List(0) : await _readRange(0, size);
    return _head = head;
  }

  /// 真正的偏移读取：打开 → 定位 → 读 → 关闭；任何一步失败都返回空。
  Future<Uint8List> _readRange(int offset, int count) async {
    RandomAccessFile? handle;
    try {
      handle = await File(_path!).open();
      await handle.setPosition(offset);
      return await handle.read(count);
    } catch (_) {
      return Uint8List(0);
    } finally {
      try {
        await handle?.close();
      } catch (_) {
        // 关闭失败不影响本次读取结果。
      }
    }
  }
}

/// Latin-1 编码（非 Latin-1 字符返回 null，由调用方判不匹配）。
List<int>? _encodeLatin1(String text) {
  try {
    return latin1.encode(text);
  } catch (_) {
    return null;
  }
}
