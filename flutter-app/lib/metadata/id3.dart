// lib/metadata/id3.dart
import 'dart:typed_data';

import 'byte_reader.dart';
import 'text_decode.dart';

/// 对译 React 版 src/lib/audio-tags.js 的 ID3 部分：
/// `parseId3v2Frames` / `parseApicFrame` / `findTerminator` / `desynchronise`
/// / `parseId3v1`（行号见 task-7-brief.md）。
///
/// 契约与原版一致：**任何畸形长度、越界帧、未知编码都只影响对应字段**，
/// 函数不抛异常；解析不出字段时返回 null，让调用方继续走其它格式或文件名兜底。

/// 整标签 unsynchronisation 位：v2.3 表示整个帧区、v2.4 表示所有帧都做过 unsync。
const int unsynchronisationFlag = 0x80;

/// 扩展头位：v2.3 / v2.4 的帧区整体后移。
const int extendedHeaderFlag = 0x40;

/// v2.4 帧头第二字节（格式标志）里的 unsynchronisation 位。
const int frameUnsynchronisationFlag = 0x0002;

/// 封面类型 3 = 正面封面；多张图时优先它（对齐原版）。
const int frontCoverType = 3;

/// `ID3` 魔数。
const List<int> id3Signature = [0x49, 0x44, 0x33];

/// 帧文本 id → 目标字段。v2.2 的三字符 id 一并收进来（v2.3/2.4 不会撞上）。
const Map<String, String> id3TextFrames = {
  'TIT1': 'title',
  'TIT2': 'title',
  'TT1': 'title',
  'TT2': 'title',
  'TPE1': 'artist',
  'TP1': 'artist',
  'TPE2': 'albumArtist',
  'TP2': 'albumArtist',
  'TALB': 'album',
  'TAL': 'album',
};

/// v2.3 / v2.4 的内嵌图片帧。
const String apicFrameId = 'APIC';

/// v2.2 的内嵌图片帧（mime 换成 3 字符格式码）。
const String picFrameId = 'PIC';

const int _tagHeaderLength = 10;
final RegExp _frameIdPattern = RegExp(r'^[A-Z0-9@©]{3,4}$');

/// 内嵌标签的解析结果。字段全部可变，解析器按「先到先得」填。
class Id3Tag {
  Id3Tag({this.version = ''});

  /// 标签版本：`id3v2.2` / `id3v2.3` / `id3v2.4` / `id3v1`。
  String version;

  String title = '';
  String artist = '';
  String album = '';
  String albumArtist = '';

  /// 内嵌封面字节（没有封面时为 null）。
  Uint8List? picture;

  /// 封面的 mime；声明缺失或不是 `image/` 时按魔数嗅探。
  String pictureMime = '';

  /// 一个字段都没解出来：调用方据此返回 null（对齐原版「空结果」语义）。
  bool get isEmpty =>
      title.isEmpty &&
      artist.isEmpty &&
      album.isEmpty &&
      albumArtist.isEmpty &&
      picture == null;
}

/// 去掉 unsynchronisation 引入的填充：`0xff 0x00` → `0xff`。
///
/// 只在整标签（`unsynchronisationFlag`）或 v2.4 单帧
/// （`frameUnsynchronisationFlag`）被标记时使用。
Uint8List desynchronise(List<int> bytes) {
  final out = Uint8List(bytes.length);
  var written = 0;
  for (var i = 0; i < bytes.length; i += 1) {
    out[written] = bytes[i];
    written += 1;
    if (bytes[i] == 0xff && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
      i += 1;
    }
  }
  return Uint8List.sublistView(out, 0, written);
}

