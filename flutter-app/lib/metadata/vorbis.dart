// lib/metadata/vorbis.dart
import 'dart:convert';
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'text_decode.dart';

/// 对译 React 版 src/lib/audio-tags.js 的 Vorbis Comment / FLAC / OGG 部分：
/// `parseVorbisComment` / `parseFlacPicture` / `parseFlac` / `parseOgg`。
///
/// 契约与原版一致：畸形长度、越界块、非法 base64 只影响对应字段，
/// 函数不抛异常；一个字段都没解出来时返回 null，让调用方继续兜底。
///
/// 与 JS 的差异只有两处，都是本移植的既定裁定：
/// * `parseVorbisComment` 的 key 统一转**小写**（JS 用大写），见 task-8-brief；
/// * 原版读 `DATE` / `YEAR` 填 `year`，而 `Id3Tag` 没有该字段（task-7 裁定），
///   `year` 整个不解析。

/// `fLaC` 魔数。
const List<int> _flacSignature = [0x66, 0x4c, 0x61, 0x43];

/// OGG 捕获模式的 `OggS` 魔数。
const List<int> _oggSignature = [0x4f, 0x67, 0x67, 0x53];

/// 元数据块链最多扫这么多块（对齐原版 `guard < 64`），防畸形链死循环。
const int _blockGuard = 64;

/// 找 comment 报文时先读这么多（对齐原版 `PROBE_BYTES` = 64KB）。
const int _oggProbeBytes = 64 * 1024;

/// Vorbis comment 报文的魔数尾段（前面是 1 字节的报文类型 0x03）。
final List<int> _vorbisMagic = latin1.encode('vorbis');

/// `METADATA_BLOCK_PICTURE` 的 base64 里可能有换行；解得前先全部去掉。
final RegExp _whitespace = RegExp(r'\s');

/// 解析 Vorbis Comment 块：`vendor 长度 + vendor + 条目数 + 每条[长度 + 文本]`。
///
/// [offset] 指向 vendor 长度字段（OGG 的 comment 报文是 `0x03 'vorbis'` 之后，
/// 所以传 7）。key 统一转小写、值保留原样；解析不出键值的条目跳过（不抛），
/// 同一个 key 先到先得（对齐原版 `!(key in fields)`）。
Map<String, String> parseVorbisComment(List<int> bytes, {int offset = 0}) {
  final fields = <String, String>{};
  if (offset < 0 || offset + 4 > bytes.length) return fields;
  final vendorLength = _u32leAt(bytes, offset);
  var pos = offset + 4 + vendorLength;
  if (pos < 0 || pos + 4 > bytes.length) return fields;
  final count = _u32leAt(bytes, pos);
  pos += 4;
  for (var i = 0; i < count && pos + 4 <= bytes.length; i += 1) {
    final length = _u32leAt(bytes, pos);
    pos += 4;
    if (length <= 0 || pos + length > bytes.length) break;
    final start = pos;
    final end = pos + length;
    pos = end;
    // '=' 只可能是 ASCII（GBK 尾字节最小 0x40），按字节切分再解值，
    // 这样 GBK 写的 Vorbis 注释（非标准但真实存在）也能救回来。
    final eq = _indexOfByte(bytes, 0x3d, start, end);
    if (eq <= start) continue; // 没有 '=' 或 key 为空：跳过该条
    final key = _latin1Of(bytes.sublist(start, eq)).trim().toLowerCase();
    final value = _clean(decodeLegacyText(bytes.sublist(eq + 1, end)));
    if (value.isEmpty || fields.containsKey(key)) continue;
    fields[key] = value;
  }
  return fields;
}

