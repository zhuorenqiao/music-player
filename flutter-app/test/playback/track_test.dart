// test/playback/track_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/track_handle.dart';

void main() {
  group('normalizeTrack', () {
    test('缺 id 或缺 src 判为非法', () {
      expect(normalizeTrack({'title': 'a', 'src': 'x'}), isNull);
      expect(normalizeTrack({'id': '', 'src': 'x', 'title': 'a'}), isNull);
      expect(normalizeTrack({'id': 'a', 'src': '', 'title': 'a'}), isNull);
      // 缺 title 也非法：原版 isTrackLike 三个字段一起校验，这里锁住该规则。
      expect(normalizeTrack({'id': 'a', 'src': 'x'}), isNull);
      expect(normalizeTrack(null), isNull);
      expect(normalizeTrack('not a map'), isNull);
    });

    test('空标题退回「未知曲目」，首尾空白去掉', () {
      final t = normalizeTrack({'id': '1', 'src': 'x', 'title': '  十年  '})!;
      expect(t.title, '十年');
      final blank = normalizeTrack({'id': '1', 'src': 'x', 'title': '   '})!;
      expect(blank.title, '未知曲目');
    });

    test('artist/album/cover 非字符串或空白一律空串', () {
      final t = normalizeTrack({
        'id': '1',
        'src': 'x',
        'title': 'a',
        'artist': 123,
        'album': '',
        'cover': '   ',
      })!;
      expect(t.artist, '');
      expect(t.album, '');
      expect(t.cover, '');
    });

    // 以下三组的样例都补了 title：原版 isTrackLike 要求 title 必须是字符串
    // （src/lib/playlist.js:47-54），缺了会被判非法返回 null，不是清洗逻辑的问题。
    test('duration 只有正有限数保留，其余 NaN', () {
      expect(
        normalizeTrack({
          'id': '1',
          'src': 'x',
          'title': 'x',
          'duration': 213.2,
        })!.duration,
        213.2,
      );
      expect(
        normalizeTrack({'id': '1', 'src': 'x', 'title': 'x', 'duration': 0})!
            .duration
            .isNaN,
        isTrue,
      );
      expect(
        normalizeTrack({'id': '1', 'src': 'x', 'title': 'x', 'duration': -3})!
            .duration
            .isNaN,
        isTrue,
      );
      expect(
        normalizeTrack({'id': '1', 'src': 'x', 'title': 'x', 'duration': '80'})!
            .duration
            .isNaN,
        isTrue,
      );
    });

    test('lyrics 截到 64KB，lyricsSource 只认 auto/manual', () {
      final long = 'a' * (kMaxLyricsLength + 100);
      final t = normalizeTrack({
        'id': '1',
        'src': 'x',
        'title': 'x',
        'lyrics': long,
        'lyricsSource': 'manual',
      })!;
      expect(t.lyrics.length, kMaxLyricsLength);
      expect(t.lyricsSource, 'manual');
      expect(
        normalizeTrack({
          'id': '1',
          'src': 'x',
          'title': 'x',
          'lyricsSource': 'auto?',
        })!.lyricsSource,
        '',
      );
    });

    test('isLocal 只认真 true', () {
      expect(
        normalizeTrack({'id': '1', 'src': 'x', 'title': 'x', 'isLocal': 1})!
            .isLocal,
        isFalse,
      );
      expect(
        normalizeTrack({'id': '1', 'src': 'x', 'title': 'x', 'isLocal': true})!
            .isLocal,
        isTrue,
      );
    });

    test('toJson/fromJson 往返一致，copy 得到可改的独立对象', () {
      final t = normalizeTrack({
        'id': '1',
        'src': 'file:///a.flac',
        'title': '白玫瑰',
        'artist': '陈奕迅',
        'duration': 226.0,
        'isLocal': true,
        'handle': {'kind': 'file', 'path': '/a.flac'},
      })!;
      final back = Track.fromJson(t.toJson())!;
      expect(back.id, t.id);
      expect(back.title, '白玫瑰');
      expect(back.duration, 226.0);
      expect(back.handle.uri, 'file:///a.flac');
      final c = t.copy()..artist = 'Eason Chan';
      expect(t.artist, '陈奕迅');
      expect(c.artist, 'Eason Chan');
    });
  });

  group('TrackHandle', () {
    test('路径句柄给出 file URI 并可判存在', () async {
      final h = FilePathHandle('test/fixtures/absent.flac');
      expect(h.uri, startsWith('file://'));
      expect(await h.exists(), isFalse);
      expect(await h.sizeBytes(), isNull);
    });

    test('SAF 句柄原样保留 uri 与显示名', () {
      const uri = 'content://com.android.externalstorage.documents/tree/x';
      final h = SafUriHandle(uri, 'U盘');
      expect(h.uri, uri);
      expect(h.displayName, 'U盘');
      expect(TrackHandle.fromJson(h.toJson())!.uri, uri);
    });
  });
}
