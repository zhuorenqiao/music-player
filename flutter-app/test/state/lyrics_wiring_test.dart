// test/state/lyrics_wiring_test.dart
//
// T15 装配闸口：组合根必须真的把 LyricsState / BilingualState 建出来、注册给
// provider、把还原出来的当前曲目挂上，并在切歌时联动；双语开关要落 prefs。
//
// 四个用例的替身都注入假的 matcher / fetcher，绝不打网络；driver / bridge 用
// 工程里随 lib 一起发布的现成替身（FakeAudioDriver / FakeMediaSessionBridge）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:provider/provider.dart';

class _Matcher implements LyricsMatcher {
  final List<String?> seen = [];

  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    seen.add(query.trackName);
    return const LyricsMatch(status: 'not-found');
  }
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const TranslationResult(
        status: 'not-found',
        reason: 'song-not-matched',
      );
}

Future<Directory> _tempDir() => Directory.systemTemp.createTemp('wiring-');

/// 永不使用 `Future.delayed` 的延时接缝：挂起的 Completer 不是 Timer，
/// testWidgets 收尾时不会因「pending Timer」挂住；同时 4s / 25s 两个
/// detached 回调永远不会到点，装配测试只关心「状态建出来、曲目挂上去」。
Future<void> Function(Duration) get _neverFire {
  final completer = Completer<void>();
  return (_) => completer.future;
}

void main() {
  testWidgets('组合根建出歌词与双语状态，并把还原出来的当前曲目挂上去', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('wiring-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();

    final matcher = _Matcher();
    // 组合根要读真实文件 / 跑真异步（repo.save、library.restore、媒体会话
    // attach 的 .timeout()）；testWidgets 跑在 FakeAsync 里，**任何** await
    // 真异步都会永远等不到头。全部塞进同一个 runAsync —— 与
    // test/state/app_bootstrap_test.dart 的同一条手法一致。
    final bootstrap = await tester.runAsync(
      () async {
        await LibraryRepository(directory: dir.path).save(
          LibrarySnapshot(
            tracks: [
              Track(
                id: 'a',
                src: '/m/a.flac',
                title: 'Yesterday',
                artist: 'The Beatles',
                duration: 125,
                // 非中文歌词：translatable 才为真（T13 的
                // `displayLines.isNotEmpty && needsTranslation(lyricsText)`）。
                // brief 那条用例的曲目没带歌词，却期望 translatable=true，
                // 与 T13 的既定实现不符 —— 这里按真实契约补上歌词。
                lyrics: '[00:01]Yesterday\n[00:05]All my troubles',
                lyricsSource: 'auto',
              ),
            ],
            order: ['a'],
            currentId: 'a',
          ),
        );
        return buildBootstrap(
          prefs: prefs,
          dataDirectory: dir.path,
          driver: FakeAudioDriver(),
          bridge: FakeMediaSessionBridge(),
          lyricsMatcher: matcher,
          translationFetcher: _Fetcher(),
          bilingualEnabled: true,
        );
      },
    );
    addTearDown(() => bootstrap!.player.dispose());

    expect(bootstrap!.lyrics.track?.id, 'a');
    expect(bootstrap.bilingual.translatable, isTrue);

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    expect(
      Provider.of<LyricsState>(context, listen: false),
      same(bootstrap.lyrics),
    );
    expect(
      Provider.of<BilingualState>(context, listen: false),
      same(bootstrap.bilingual),
    );
  });

  test('切歌时 attach 新曲目', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(
      LibrarySnapshot(
        tracks: [
          Track(id: 'a', src: '/m/a.flac', title: 'A', duration: 60),
          Track(id: 'b', src: '/m/b.flac', title: 'B', duration: 60),
        ],
        order: ['a', 'b'],
        currentId: 'a',
      ),
    );

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      lyricsDelay: _neverFire,
    );
    addTearDown(bootstrap.player.dispose);

    await bootstrap.player.next();
    await bootstrap.lyrics.settle();
    expect(bootstrap.lyrics.track?.id, 'b');
  });

  test('双语开关持久化到 StorageKeys.bilingual', () async {
    final prefs = AppPrefs.inMemory();
    final dir = await _tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      lyricsDelay: _neverFire,
      bilingualEnabled: true,
    );
    addTearDown(bootstrap.player.dispose);

    bootstrap.bilingual.setEnabled(false);
    expect(await prefs.readString(StorageKeys.bilingual), '0');
    bootstrap.bilingual.setEnabled(true);
    expect(await prefs.readString(StorageKeys.bilingual), '1');
  });

  test('默认开启：键从未写过时是开；显式写 0 才是关', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final prefs = AppPrefs.inMemory();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      lyricsDelay: _neverFire,
    );
    addTearDown(bootstrap.player.dispose);
    expect(bootstrap.bilingual.enabled, isTrue);

    final offPrefs = AppPrefs.inMemory();
    await offPrefs.writeString(StorageKeys.bilingual, '0');
    final dir2 = await _tempDir();
    addTearDown(() => dir2.delete(recursive: true));
    final off = await buildBootstrap(
      prefs: offPrefs,
      dataDirectory: dir2.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      lyricsDelay: _neverFire,
    );
    addTearDown(off.player.dispose);
    expect(off.bilingual.enabled, isFalse);
  });
}