/// 解析 FLAC PICTURE 块内容，返回（图片字节, mime）。
///
/// 布局：type(4) + mime 长度(4) + mime + 描述长度(4) + 描述 + 宽/高/位深/调色板
/// 数(16) + 数据长度(4) + 数据。声明的 mime 不是 `image/…` 时按魔数嗅探；
/// 嗅探不出、长度为 0 或越界都返回 null（原版语义：这张图丢弃）。
(Uint8List, String)? readFlacPicture(List<int> bytes, int offset) {
  var pos = offset;
  if (pos < 0 || bytes.length - pos < 8) return null;
  int be() {
    final value =
        (bytes[pos] << 24) |
        (bytes[pos + 1] << 16) |
        (bytes[pos + 2] << 8) |
        bytes[pos + 3];
    pos += 4;
    return value;
  }

  be(); // 封面类型（3 = 正面封面，这里不参与挑选）
  final mimeLength = be();
  if (mimeLength < 0 || pos + mimeLength > bytes.length) return null;
  final mime = _clean(
    _latin1Of(bytes.sublist(pos, pos + mimeLength)),
  ).toLowerCase();
  pos += mimeLength;
  if (pos + 4 > bytes.length) return null;
  final descriptionLength = be();
  // 描述 + 宽/高/位深/调色板数（16 字节）+ 数据长度字段（4 字节）必须都在块内。
  if (descriptionLength < 0 ||
      pos + descriptionLength + 20 > bytes.length) {
    return null;
  }
  pos += descriptionLength + 16;
  final dataLength = be();
  if (dataLength <= 0 ||
      dataLength > ByteSource.defaultMaxBytes ||
      pos + dataLength > bytes.length) {
    return null;
  }
  final data = Uint8List.fromList(bytes.sublist(pos, pos + dataLength));
  final declared = mime.startsWith('image/') ? mime : '';
  final type = declared.isNotEmpty ? declared : sniffImageMime(data);
  if (type.isEmpty) return null;
  return (data, type);
}

/// 解析 FLAC：`fLaC` 魔数 + 元数据块链表（STREAMINFO / VORBIS_COMMENT / PICTURE）。
///
/// 块长度爆炸或越界时**停止扫描**，已经解出的字段照常返回，绝不抛 ——
/// 与原版「畸形输入只丢字段」的约定一致。
Future<Id3Tag?> parseFlacMeta(ByteSource src, {int offset = 0}) async {
  if (offset < 0 || !await src.matches(offset, _flacSignature)) return null;
  final tag = Id3Tag(version: 'flac');
  var pos = offset + 4;
  for (var guard = 0; guard < _blockGuard; guard += 1) {
    final header = await src.read(pos, 4);
    if (header.length < 4) break;
    final isLast = (header[0] & 0x80) != 0;
    final type = header[0] & 0x7f;
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    pos += 4;
    // 块长度爆炸（畸形输入）：停止扫描，已解析字段照常返回，不抛。
    if (length > ByteSource.defaultMaxBytes || pos + length > src.length) break;
    final block = await src.read(pos, length);
    if (block.length < length) break; // 读不全（文件被截断）：同样只停不抛
    if (type == 4) {
      _mergeInto(tag, _tagFromFields(parseVorbisComment(block), 'flac'));
    } else if (type == 6 && tag.picture == null) {
      _applyPicture(tag, block);
    }
    pos += length;
    if (isLast) break;
    // 与原版一致：三项都齐了就不再往下扫（后面的块解不出更多东西）。
    if (tag.title.isNotEmpty && tag.artist.isNotEmpty && tag.picture != null) {
      break;
    }
  }
  return tag.isEmpty ? null : tag;
}

