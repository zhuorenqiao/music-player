// lib/lyrics/lyrics_provider.dart
//
// 单个歌词源的最小接口：LyricsSource 按优先级依次调用。
// 单独一层是为了避免 lyrics_source ↔ 各源实现之间的循环 import。
import 'lyrics_cache.dart';
import 'query.dart';
import 'upstream.dart';

abstract class LyricsProvider {
  Future<LyricsRecord?> lookup(LyricsQuery query, {CancelToken? cancel});
}
