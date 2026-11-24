// test/state/media_refresh_state_test.dart
//
// 「重新获取全部封面与歌词」的行为合同：
//   * 手动歌词（lyricsSource == 'manual'）只统计、不覆盖；
//   * 其余曲目一律 useCache:false 强制重查，命中覆盖旧自动歌词；
//   * 内嵌封面不参与在线封面刷新（文件自带图优先）；
//   * 两批并发只跑一批；离线短路；跑完统一落库一次；
//   * 新导入批次在标签 / 时长回填收敛之后才交给预加载钩子（不是入列那一刻）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/library/duration_probe.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/cover_state.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/media_refresh_state.dart';
import 'package:light_music/state/toast_state.dart';

import '../metadata/tag_fixtures.dart';

const LyricsMatch _syncedOk = LyricsMatch(
  status: 'ok',
  synced: '[00:01.00] 新歌词',
  source: 'LRCLIB',
);

/// 记录每次调用的查询与 useCache，并按 id 返回固定结果。
class _RecordingMatcher implements LyricsMatcher {
  _RecordingMatcher({this.gate});

  final Completer<void>? gate;
  final List<LyricsQuery> calls = <LyricsQuery>[];
  final List<bool> useCacheFlags = <bool>[];

  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    calls.add(query);
    useCacheFlags.add(useCache);
    if (gate != null && calls.length == 1) {
      await gate!.future;
    }
    return _syncedOk;
  }
}

/// 只验「调了哪些曲目、命中几首」，不碰网络。
class _FakeCoverState extends CoverState {
  _FakeCoverState(String directory)
    : super(
        json: const _NoJson(),
        bytes: const _NoBytes(),
        diskStore: CoverDiskStore(directory: directory),
        artistImageDirectory: directory,
      );

  final List<CoverPrefetchItem> refreshed = <CoverPrefetchItem>[];
  int matched = 0;

  @override
  Future<int> refreshAllCovers(
    List<CoverPrefetchItem> tracks, {
    void Function(int done)? onMatched,
  }) async {
    refreshed.addAll(tracks);
    for (var i = 1; i <= tracks.length; i++) {
      final item = tracks[i - 1];
      debugSeedMatched(item.trackId, '/net/$i.jpg');
      matched = i;
      onMatched?.call(i);
    }
    return tracks.length;
  }
}

class _NoJson implements HttpJsonClient {
  const _NoJson();

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async => const JsonNetwork();
}

class _NoBytes implements ImageBytesClient {
  const _NoBytes();

  @override
  Future<ImageBytesOutcome> getBytes(
    Uri url, {
    required Duration timeout,
  }) async => const ImageBytesNetwork();
}

/// ID3v2.3 标签 + 一段 MPEG 帧，像真音频（与 import_service_test 同一造法）。
List<int> withId3(List<List<int>> frames) => [...id3v2(frames), ...mpegFrame()];

class _CountingRepository extends LibraryRepository {
  _CountingRepository({required super.directory});

  int saves = 0;

  @override
  Future<void> save(LibrarySnapshot snapshot) {
    saves += 1;
    return super.save(snapshot);
  }
}