/// 解析 OGG：在前 64KB 里找 Vorbis comment 报文（`0x03 'vorbis'`），
/// 解析 Vorbis Comment，并把 `METADATA_BLOCK_PICTURE` 的 base64 解回 FLAC PICTURE。
///
/// 与原版一样按魔数定位而不是逐页重组页表：真实 OGG 的 comment 报文总是紧跟
/// identification 报文，直接扫字节更耐受畸形页头（且夹具的页头本身就不完整）。
/// `METADATA_BLOCK_PICTURE` 非法 base64 时只丢封面，文本字段照常返回。
Future<Id3Tag?> parseOggMeta(ByteSource src, {int offset = 0}) async {
  if (offset < 0 || !await src.matches(offset, _oggSignature)) return null;
  final available = src.length - offset;
  if (available <= 0) return null;
  final probe = available < _oggProbeBytes ? available : _oggProbeBytes;
  var data = await src.read(offset, probe);
  final start = _findCommentPacket(data);
  if (start < 0) return null;
  final commentStart = start + 7; // 0x03 + 'vorbis'
  // 原版会按 vendor 长度把窗口放大一次：PICTURE 常把 comment 顶出 64KB。
  final vendorLength = _u32leAt(data, commentStart);
  final needed = commentStart + 4 + vendorLength + 4;
  if (needed > data.length) {
    var want = needed > available ? available : needed;
    if (want > ByteSource.defaultMaxBytes) {
      want = ByteSource.defaultMaxBytes;
    }
    if (want > data.length) data = await src.read(offset, want);
  }
  if (commentStart + 4 > data.length) return null;
  final fields = parseVorbisComment(data, offset: commentStart);
  final tag = _tagFromFields(fields, 'ogg');
  _applyBase64Picture(tag, fields);
  return tag.isEmpty ? null : tag;
}

/// 从 comment 报文里挑字段：artist 缺省时兜 albumArtist（对齐原版 `??` 链）。
Id3Tag _tagFromFields(Map<String, String> fields, String version) {
  final tag = Id3Tag(version: version);
  tag.title = fields['title'] ?? '';
  tag.albumArtist = fields['albumartist'] ?? '';
  tag.artist = fields['artist'] ?? fields['albumartist'] ?? '';
  tag.album = fields['album'] ?? '';
  return tag;
}

/// 多块 VORBIS_COMMENT 时先到先得（对齐原版 `result.title ||= …`）。
void _mergeInto(Id3Tag target, Id3Tag source) {
  if (target.title.isEmpty) target.title = source.title;
  if (target.artist.isEmpty) target.artist = source.artist;
  if (target.album.isEmpty) target.album = source.album;
  if (target.albumArtist.isEmpty) target.albumArtist = source.albumArtist;
}

void _applyPicture(Id3Tag tag, List<int> block) {
  final picture = readFlacPicture(block, 0);
  if (picture == null) return;
  tag.picture = picture.$1;
  tag.pictureMime = picture.$2;
}

/// OGG 的 `METADATA_BLOCK_PICTURE`：值是 base64 的 FLAC PICTURE 块。
///
/// base64 畸形时 **只丢封面**：文本字段照常返回（原版 try/catch 的语义）。
void _applyBase64Picture(Id3Tag tag, Map<String, String> fields) {
  final encoded = fields['metadata_block_picture'];
  if (encoded == null || encoded.isEmpty) return;
  try {
    final bytes = base64Decode(encoded.replaceAll(_whitespace, ''));
    _applyPicture(tag, bytes);
  } on FormatException {
    // 非法 base64：没有封面，继续走后面的兜底级。
  }
}

/// 找 `0x03 'vorbis'`（Vorbis comment 报文头）；找不到返回 -1。
int _findCommentPacket(List<int> data) {
  for (var i = 0; i + 7 <= data.length; i += 1) {
    if (data[i] == 0x03 && _matchesAt(data, i + 1, _vorbisMagic)) return i;
  }
  return -1;
}

bool _matchesAt(List<int> bytes, int offset, List<int> signature) {
  if (offset < 0 || offset + signature.length > bytes.length) return false;
  for (var i = 0; i < signature.length; i += 1) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

int _indexOfByte(List<int> bytes, int target, int from, int end) {
  for (var i = from; i < end; i += 1) {
    if (bytes[i] == target) return i;
  }
  return -1;
}

/// 去掉 NUL 与首尾空白（对齐原版 `cleanText` 的可见字符部分）。
String _clean(String value) => value.replaceAll('\u0000', '').trim();

/// Latin-1 一对一映射：vendor / mime / key 都只用 ASCII 区，不会丢字节。
String _latin1Of(List<int> bytes) => String.fromCharCodes(bytes);

int _u32leAt(List<int> bytes, int offset) => offset + 4 > bytes.length
    ? 0
    : bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
