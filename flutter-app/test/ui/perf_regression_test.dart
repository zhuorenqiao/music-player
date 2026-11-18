// test/ui/perf_regression_test.dart
//
// Windows 卡顿那一轮修掉的几处，用**可断言的结构**钉住，防止以后被改回去。
//
// 为什么不用耗时断言：`flutter test` 的时钟是 FakeAsync，测不出真实光栅化
// 开销，拿 Stopwatch 只会写出一个在别人机器上必翻的脆弱用例。这里钉的是
// 「代价为什么低」的那个结构事实 —— 结构一没，性能就跟着没了：
//
//   1. 旋转的碟面必须把静止内容包进 RepaintBoundary（否则 60fps 重新光栅化
//      整张封面/生成卡）；
//   2. 磨砂膜噪点必须走 drawRawPoints，不能逐点 drawCircle（一次 vs 数千条
//      绘制指令）；
//   3. 歌词列表在「行号没变」的进度 tick 上必须复用同一个 widget 实例
//      （否则 4Hz 重建整棵树）；
//   4. 常驻动画的叶子（音柱 / 转圈 / 频谱条）各自隔离，别把祖先拖下水。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/cover_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/cover_thumb.dart';
import 'package:light_music/ui/glass_frost.dart';
import 'package:light_music/ui/lyrics_view.dart';
import 'package:light_music/ui/vinyl_deck.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';
import 'package:light_music/wave/wave_signal.dart';
import 'package:provider/provider.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

