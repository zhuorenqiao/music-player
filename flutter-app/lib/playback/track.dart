// lib/playback/track.dart
import 'track_handle.dart';

const int kMaxLyricsLength = 64 * 1024;

const String kUnknownTitle = '未知曲目';

/// 结构自检：与原版 isTrackLike 逐条对齐（src/lib/playlist.js:47-54）——
/// `title` 必须是字符串（可以为空串，空串在 normalizeTrack 里退成「未知曲目」），
/// `id` 与 `src` 还必须是非空字符串。
bool isTrackLike(Object? raw) =>
    raw is Map &&
    raw['id'] is String &&
    (raw['id'] as String).isNotEmpty &&
    raw['title'] is String &&
    raw['src'] is String &&
    (raw['src'] as String).isNotEmpty;

/// 对译原版 `normalizeTrack`：不改写 `id`/`src`（id 由调用方给出），
/// 只补默认值与清洗脏字段。非法数据返回 null。
Track? normalizeTrack(Object? raw) {
  if (!isTrackLike(raw)) return null;
  final map = (raw as Map).cast<String, Object?>();
  final duration = map['duration'];
  // 取一次原值即可；下面的比较一律针对原值本身。原版是精确比较
  // （src/lib/playlist.js:87 `raw.lyricsSource === 'auto'`），不做 trim，
  // 所以 ' auto ' 这类值在原版得到空串，这里必须一致。
  final lyricsSource = map['lyricsSource'];
  return Track(
    id: map['id']! as String,
    title: ((map['title'] as String?) ?? '').trim().isEmpty
        ? kUnknownTitle
        : (map['title'] as String).trim(),
    artist: _trimmed(map['artist']),
    album: _trimmed(map['album']),
    cover: _trimmed(map['cover']),
    src: map['src']! as String,
    duration: duration is num && duration.isFinite && duration > 0
        ? duration.toDouble()
        : double.nan,
    isLocal: map['isLocal'] == true,
    lyrics: _clampLyrics(map['lyrics']),
    lyricsPlain: _clampLyrics(map['lyricsPlain']),
    lyricsSource: lyricsSource == 'auto' || lyricsSource == 'manual'
        ? lyricsSource as String
        : '',
    restored: map['restored'] == true,
    handle:
        TrackHandle.fromJson(
          map['handle'] is Map
              ? (map['handle'] as Map).cast<String, Object?>()
              : null,
        ) ??
        FilePathHandle(map['src']! as String),
  );
}

String _trimmed(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : '';

String _clampLyrics(Object? value) {
  if (value is! String || value.trim().isEmpty) return '';
  return value.length > kMaxLyricsLength
      ? value.substring(0, kMaxLyricsLength)
      : value;
}

class Track {
  Track({
    required this.id,
    required this.src,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.cover = '',
    double? duration,
    this.isLocal = false,
    this.lyrics = '',
    this.lyricsPlain = '',
    this.lyricsSource = '',
    this.restored = false,
    TrackHandle? handle,
  }) : duration = duration ?? double.nan,
       handle = handle ?? FilePathHandle(src);

  final String id;
  String title;
  String artist;
  String album;
  String cover;

  /// 展示与存档用的来源字符串（沿用原版语义）。播放一律以 `handle` 为准
  /// （T11 起由 handle 给出可播 URI），所以它可变但不参与播放判定。
  String src;
  double duration;
  bool isLocal;
  String lyrics;
  String lyricsPlain;
  String lyricsSource;
  bool restored;
  TrackHandle handle;

  bool get hasDuration => duration.isFinite && duration > 0;

  /// 已有真封面 == cover 非空。生成卡不写这里（spec §12）。
  bool get hasRealCover => cover.isNotEmpty;

  Track copy() => Track(
    id: id,
    src: src,
    title: title,
    artist: artist,
    album: album,
    cover: cover,
    duration: duration,
    isLocal: isLocal,
    lyrics: lyrics,
    lyricsPlain: lyricsPlain,
    lyricsSource: lyricsSource,
    restored: restored,
    handle: handle,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'src': src,
    'duration': hasDuration ? duration : null,
    'isLocal': isLocal,
    'lyrics': lyrics,
    'lyricsPlain': lyricsPlain,
    'lyricsSource': lyricsSource,
    'restored': restored,
    'handle': handle.toJson(),
  };

  static Track? fromJson(Map<String, Object?> json) => normalizeTrack(json);
}
