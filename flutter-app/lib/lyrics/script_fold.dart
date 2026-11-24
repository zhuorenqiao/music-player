// lib/lyrics/script_fold.dart
//
// 查询侧的繁→简折叠（对译 React 版 src/lib/lyrics-source.js 的 foldQuery）。
//
// 为什么必须有这一层：LRCLIB 的 /get 是「曲名 + 歌手」逐字匹配，/search 也按词面
// 切词。标签里写成繁体（周杰倫 / 完美主義）时，上游那条简体记录一条都对不上 ——
// 实测 get 404、search 0 条（2026-11-21《完美主义》案例）。查询前统一折到简体，
// 缓存键也跟着折：键变了，之前按繁体查出来的「未找到」不会再挡在缓存里。
//
// 只折查询参数，不动歌词正文：正文的繁→简由显示层 toSimplified 负责，缓存里保持原文。
// 返回对象带上原字形，供「简体也没命中」时补一次原字形搜索 —— 只有繁体条目的冷门歌
// 不至于因此回归（lyrics_source.dart 的 _fetch 末尾那一步）。
import 'opencc/converter.dart';
import 'query.dart';

/// 把查询折到简体，并按折叠后的曲名/歌手重算 key。
///
/// 没变化时原样返回同一个对象（缓存键、日志都保持原样，调用方可以放心复用）。
LyricsQuery foldQuery(LyricsQuery query) {
  final trackName = toSimplified(query.trackName);
  final artistName = toSimplified(query.artistName);
  if (trackName == query.trackName && artistName == query.artistName) {
    return query;
  }
  return LyricsQuery(
    trackName: trackName,
    artistName: artistName,
    duration: query.duration,
    key: '$trackName|$artistName|${query.duration}'.toLowerCase(),
  );
}

/// 折叠是否真的改动了曲名/歌手（决定要不要补原字形回退）。
bool foldChangedByScript(LyricsQuery raw, LyricsQuery folded) =>
    raw.trackName != folded.trackName || raw.artistName != folded.artistName;