void main() {
  group('碟面旋转：静止内容必须被 RepaintBoundary 隔离', () {
    testWidgets('spinning 时碟面内容在 RepaintBoundary 之内', (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(
          const Center(
            child: CoverDisc(
              coverPath: '',
              size: 300,
              spinning: true,
              fallbackArtist: '周杰伦',
              fallbackTitle: '稻香',
            ),
          ),
        ),
      );
      await tester.pump();

      // 旋转层本身就是那颗 RepaintBoundary（它包住全部静止内容）。
      expect(
        find.descendant(
          of: find.byType(AnimatedBuilder),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
        reason: '旋转若没有隔离，60fps 会把整张碟面的光栅化重跑一遍',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('磨砂膜噪点：一条 drawRawPoints，不是几千条 drawCircle', () {
    testWidgets('frost>0 时 painter 里没有逐点 drawCircle', (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(
          const GlassFrostLayer(
            coverPath: '',
            frostLevel: 0.26,
            child: SizedBox(width: 700, height: 600),
          ),
        ),
      );
      await tester.pump();

      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<CustomPainter>()
          .firstWhere((p) => p.runtimeType.toString().contains('FrostMembrane'));
      expect(painter, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('CoverThumb：同一路径的存在性只 stat 一次', () {
    testWidgets('重复构建不会因 existsSync 退化成占位图', (tester) async {
      tester.view.physicalSize = const Size(300, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // 不存在的路径：阴性结果**不**缓存（线上预取会往目录里补文件），
      // 所以每次都要重新 stat —— 这条钉的是「阴性不缓存」这个语义。
      await tester.pumpWidget(
        wrap(
          const Center(
            child: CoverThumb(
              path: 'C:/__perf_no_such__/x.jpg',
              size: 44,
              fallbackArtist: '周杰伦',
              fallbackTitle: '稻香',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('CoverState：预取按批通知，不是每命中一首喊一次', () {
    test('prefetchCovers 在零命中时不通知', () async {
      final state = CoverState(
        json: _NeverJson(),
        bytes: _NeverBytes(),
        diskStore: CoverDiskStore(directory: ''),
        artistImageDirectory: '',
        sleep: (_) async {},
      );
      var notifications = 0;
      state.addListener(() => notifications += 1);
      await state.prefetchCovers(const []);
      expect(notifications, 0, reason: '空批不该产生任何通知');
    });
  });

  group('歌词列表：行号没变的进度 tick 必须复用同一个 widget 实例', () {
    testWidgets('同一条歌词内的 4Hz tick 不重建列表', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // 直接验 `LyricsView` 的缓存语义：同一个 position 区间内反复换 position
      // 值，`LyricsLinesView` 的 widget 实例必须自始至终是**同一个**。
      // 它一变，Flutter 就会把 60~120 行的整棵歌词树重跑一遍 build ——
      // 实测 80 行时单帧 20~30ms，直接超掉 16.6ms 的帧预算。
      final track = Track(
        id: 't1',
        title: '测试歌曲',
        artist: '测试歌手',
        src: 'x',
        // 一行 10 秒、共 20 行：0~1.6 秒全程停在第 0 行。
        lyrics: List.generate(
          20,
          (i) => '[${(i * 10).toString().padLeft(2, '0')}:00.00]第 $i 行',
        ).join('\n'),
      );
      final transport = TransportController(
        player: AudioPlayer(FakeAudioDriver()),
        recent: const _NullRecent(),
        toasts: const _SilentToasts(),
        playlist: Playlist.fromTracks([track]),
      );
      final player = PlayerState(prefs: AppPrefs.inMemory(), transport: transport);
      addTearDown(player.dispose);
      final lyrics = LyricsState(source: _NoMatch());
      final bilingual = BilingualState(lyrics: lyrics, source: _NoTranslation());
      lyrics.attach(track);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LyricsState>.value(value: lyrics),
            ChangeNotifierProvider<BilingualState>.value(value: bilingual),
            ChangeNotifierProvider<PlayerState>.value(value: player),
            ChangeNotifierProvider<ThemeState>.value(value: ThemeState.unloaded()),
          ],
          child: MaterialApp(
            theme: buildTheme().copyWith(
              extensions: const [AppTokensData(tokens: AppTokens.dark)],
            ),
            home: const Scaffold(
              body: SizedBox(
                width: 700,
                height: 500,
                child: LyricsView(variant: LyricsVariant.compact),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final first = tester.widget<LyricsLinesView>(find.byType(LyricsLinesView));
      for (var i = 0; i < 8; i++) {
        // 0.2 秒的步进：一行歌词 10 秒长，全程都停在第 0 行。
        player.position.value = 0.2 * i;
        await tester.pump();
      }
      final after = tester.widget<LyricsLinesView>(find.byType(LyricsLinesView));
      expect(
        identical(first, after),
        isTrue,
        reason: '行号没变却换了 widget 实例 → 每 tick 重建整棵歌词树',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('频谱条：每帧只重绘，不重建、不分配', () {
    testWidgets('播放中连续 vsync 不替换 CustomPaint 实例', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final track = Track(id: 't1', title: '测试歌曲', src: 'x', duration: 120);
      await tester.pumpWidget(
        ChangeNotifierProvider<ThemeState>.value(
          value: ThemeState.unloaded(),
          child: wrap(
            Center(
              child: SizedBox(
                width: 360,
                child: WaveStrip(
                  frameTable: _frameTable(),
                  track: track,
                  playing: true,
                  positionSeconds: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final mask = find.byKey(const Key('wave-fade-mask'));
      CustomPaint paint() => tester.widget<CustomPaint>(
        find.descendant(of: mask, matching: find.byType(CustomPaint)),
      );
      final first = paint();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        identical(first, paint()),
        isTrue,
        reason: '每帧换了 CustomPaint 实例 → 每个 vsync 都在重建整棵子树',
      );
      expect(tester.takeException(), isNull);
    });

    test('连续取帧复用同一块缓冲（每帧零分配）', () {
      final source = WaveSource()..attach(_frameTable(), 't1');
      WaveFrame read(double t) => source.read(
        playing: true,
        positionSeconds: t,
        phase: t,
        dt: 1 / 60,
        track: Track(id: 't1', title: '测试歌曲', src: 'x', duration: 120),
        bandCount: 90,
        waveCount: 360,
        width: 360,
        height: kWaveStripHeight,
      );
      final a = read(0);
      final b = read(0.05);
      expect(identical(a.bands, b.bands), isTrue);
      expect(identical(a.wave, b.wave), isTrue);
    });

    test('暂停复用最后一帧真实数据（不再拷贝冻结帧）', () {
      final source = WaveSource()..attach(_frameTable(), 't1');
      WaveFrame read(double t, {required bool playing}) => source.read(
        playing: playing,
        positionSeconds: t,
        phase: t,
        dt: 1 / 60,
        track: Track(id: 't1', title: '测试歌曲', src: 'x', duration: 120),
        bandCount: 90,
        waveCount: 360,
        width: 360,
        height: kWaveStripHeight,
      );
      final live = List<double>.of(read(0.4, playing: true).bands);
      final paused = read(9.9, playing: false);
      expect(paused.live, isTrue);
      for (var i = 0; i < live.length; i++) {
        expect(paused.bands[i], closeTo(live[i], 1e-6));
      }
    });
  });
}

/// 一张最小但形状可辨的帧表（20fps、64 段）。
SpectrumFrameTable _frameTable() {
  const frames = 240;
  final bands = Uint8List(frames * 64);
  for (var f = 0; f < frames; f++) {
    for (var b = 0; b < 64; b++) {
      bands[f * 64 + b] = (30 + 200 * ((f + b) % 7) / 7).round();
    }
  }
  return SpectrumFrameTable(
    sampleRate: 44100,
    frameMs: 50,
    frameCount: frames,
    bands: bands,
    wave: Int8List(frames * 128),
  );
}

class _NullRecent implements RecentRecorder {
  const _NullRecent();
  @override
  void record(Track track, {DateTime? at}) {}
}

class _SilentToasts implements ToastSink {
  const _SilentToasts();
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}
  @override
  void info(String message) {}
  @override
  void error(String message, {int durationMs = 3200}) {}
}

class _NoMatch implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async => const LyricsMatch(status: 'not-found');
}

class _NoTranslation implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async => const TranslationResult(status: 'not-found');
}

class _NeverJson implements HttpJsonClient {
  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async => JsonStatus(503);
}

class _NeverBytes implements ImageBytesClient {
  @override
  Future<ImageBytesOutcome> getBytes(
    Uri url, {
    required Duration timeout,
  }) async => ImageBytesStatus(503);
}
