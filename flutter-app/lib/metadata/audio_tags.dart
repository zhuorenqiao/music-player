// lib/metadata/audio_tags.dart
import 'dart:convert';
import 'dart:typed_data';

import 'byte_reader.dart';
import 'id3.dart';
import 'mp4.dart';
import 'vorbis.dart';

/// 对译 React 版 src/lib/audio-tags.js 的对外入口（`readAudioTags`:736-796、
/// `mergeTaggedNames`:855-860，行号见 task-10-brief.md）。
///
/// 分派规则与原版一致，全部按魔数判断，不看扩展名、也不看调用方给的 MIME：
/// * `fLaC`（偏移 0）→ FLAC；`OggS`（0）→ OGG；`ftyp`（+4）→ MP4；
/// * `ID3`（0）→ ID3v2，且 `format` 落到 `id3v2.2` / `id3v2.3` / `id3v2.4`；
/// * 其余一律 `mp3`（裸 MPEG 帧、只挂 ID3v1 尾巴的 MP3、以及认不出的字节）。
///   原版对 ID3v2 文件也一律报 `mp3`，这里按容器版本区分，见 brief 的接口约定。
///
/// 读取策略：`ByteSource` 只在被要求时读（头部 64KB 判格式、标签区按需再读、
/// 单次读取上限 8MB），与原版 README 记录的策略一致。
///
/// **本文件的入口都不抛异常**：空文件、随机字节、声明了 9MB 帧区的畸形标签
/// 都只会少几个字段。上游 `readAudioTags → normalizeTrack → LibraryRepository.load`
/// 整条链没有 try/catch，这里抛一次就是整个导入失败。

/// `fLaC` 魔数。
const List<int> _flacSignature = [0x66, 0x4c, 0x61, 0x43];

/// OGG 捕获模式的 `OggS` 魔数。
const List<int> _oggSignature = [0x4f, 0x67, 0x67, 0x53];

/// MP4 家族的 `ftyp`：出现在偏移 4（前 4 字节是首个 box 的长度）。
const List<int> _ftypSignature = [0x66, 0x74, 0x79, 0x70];

/// 认不出容器时的默认格式（原版语义：裸 MPEG 与未知字节都按 mp3 处理）。
const String _defaultFormat = 'mp3';

/// 空文件（一个字节都读不到）的格式。
const String _unknownFormat = 'unknown';

/// ID3v2 打头时的临时格式，随后被 `id3v2.N` 覆盖。
const String _id3v2Format = 'id3v2';

/// 一次标签读取的结果。
///
/// 字段与原版 `readAudioTags` 的返回同构（少了 `year`：`Id3Tag` 没有该字段，
/// 见 task-7 裁定）；`pictureMime` 已经过魔数校正，不会为空串配非空图片。
class TagResult {
  TagResult({
    this.format = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.picture,
    this.pictureMime = '',
  });

  /// 容器 / 标签版本：`mp3` / `flac` / `ogg` / `mp4` / `id3v2.3` / `unknown`…
  String format;

  String title;
  String artist;
  String album;
  String albumArtist;

  /// 内嵌封面字节（没有封面时为 null）。
  Uint8List? picture;

  /// 封面的 mime（`image/png` / `image/jpeg` …）。
  String pictureMime;

  /// 至少有一个文本字段。ID3v1 兜底的触发条件之一。
  bool get hasAnyText =>
      title.isNotEmpty ||
      artist.isNotEmpty ||
      album.isNotEmpty ||
      albumArtist.isNotEmpty;

  bool get hasPicture => picture != null && picture!.isNotEmpty;

  /// 落库 / 写缓存的形态：封面走 base64（与原版 data URL 的 `;base64,` 同源）。
  Map<String, Object?> toJson() => {
    'format': format,
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'pictureMime': pictureMime,
    'pictureBytes': picture == null ? null : base64Encode(picture!),
  };
}