/// 解析 ID3v2.2 / 2.3 / 2.4 标签。
///
/// 返回 null 表示「开头不是 `ID3`」或「一个字段都没解出来」。
/// 越界 / 长度畸形 / padding 只会**停止扫描**，已经解出的字段照常返回。
Future<Id3Tag?> parseId3v2(ByteSource src, {int offset = 0}) async {
  if (!await src.matches(offset, id3Signature)) return null;
  final header = await src.read(offset, _tagHeaderLength);
  if (header.length < _tagHeaderLength) return null;
  final version = header[3];
  if (version < 2 || version > 4) return null;
  final flags = header[5];
  final size = _synchsafeAt(header, 6);
  if (size <= 0) return null;

  // 单次读取不超过上限：长度是畸形大数时只截断不放弃（原版 Math.min(tagSize, maxBytes)），
  // 越界的帧由下面的边界检查丢掉。
  final wanted = size > ByteSource.defaultMaxBytes
      ? ByteSource.defaultMaxBytes
      : size;
  final body = await src.read(offset + _tagHeaderLength, wanted);
  final List<int> whole = (flags & unsynchronisationFlag) != 0
      ? desynchronise(body)
      : body;
  if (whole.isEmpty) return null;

  var pos = 0;
  if (version >= 3 && (flags & extendedHeaderFlag) != 0) {
    // v2.3 的长度不含自身 4 字节；v2.4 是 synchsafe 且含自身。
    final extSize = version == 4
        ? _synchsafeAt(whole, 0)
        : _u32beAt(whole, 0) + 4;
    if (extSize <= 0 || extSize > whole.length) return null;
    pos = extSize;
  }

  final idLength = version == 2 ? 3 : 4;
  // v2.2 的帧头是 3 字节 id + 3 字节长度、没有标志位（原版在这里沿用了 v2.3
  // 布局，导致 PIC 永远解不出来；本移植按 ID3v2.2 规范实现，见 report 偏差表）。
  final sizeLength = version == 2 ? 3 : 4;
  final headerLength = idLength + sizeLength + (version == 2 ? 0 : 2);
  final tag = Id3Tag(version: 'id3v2.$version');

  while (pos + headerLength <= whole.length) {
    final id = String.fromCharCodes(whole.sublist(pos, pos + idLength));
    if (!_frameIdPattern.hasMatch(id)) break; // 进了 padding 区
    final frameLength = switch (version) {
      2 => _u24beAt(whole, pos + idLength),
      4 => _synchsafeAt(whole, pos + idLength),
      _ => _u32beAt(whole, pos + idLength),
    };
    if (frameLength <= 0 || pos + headerLength + frameLength > whole.length) {
      // 长度畸形 / 帧越界：停止扫描，保留已解析字段，绝不抛。
      break;
    }
    // 标志位是 2 字节：状态标志在前、格式标志在后，v2.4 的 unsync 在格式标志里。
    final frameFlags = version == 2
        ? 0
        : whole[pos + idLength + sizeLength + 1];
    var content = whole.sublist(
      pos + headerLength,
      pos + headerLength + frameLength,
    );
    if (version == 4 && (frameFlags & frameUnsynchronisationFlag) != 0) {
      content = desynchronise(content);
    }

    if (id == apicFrameId || id == picFrameId) {
      final picture = _parseApicFrame(content, isV2Pic: id == picFrameId);
      // 优先正面封面（type 3），没有就留第一张。
      if (picture != null &&
          (tag.picture == null || picture.coverType == frontCoverType)) {
        tag.picture = picture.data;
        tag.pictureMime = picture.mime;
      }
    } else {
      final field = id3TextFrames[id];
      if (field != null && content.isNotEmpty) {
        // content[0] 是 encoding 字节；encoding=0 不盲信声明，交给嗅探。
        final value = _cleanText(decodeId3Text(content.sublist(1), content[0]));
        // 先到先得：已有值不被后来的空值或第二个同名字段覆盖。
        if (value.isNotEmpty) _applyText(tag, field, value);
      }
    }

    pos += headerLength + frameLength;
  }

  return tag.isEmpty ? null : tag;
}

/// 解析文件尾 128 字节的 ID3v1：只看签名 `TAG`，没有编码位，字段是定长**字节**。
///
/// 原版还读 year（偏移 90 的 4 字节）；Id3Tag 按 task-7-brief 的接口不暴露
/// year，所以这里不解析。
Future<Id3Tag?> parseId3v1(ByteSource src) async {
  if (src.length < _v1TailLength) return null;
  final tail = await src.readTail(_v1TailLength);
  if (tail.length < _v1TailLength ||
      tail[0] != 0x54 ||
      tail[1] != 0x41 ||
      tail[2] != 0x47) {
    return null;
  }
  String field(int from, int width) =>
      _cleanText(decodeLegacyText(tail.sublist(from, from + width)));
  final tag = Id3Tag(version: 'id3v1')
    ..title = field(3, 30)
    ..artist = field(33, 30)
    ..album = field(63, 30);
  return tag.isEmpty ? null : tag;
}

const int _v1TailLength = 128;