Track track(
  String id, {
  String title = '十年',
  String artist = '陈奕迅',
  String cover = '',
  String lyrics = '',
  String lyricsPlain = '',
  String lyricsSource = '',
}) => Track(
  id: id,
  src: '/m/$id.flac',
  title: title,
  artist: artist,
  duration: 210,
  isLocal: true,
  cover: cover,
  lyrics: lyrics,
  lyricsPlain: lyricsPlain,
  lyricsSource: lyricsSource,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaRefreshState.refreshAll', () {
    late Directory dir;
    late ToastState toasts;
    late LibraryState library;
    late _FakeCoverState cover;
    late _CountingRepository repo;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('light-media-refresh');
      toasts = ToastState();
      repo = _CountingRepository(directory: dir.path);
      final playlist = Playlist.fromTracks(<Track>[
        track('auto', lyrics: '旧歌词', lyricsSource: 'auto'),
        track('manual', lyrics: '手动歌词', lyricsSource: 'manual'),
        track('embedded', cover: '/embedded.jpg'),
        track('plain'),
      ]);
      library = LibraryState(
        prefs: AppPrefs.inMemory(),
        repo: repo,
        importer: ImportService(playlist: playlist, toasts: toasts),
        toasts: toasts,
      );
      cover = _FakeCoverState(dir.path);
    });

    tearDown(() {
      library.dispose();
      cover.dispose();
      toasts.dispose();
      dir.deleteSync(recursive: true);
    });

    MediaRefreshState build({LyricsMatcher? matcher, bool online = true}) =>
        MediaRefreshState(
          library: library,
          cover: cover,
          matcher: matcher ?? _RecordingMatcher(),
          toasts: toasts,
          sleep: (_) async {},
          isOnline: () => online,
        );

    test('手动歌词不覆盖；其余强制重查；内嵌封面不参与在线刷新；只落一次库', () async {
      final matcher = _RecordingMatcher();
      final refresh = build(matcher: matcher);

      final result = await refresh.refreshAll();

      expect(result, isNotNull);
      expect(matcher.calls.length, 3, reason: 'manual 跳过，其余三首都查');
      expect(matcher.useCacheFlags, everyElement(isFalse), reason: '强制绕过缓存');
      expect(result!.lyrics, 3);
      expect(result.manual, 1);
      expect(result.covers, 3, reason: 'auto/manual/plain 都参与封面刷新');

      expect(library.playlist.byId('auto')!.lyrics, '[00:01.00] 新歌词');
      expect(library.playlist.byId('auto')!.lyricsSource, 'auto');
      expect(
        library.playlist.byId('manual')!.lyrics,
        '手动歌词',
        reason: '手动歌词是权威来源，刷新不许覆盖',
      );
      expect(library.playlist.byId('plain')!.lyrics, '[00:01.00] 新歌词');

      expect(cover.refreshed.map((item) => item.trackId).toSet(), <String>{
        'auto',
        'manual',
        'plain',
      }, reason: '内嵌封面不请求在线图');
      expect(repo.saves, 1, reason: '整批只落一次库');
      expect(refresh.busy, isFalse);
      expect(refresh.progress, isEmpty);
      expect(toasts.items.last.message, contains('歌词 3 首'));
    });

    test('并发两批共用同一次刷新', () async {
      final gate = Completer<void>();
      final matcher = _RecordingMatcher(gate: gate);
      final refresh = build(matcher: matcher);

      final first = refresh.refreshAll();
      final second = refresh.refreshAll();
      expect(refresh.busy, isTrue);
      gate.complete();
      await Future.wait(<Future<MediaRefreshResult?>>[first, second]);

      expect(matcher.calls.length, 3, reason: '第二批不应再发一轮');
    });

    test('离线直接短路：不查歌词、不查封面，提示错误', () async {
      final matcher = _RecordingMatcher();
      final refresh = build(matcher: matcher, online: false);

      final result = await refresh.refreshAll();

      expect(result, isNull);
      expect(matcher.calls, isEmpty);
      expect(cover.refreshed, isEmpty);
      expect(refresh.busy, isFalse);
      expect(toasts.items.last.kind, ToastKind.error);
    });
  });

  group('LibraryState.onTracksImported', () {
    late Directory dir;
    late AppPrefs prefs;
    late ToastState toasts;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('light-import-prefetch');
      prefs = AppPrefs.inMemory();
      toasts = ToastState();
    });

    tearDown(() {
      toasts.dispose();
      dir.deleteSync(recursive: true);
    });

    File taggedFile(String name, List<List<int>> frames) {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(withId3(frames));
      return file;
    }

    test('回填收敛后才把新批次交给预加载钩子（标题已纠正、时长已补）', () async {
      final playlist = Playlist(tracks: const []);
      final state = LibraryState(
        prefs: prefs,
        repo: LibraryRepository(directory: dir.path),
        importer: ImportService(
          playlist: playlist,
          toasts: toasts,
          durationProbe: (path) async => const DurationProbeOutcome(187.5),
        ),
        toasts: toasts,
      );
      addTearDown(state.dispose);
      final seen = <Track>[];
      state.onTracksImported = (tracks) async => seen.addAll(tracks);

      final file = taggedFile('陈奕迅 - 十年.mp3', [
        textFrame('TIT2', '白玫瑰'),
        textFrame('TPE1', '陈奕迅'),
      ]);
      await state.importPaths([file.path]);
      await state.importPrefetchSettled;

      expect(seen, hasLength(1));
      expect(seen.single.title, '白玫瑰', reason: '标签纠正完成后才预取');
      expect(seen.single.duration, 187.5, reason: '时长探针也要收敛');
    });

    test('没有接钩子时导入照常返回，不产生额外任务', () async {
      final playlist = Playlist(tracks: const []);
      final state = LibraryState(
        prefs: prefs,
        repo: LibraryRepository(directory: dir.path),
        importer: ImportService(playlist: playlist, toasts: toasts),
        toasts: toasts,
      );
      addTearDown(state.dispose);

      final file = taggedFile('a.mp3', [textFrame('TIT2', '甲')]);
      await state.importPaths([file.path]);
      await state.importPrefetchSettled;

      expect(state.tracks, hasLength(1));
    });
  });
}