/// 读取音频文件的内嵌标签与内嵌封面。
///
/// [fileName] 只为对齐原版签名保留（原版拿它打日志），不参与解析。
/// 任何输入都返回一个非空 `format` 的结果，绝不抛出。
Future<TagResult> readAudioTags(ByteSource src, {String fileName = ''}) async {
  final result = TagResult();
  if (src.length == 0) {
    result.format = _unknownFormat;
    return result;
  }
  try {
    if (await src.matches(0, _flacSignature)) {
      result.format = 'flac';
      _merge(result, await parseFlacMeta(src));
      return result;
    }
    if (await src.matches(0, _oggSignature)) {
      result.format = 'ogg';
      _merge(result, await parseOggMeta(src));
      return result;
    }
    if (await src.matches(4, _ftypSignature)) {
      result.format = 'mp4';
      _merge(result, await parseMp4Meta(src));
      return result;
    }
    if (await src.matches(0, id3Signature)) {
      final tag = await parseId3v2(src);
      // 头里是 ID3 就一定报 id3v2.x（解不出帧时退回 `id3v2`），
      // 别让随后补读的 ID3v1 把容器名改写成 `id3v1`。
      result.format = tag == null || tag.version.isEmpty
          ? _id3v2Format
          : tag.version;
      _merge(result, tag);
      await _fallbackId3v1(result, src);
      return result;
    }
    // 裸 MPEG / ADTS / 认不出的字节：按原版兜底成 mp3，尾部仍可能有 ID3v1。
    // 这里不再试 ID3v2 —— 上面那条分支已经把 `ID3` 打头的文件接走了。
    result.format = _defaultFormat;
    await _fallbackId3v1(result, src);
    return result;
  } catch (_) {
    // 任何一环失败都只影响对应字段：保留已经解出的部分，绝不抛给调用方。
    if (result.format.isEmpty) result.format = _unknownFormat;
    return result;
  }
}

/// 文本与封面都没拿全时，补读文件末尾 128 字节的 ID3v1（原版的兜底级）。
Future<void> _fallbackId3v1(TagResult result, ByteSource src) async {
  if (result.hasAnyText && result.hasPicture) return;
  _merge(result, await parseId3v1(src));
}

/// 把某一层解析结果并进 [result]：文本只填空缺，封面只补空缺。
///
/// 与原版 `Object.assign` / `||=` 的差别只在「不覆盖已有值」——
/// 一次读取只会经过一层容器，所以两种写法结果相同。`format` 不在这里改：
/// 容器名由 [readAudioTags] 的分派决定，桶底标签（ID3v1）无权改写它。
void _merge(TagResult result, Id3Tag? tag) {
  if (tag == null) return;
  if (result.title.isEmpty) result.title = tag.title;
  if (result.artist.isEmpty) result.artist = tag.artist;
  if (result.album.isEmpty) result.album = tag.album;
  if (result.albumArtist.isEmpty) result.albumArtist = tag.albumArtist;
  if (result.picture == null && tag.picture != null) {
    result.picture = tag.picture;
    result.pictureMime = tag.pictureMime;
  }
}

/// 归一后的展示字段。
class Names {
  Names({required this.title, required this.artist, required this.usedTags});

  final String title;
  final String artist;

  /// 是否有字段来自标签（true 说明文件名仅供参考）。
  final bool usedTags;
}

/// 标签优先、缺什么补什么（原版 `mergeTaggedNames`）。
///
/// * `title` / `artist` 各自独立判断：标签有就用标签，没有才用文件名拆分；
/// * 歌手还有一层兜底：`albumArtist` 先于文件名（原版的 `artist || albumArtist || …`）；
/// * `usedTags` 为 true 的条件是 title / artist / albumArtist 任一来自标签。
Names mergeTaggedNames(TagResult tags, String fromName) {
  final split = splitArtistTitle(fromName);
  final title = tags.title.isNotEmpty ? tags.title : split.title;
  final artist = tags.artist.isNotEmpty
      ? tags.artist
      : (tags.albumArtist.isNotEmpty ? tags.albumArtist : split.artist);
  final usedTags =
      tags.title.isNotEmpty ||
      tags.artist.isNotEmpty ||
      tags.albumArtist.isNotEmpty;
  return Names(title: title, artist: artist, usedTags: usedTags);
}

/// 从文件名拆「歌手 - 曲名」：只在**第一个** ` - ` 处拆，左侧歌手、右侧曲名，
/// 两侧去空白。
///
/// 拆不出（没有分隔符、分隔符在开头、任一侧为空）时返回（空歌手, 原文）。
/// 这是原版 `splitArtistTitle` 的同名实现；M2 把它迁到 `lyrics/` 时调用方不变。
({String artist, String title}) splitArtistTitle(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (artist: '', title: '');
  final at = text.indexOf(' - ');
  if (at <= 0) return (artist: '', title: text);
  final left = text.substring(0, at).trim();
  final right = text.substring(at + 3).trim();
  if (left.isEmpty || right.isEmpty) return (artist: '', title: text);
  return (artist: left, title: right);
}