/// 图片帧的解析结果：字节 + mime + 封面类型（类型只用于挑封面，不进 Id3Tag）。
typedef _ApicPicture = ({Uint8List data, String mime, int coverType});

/// 解析 APIC（v2.3 / 2.4）或 PIC（v2.2）帧内容。
///
/// 声明的 mime 不是 `image/…` 时按魔数嗅探；嗅探不出就丢弃这一帧（原版返回 null）。
_ApicPicture? _parseApicFrame(List<int> content, {required bool isV2Pic}) {
  if (content.length < 4) return null;
  final encoding = content[0];
  final wide = encoding == 1 || encoding == 2;
  var pos = 1;
  String mime;
  if (isV2Pic) {
    // v2.2 存的是 'JPG' / 'PNG' 这类图片格式码。
    if (pos + 3 > content.length) return null;
    final code = _latin1Of(content.sublist(pos, pos + 3)).toUpperCase();
    mime = code == 'PNG' ? 'image/png' : 'image/jpeg';
    pos += 3;
  } else {
    final end = content.indexOf(0, pos);
    if (end < 0) return null;
    mime = _cleanText(_latin1Of(content.sublist(pos, end))).toLowerCase();
    pos = end + 1;
  }
  if (pos >= content.length) return null;
  final coverType = content[pos];
  pos += 1;
  // 描述文字按帧编码解，结束符随编码而变（UTF-16 是 2 字节对齐的双 NUL）。
  final descriptionEnd = _findTerminator(content, pos, wide: wide);
  if (descriptionEnd < 0) return null;
  pos = descriptionEnd + (wide ? 2 : 1);
  if (pos >= content.length) return null;

  final data = content.sublist(pos);
  if (data.length > ByteSource.defaultMaxBytes) return null;
  if (!mime.startsWith('image/')) mime = sniffImageMime(data);
  if (mime.isEmpty) return null;
  // 复制一份：content 只是整个标签的视图，别把整块内存挂在封面上。
  return (data: Uint8List.fromList(data), mime: mime, coverType: coverType);
}

/// 找帧内的字符串结束符位置：单字节编码认 `0x00`，UTF-16 认双字节边界上的
/// `0x00 0x00`。找不到返回 -1（当作畸形帧跳过）。
int _findTerminator(List<int> bytes, int from, {required bool wide}) {
  if (wide) {
    for (var i = from; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i;
    }
    return -1;
  }
  return bytes.indexOf(0, from);
}

void _applyText(Id3Tag tag, String field, String value) {
  switch (field) {
    case 'title':
      if (tag.title.isEmpty) tag.title = value;
    case 'artist':
      if (tag.artist.isEmpty) tag.artist = value;
    case 'album':
      if (tag.album.isEmpty) tag.album = value;
    case 'albumArtist':
      if (tag.albumArtist.isEmpty) tag.albumArtist = value;
  }
}

/// 去掉字符串里的 NUL、控制字符与首尾空白（对齐原版 `cleanText`）。
String _cleanText(String value) {
  final buffer = StringBuffer();
  for (final unit in value.codeUnits) {
    if (unit == 0x00) continue;
    if (unit >= 0x01 && unit <= 0x08) continue;
    if (unit == 0x0b || unit == 0x0c) continue;
    if (unit >= 0x0e && unit <= 0x1f) continue;
    if (unit == 0x7f) continue;
    buffer.writeCharCode(unit);
  }
  return buffer.toString().trim();
}

/// Latin-1 一对一映射（mime、帧 id 这些地方只用 ASCII 区）。
String _latin1Of(List<int> bytes) =>
    String.fromCharCodes(bytes.map((byte) => byte & 0xff));

int _u32beAt(List<int> bytes, int offset) => offset + 4 > bytes.length
    ? 0
    : (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];

/// 大端 24 位（v2.2 的帧长度）。
int _u24beAt(List<int> bytes, int offset) => offset + 3 > bytes.length
    ? 0
    : (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];

/// ID3v2 的 synchsafe 整数：每字节只用低 7 位。
int _synchsafeAt(List<int> bytes, int offset) => offset + 4 > bytes.length
    ? 0
    : ((bytes[offset] & 0x7f) << 21) |
          ((bytes[offset + 1] & 0x7f) << 14) |
          ((bytes[offset + 2] & 0x7f) << 7) |
          (bytes[offset + 3] & 0x7f);
