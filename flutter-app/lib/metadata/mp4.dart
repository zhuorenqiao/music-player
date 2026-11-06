// lib/metadata/mp4.dart
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'text_decode.dart';

/// 对译 React 版 src/lib/audio-tags.js 的 MP4 部分（`parseMp4` / `parseMp4Window`
/// / `findBox` / `findIlst` / `readDataAtom`，行号见 task-9-brief.md）：
/// 只解 `moov.udta.meta.ilst` 里的 `©nam` / `©ART` / `©alb` / `aART` / `covr`。
///
/// 契约与原版一致：**任何畸形长度、越界 box、未知载荷都只丢字段**，函数不抛异常
/// —— 上游 `readAudioTags` → `normalizeTrack` → `LibraryRepository.load` 整条链
/// 都没有 try/catch，所以这里既不允许 `as` 强转，也不允许把畸形长度当真去读。
///
/// 与 JS 的差异（见 task-9-report.md 的偏差表）：
/// * 不切「头部 64KB / 尾部窗口」两次尝试：`ByteSource` 本身就支持任意偏移读取，
///   一次遍历整个文件即可（原版的两次尝试只是为了绕过 `file.slice` 窗口）；
/// * `covr` 的 data atom flags 参与判型：13 = JPEG、14 = PNG，其余按魔数嗅探
///   （原版完全忽略 flags，一律嗅探，嗅探不出就兜底 `image/jpeg`）；
/// * `©day`（原版映射 `year`）不解析 —— `Id3Tag` 没有该字段（task-7 裁定）。

/// data atom 的 type flags 里 13 = JPEG。
const int _jpegFlag = 13;

/// data atom 的 type flags 里 14 = PNG。
const int _pngFlag = 14;

/// `ftyp` 的 fourcc —— MP4 家族的判定依据。
const List<int> _ftypSignature = [0x66, 0x74, 0x79, 0x70];

/// ilst 里的文本键 → `Id3Tag` 字段。
///
/// 键是 latin-1 文本（`©` = 单字节 `0xA9`），比较时按字节进行，不经过 UTF-8。
/// 原版的 `MP4_TEXT_KEYS` 还有 `©day → year`，本移植不解析（无该字段）。
const Map<String, String> _textKeys = {
  '\u00a9nam': 'title',
  '\u00a9ART': 'artist',
  'aART': 'albumArtist',
  '\u00a9alb': 'album',
};

/// 找到的 box 的**内容区**：`[start, end)`，不含 8 字节 box 头。
typedef _Box = ({int start, int end});

/// 解析 M4A / MP4 的内嵌标签。
///
/// [offset] 是文件里 MP4 的起点（容器分派场景下可能非 0）。`ftyp` 不在
/// `offset + 4` 处 → null（不是 MP4）；有 `ftyp` 但没有 `moov` / `udta` /
/// `meta` / `ilst` → null；解不出任何字段 → null。全程不抛。
Future<Id3Tag?> parseMp4Meta(ByteSource src, {int offset = 0}) async {
  if (offset < 0) return null;
  // 只按 ftyp 判家族：moov 缺失是「正常的非标签 MP4」，不是错误。
  if (!await src.matches(offset + 4, _ftypSignature)) return null;
  final moov = await _findBox(src, offset, src.length, 'moov');
  if (moov == null) return null;
  final udta = await _findBox(src, moov.start, moov.end, 'udta');
  if (udta == null) return null;
  final meta = await _findBox(src, udta.start, udta.end, 'meta');
  if (meta == null) return null;
  // meta 是完整 box：先有 4 字节 version/flags，之后才是 ilst 之类的子 box。
  final ilst = await _findBox(src, meta.start + 4, meta.end, 'ilst');
  if (ilst == null) return null;
  return _readIlst(src, ilst.start, ilst.end);
}

/// 在 `[from, to)` 里按兄弟顺序找指定 fourcc 的 box。
///
/// 长度语义对齐原版 `findBox`：`size == 1` 读 16 字节头里的 64 位 largesize，
/// `size == 0` 表示「一直到父容器末尾」。长度小于头长或跑出父容器的，**整层
/// 停止**（结构已损坏，别硬走），已经找到的 box 不受影响。
Future<_Box?> _findBox(ByteSource src, int from, int to, String name) async {
  var pos = from;
  while (pos + 8 <= to) {
    var size = await src.u32be(pos);
    var header = 8;
    if (size == 1) {
      final hi = await src.u32be(pos + 8);
      final lo = await src.u32be(pos + 12);
      size = hi * 0x100000000 + lo;
      header = 16;
    } else if (size == 0) {
      size = to - pos;
    }
    if (size < header || pos + size > to) return null;
    if (await src.matchesText(pos + 4, name)) {
      return (start: pos + header, end: pos + size);
    }
    pos += size;
  }
  return null;
}

