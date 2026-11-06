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
      // src 与 title 相反：原样透传，既不 trim 也不改写（playlist.js:75）。
      final raw = normalizeTrack({
        'id': '1',
        'src': ' file:///十年.flac ',
        'title': 'x',
      })!;
      expect(raw.src, ' file:///十年.flac ');
      expect(t.src, 'x');
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
      // hasRealCover 就是 cover 非空：清洗后为空串即「没有真封面」。
      expect(t.hasRealCover, isFalse);
      expect(
        normalizeTrack({
          'id': '1',
          'src': 'x',
          'title': 'x',
          'cover': ' cover.jpg ',
        })!.hasRealCover,
        isTrue,
      );
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
      // NaN 写存档时是 null，读回来仍然是 NaN（不会被悄悄当成 0 秒）。
      final lost = normalizeTrack({
        'id': '1',
        'src': 'x',
        'title': 'x',
        'duration': -3,
      })!;
      expect(lost.toJson()['duration'], isNull);
      expect(Track.fromJson(lost.toJson())!.duration.isNaN, isTrue);
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
      // 原版是精确比较（playlist.js:87 `=== 'auto'`），带空白的值不认，
      // 也不允许 Dart 侧先 trim 再把 ' auto ' 放成 'auto'。
      expect(
        normalizeTrack({
          'id': '1',
          'src': 'x',
          'title': 'x',
          'lyricsSource': ' auto ',
        })!.lyricsSource,
        '',
      );
      expect(
        normalizeTrack({
          'id': '1',
          'src': 'x',
          'title': 'x',
          'lyricsSource': 'auto',
        })!.lyricsSource,
        'auto',
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
      expect(back.src, 'file:///a.flac');
      final c = t.copy()..artist = 'Eason Chan';
      expect(t.artist, '陈奕迅');
      expect(c.artist, 'Eason Chan');

      // handle 字段缺失时退回 FilePathHandle(src)，且 _toFileUri 的「已是 URI
      // 就原样返回」这一支不能被二次编码：Android content:// 的恢复路径靠它。
      final noHandle = normalizeTrack({
        'id': '1',
        'src': 'file:///a.flac',
        'title': 't',
      })!;
      expect(noHandle.handle, isA<FilePathHandle>());
      expect(noHandle.handle.uri, 'file:///a.flac');
      expect(
        normalizeTrack({'id': '1', 'src': 'content://x/y', 'title': 't'})!
            .handle
            .uri,
        'content://x/y',
      );
      // handle 是畸形 Map（kind 未知）时同样退回 FilePathHandle(src)，不抛。
      final badHandle = normalizeTrack({
        'id': '1',
        'src': '/music/b.flac',
        'title': 't',
        'handle': {'kind': 'nope'},
      })!;
      expect(badHandle.handle, isA<FilePathHandle>());
      // handle 是「键类型不是 String」的 Map 时，cast 视图读 String 键也不抛。
      final weirdKeys = normalizeTrack({
        'id': '1',
        'src': 'x',
        'title': 't',
        'handle': <Object, Object>{'kind': 'file', 'path': '/a.flac'},
      })!;
      expect(weirdKeys.handle.uri, 'file:///a.flac');
    });
  });

  group('TrackHandle', () {
    test('路径句柄给出 file URI 并可判存在', () async {
      final h = FilePathHandle('test/fixtures/absent.flac');
      expect(h.uri, startsWith('file://'));
      expect(await h.exists(), isFalse);
      expect(await h.sizeBytes(), isNull);

      // 脏存档契约：fromJson 对坏字段返回 null，绝不抛类型异常
      // （这条一路被 LibrarySnapshot.fromJson → load() 无保护地调用）。
      expect(TrackHandle.fromJson({'kind': 'file', 'path': ''}), isNull);
      expect(TrackHandle.fromJson({'kind': 'file'}), isNull);
      expect(TrackHandle.fromJson({'kind': 'file', 'path': 42}), isNull);
      expect(TrackHandle.fromJson({'kind': 'unknown'}), isNull);
      expect(TrackHandle.fromJson({}), isNull);
      expect(TrackHandle.fromJson(null), isNull);
    });

    test('SAF 句柄原样保留 uri 与显示名', () {
      const uri = 'content://com.android.externalstorage.documents/tree/x';
      final h = SafUriHandle(uri, 'U盘');
      expect(h.uri, uri);
      expect(h.displayName, 'U盘');
      expect(TrackHandle.fromJson(h.toJson())!.uri, uri);

      expect(TrackHandle.fromJson({'kind': 'saf', 'uri': ''}), isNull);
      expect(TrackHandle.fromJson({'kind': 'saf'}), isNull);
      expect(TrackHandle.fromJson({'kind': 'saf', 'uri': 42}), isNull);
      // name 是数字时不抛 TypeError，退回空显示名。
      final dirty = TrackHandle.fromJson({
        'kind': 'saf',
        'uri': uri,
        'name': 7,
      });
      expect(dirty, isNotNull);
      expect(dirty!.displayName, '');
      expect(dirty.uri, uri);
      // 同一个脏字段经 Track.fromJson → normalizeTrack 读回也不抛。
      final t = Track.fromJson({
        'id': '1',
        'src': uri,
        'title': 'x',
        'handle': {'kind': 'saf', 'uri': uri, 'name': 7},
      })!;
      expect(t.handle.displayName, '');
      expect(t.handle.uri, uri);
    });
  });
}
