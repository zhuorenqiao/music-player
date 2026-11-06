// lib/metadata/text_decode.dart
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

/// 内嵌标签的文本解码：不盲信声明的编码，按内容嗅探。
///
/// 对应 React 版 src/lib/audio-tags.js 的 `decodeText` / `canDecodeStrictly` /
/// `hasHighByteRun` / `decodeLegacyText` / `decodeId3Text` / `sniffImageMime`。
/// 背景（README「元数据与内嵌标签解析的边界」）：中文音频文件的标签大量
/// 不符合规范 —— ID3v1 压根没有编码位，老工具一律按 GBK 写；ID3v2 的
/// encoding=0（名义 ISO-8859-1）有的工具塞 GBK，有的塞 UTF-8。盲信声明就会
/// 解出「Ò¹Çú」「å¤œæ›²」这类乱码。
///
/// 本文件所有函数都不抛异常，也绝不产出 U+FFFD：解不出来就退到 Latin-1。

/// 遇到首个终止符即截断：单字节编码认 `0x00`，UTF-16 认 2 字节边界上的
/// `0x00 0x00`。
///
/// UTF-16 必须是**成对**扫描：`0x41 0x00 0x5e 0x00` 里没有终止符，
/// 若按单字节找 0 会把 `0x41 0x00` 之后的全部内容误删。
List<int> _cutAtTerminator(List<int> bytes, {required bool wide}) {
  if (wide) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return bytes.sublist(0, i);
    }
    return bytes;
  }
  final at = bytes.indexOf(0);
  return at < 0 ? bytes : bytes.sublist(0, at);
}

/// 字节能否按 UTF-8 **严格**解开（遇到非法序列直接判 false）。
bool canDecodeStrictlyUtf8(List<int> bytes) {
  try {
    // utf8.decode 默认 allowMalformed = false，非法序列抛 FormatException。
    utf8.decode(bytes);
    return true;
  } catch (_) {
    return false;
  }
}

/// 是否出现「连续两个以上高位字节」。
///
/// GBK 的汉字 / 全角符号都是双字节且两字节都 >= 0x80，成串出现；
/// 真正的西文 Latin-1（Motörhead、Café）重音字母是孤立的，
/// 用这个特征把「恰好也是合法 GBK 的拉丁文」挡在 GBK 之外。
bool hasHighByteRun(List<int> bytes) {
  var run = 0;
  for (final byte in bytes) {
    if (byte >= 0x80) {
      run += 1;
      if (run >= 2) return true;
    } else {
      run = 0;
    }
  }
  return false;
}

/// 按帧的 encoding 字节解文本（0 latin1 / 1 utf-16 带 BOM / 2 utf-16be / 3 utf-8）。
///
/// 只处理 BMP：标签文本实际都在 BMP 内，与原版一样不拼代理对。
String decodeId3Text(List<int> bytes, int encoding) {
  switch (encoding) {
    case 1:
      // 带 BOM 的 UTF-16；没有 BOM 时按 UTF-16LE 猜（写标签的工具绝大多数用 LE）。
      if (_matchAt(bytes, 0, _bomLe)) {
        return _utf16le(_cutAtTerminator(bytes.sublist(2), wide: true));
      }
      if (_matchAt(bytes, 0, _bomBe)) {
        return _utf16be(_cutAtTerminator(bytes.sublist(2), wide: true));
      }
      return _utf16le(_cutAtTerminator(bytes, wide: true));
    case 2:
      return _utf16be(_cutAtTerminator(bytes, wide: true));
    case 3:
      final body = _cutAtTerminator(bytes, wide: false);
      return canDecodeStrictlyUtf8(body) ? utf8.decode(body) : _latin1(body);
    default:
      // encoding=0 名义上是 ISO-8859-1，但中文文件常被塞 GBK / UTF-8：
      // 与原版一致，交给嗅探而不是盲信声明。未知编码号同样走这条。
      return decodeLegacyText(bytes);
  }
}

/// 解码「编码声明不可信」的文本：ASCII → UTF-8 严格 → GBK（连续高位字节）
/// → Latin-1 兜底。never throws，也绝不返回 U+FFFD。
String decodeLegacyText(List<int> bytes) {
  final body = _cutAtTerminator(bytes, wide: false);
  if (body.isEmpty) return '';
  // 全 ASCII 是最常见的情况，先用最快路径出去。
  if (body.every((byte) => byte < 0x80)) return ascii.decode(body);
  // UTF-8 BOM 说明作者确实按 UTF-8 写，剥掉 BOM 再解（与原版一致）。
  if (body.length >= 3 &&
      body[0] == 0xef &&
      body[1] == 0xbb &&
      body[2] == 0xbf) {
    final stripped = body.sublist(3);
    return canDecodeStrictlyUtf8(stripped)
        ? utf8.decode(stripped)
        : _latin1(stripped);
  }
  if (canDecodeStrictlyUtf8(body)) return utf8.decode(body);
  if (hasHighByteRun(body)) {
    try {
      // gbk.decode 默认 allowMalformed = false：不合法就抛，交给 Latin-1 兜底。
      final decoded = gbk.decode(body);
      if (decoded.isNotEmpty && !decoded.contains('\uFFFD')) return decoded;
    } catch (_) {
      // 不是可信 GBK：落到 Latin-1。
    }
  }
  return _latin1(body);
}

/// 按魔数识别图片类型（有些文件的 APIC mime 写错或留空）。
///
/// 认不出返回空串 —— 与原版返回 null 等价，调用方判空即可。
String sniffImageMime(List<int> bytes) {
  if (_matchAt(bytes, 0, _pngMagic)) return 'image/png';
  if (_matchAt(bytes, 0, _jpegMagic)) return 'image/jpeg';
  if (_matchAt(bytes, 0, _gifMagic)) return 'image/gif';
  if (_matchAt(bytes, 0, _riffMagic) && _matchAt(bytes, 8, _webpForm)) {
    return 'image/webp';
  }
  return '';
}

const List<int> _bomLe = [0xff, 0xfe];
const List<int> _bomBe = [0xfe, 0xff];
const List<int> _pngMagic = [0x89, 0x50, 0x4e, 0x47];
const List<int> _jpegMagic = [0xff, 0xd8, 0xff];
const List<int> _gifMagic = [0x47, 0x49, 0x46, 0x38];
const List<int> _riffMagic = [0x52, 0x49, 0x46, 0x46];
const List<int> _webpForm = [0x57, 0x45, 0x42, 0x50];

/// Latin-1 兜底：0x00-0xff 一对一映射，任何字节都能出字符。
String _latin1(List<int> bytes) {
  try {
    return latin1.decode(bytes);
  } catch (_) {
    // 0x100 以上的非法值不该出现；真出现了也不抛，按低 8 位截断。
    return String.fromCharCodes(bytes.map((byte) => byte & 0xff));
  }
}

/// 判断 [offset] 处是否是指定字节序列，越界一律 false（对齐原版 `matchAt`）。
bool _matchAt(List<int> bytes, int offset, List<int> signature) {
  if (offset < 0 || offset + signature.length > bytes.length) return false;
  for (var i = 0; i < signature.length; i += 1) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

String _utf16le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

String _utf16be(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}