/// 遍历 ilst 的条目，逐个把 data atom 落到 [Id3Tag]。
///
/// 条目长度小于 8 或跑出 ilst 就**停止扫描**（保留已解析字段），绝不抛。
Future<Id3Tag?> _readIlst(ByteSource src, int from, int to) async {
  final tag = Id3Tag(version: 'mp4');
  var pos = from;
  while (pos + 8 <= to) {
    final size = await src.u32be(pos);
    if (size < 8 || pos + size > to) break;
    final name = await src.read(pos + 4, 4);
    if (name.length < 4) break;
    final content = await src.read(pos + 8, size - 8);
    _applyItem(tag, name, content);
    pos += size;
  }
  return tag.isEmpty ? null : tag;
}

/// 处理一个 ilst 条目：`covr` 进封面，其余按 [_textKeys] 映射文本字段。
void _applyItem(Id3Tag tag, List<int> name, List<int> content) {
  final data = _readDataAtom(content);
  if (data == null) return;
  if (_nameAt(name, 0, 'covr')) {
    _applyCover(tag, data.bytes, data.flags);
    return;
  }
  final field = _textFieldOf(name);
  if (field == null) return;
  final value = _clean(decodeLegacyText(data.bytes));
  if (value.isEmpty) return; // 先到先得：不让空值覆盖已有内容
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

/// 读条目里的第一个 `data` 子 box，返回（载荷, type flags）。
///
/// 布局：box 头(8) + version/flags(4) + locale(4) + 载荷。flags 取低 24 位
/// （高 8 位是 version，真实文件里恒为 0）。box 越界或不是 `data` 一律 null，
/// 不做任何强转 —— 上游没有兜底，这里必须容错。
({List<int> bytes, int flags})? _readDataAtom(List<int> content) {
  var pos = 0;
  while (pos + 8 <= content.length) {
    final size = _u32beAt(content, pos);
    if (size < 8 || pos + size > content.length) return null;
    if (_nameAt(content, pos + 4, 'data')) {
      if (size < 16) return null; // 连 version/flags + locale 都不够
      final flags =
          (content[pos + 8] << 16) |
          (content[pos + 9] << 8) |
          content[pos + 10];
      return (bytes: content.sublist(pos + 16, pos + size), flags: flags);
    }
    pos += size;
  }
  return null;
}

/// 封面：flags 13 = JPEG、14 = PNG，其余按魔数嗅探。
///
/// 嗅探不出就不设封面（原版会兜底成 `image/jpeg` 硬塞一个 blob；本移植与
/// id3 / vorbis 的处理一致：认不出就丢，免得把非图片载荷当封面）。
void _applyCover(Id3Tag tag, List<int> payload, int flags) {
  if (payload.isEmpty || payload.length > ByteSource.defaultMaxBytes) return;
  final mime = switch (flags) {
    _jpegFlag => 'image/jpeg',
    _pngFlag => 'image/png',
    _ => sniffImageMime(payload),
  };
  if (mime.isEmpty) return;
  // 复制一份：载荷只是 entry 的切片，别把整块 ilst 挂在封面上。
  tag.picture = Uint8List.fromList(payload);
  tag.pictureMime = mime;
}

/// 条目名 → 字段名；未收录的名字返回 null（包括 `©day`）。
String? _textFieldOf(List<int> name) {
  for (final entry in _textKeys.entries) {
    if (_nameAt(name, 0, entry.key)) return entry.value;
  }
  return null;
}

/// 按 Latin-1 字节比较[bytes] 的 [offset] 处是否是 [text]。
///
/// fourcc / 条目名都是 latin-1（`©` = `0xA9`）；超过 0xff 的字符直接判不匹配，
/// 宁可漏认也不抛。**不能**用 `String.fromCharCodes` 之后比 UTF-8 字符串。
bool _nameAt(List<int> bytes, int offset, String text) {
  if (offset < 0 || offset + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i += 1) {
    final unit = text.codeUnitAt(i);
    if (unit > 0xff || bytes[offset + i] != unit) return false;
  }
  return true;
}

/// 去掉 NUL 与首尾空白（对齐原版 `cleanText` 的可见字符部分）。
String _clean(String value) => value.replaceAll('\u0000', '').trim();

int _u32beAt(List<int> bytes, int offset) => offset + 4 > bytes.length
    ? 0
    : (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
