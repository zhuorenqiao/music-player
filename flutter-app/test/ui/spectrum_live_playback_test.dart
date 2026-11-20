// test/ui/spectrum_live_playback_test.dart
//
// 「手动切歌 / 自动续播之后频谱条不律动」那一轮回归。
//
// 结构事实：控制条（[TransportBar]）在首页是 `const`，整条**不订阅** PlayerState
// （见 transport.dart 头部的订阅纪律），`WaveStrip.playing` 只是 build 时顺手读的
// `player.view.value.playing` 快照。于是：
//
//   * 换曲时 SpectrumState 会 notify（清表 / 表到货），控制条跟着重建一次 ——
//     这一次读到的 `playing` 往往是 false（内核还在 open，播放事件还没回来）；
//   * 等内核真的出声（playing=true）时，**没有任何东西会再重建控制条**，
//     于是 `WaveStrip.playing` 永远停在 false：ticker 不跑、`read(playing:false)`
//     冻住最后一帧 —— 用户看到的就是「不律动了」。
//
// 这里钉两件事：
//   1. 播放态变化必须自己走到频谱条（不依赖父级恰好重建）；
//   2. 切歌 + 播放态晚到之后，频谱条的画面必须真的在动（像素级）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/lyrics_page_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/spectrum_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/transport.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';
import 'package:provider/provider.dart';

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

/// 帧表：240 帧、每帧 64 段，段值随时间变化 —— 不同位置的帧画面必然不同。
SpectrumFrameTable _table() {
  const frames = 240;
  final bands = Uint8List(frames * 64);
  for (var f = 0; f < frames; f++) {
    for (var b = 0; b < 64; b++) {
      final shape = 1 - ((b - 20).abs() / 44.0);
      bands[f * 64 + b] =
          (15 + 220 * shape * (0.25 + 0.75 * ((f * 9 + b * 5) % 17) / 16))
              .round()
              .clamp(0, 255);
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

/// 缓存全命中（真机曲库已预热），request 也立刻给表 —— 与真机一致。
class _CachedSource implements SpectrumSource {
  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) async =>
      _table();

  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) async => _table();
}

const _shotKey = Key('spectrum-live-shot');

void main() {
  testWidgets('播控语义变化自己走到频谱条：不靠父级重建', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 420);

    final tracks = <Track>[
      Track(id: 't1', src: r'D:\m\t1.flac', title: '一', duration: 200),
      Track(id: 't2', src: r'D:\m\t2.flac', title: '二', duration: 180),
    ];
    final driver = FakeAudioDriver();
    final player = PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(driver),
        recent: const _NullRecent(),
        toasts: const _SilentToasts(),
        playlist: Playlist.fromTracks(tracks),
      ),
    );
    addTearDown(player.dispose);
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);
    final spectrum = SpectrumState(source: _CachedSource());
    addTearDown(spectrum.dispose);
    final theme = ThemeState.unloaded();
    addTearDown(theme.dispose);

    // 装配层那两条联动（与 main.dart 一致）。
    void syncTrack() => spectrum.setCurrent(player.current);
    player.view.addListener(syncTrack);
    void syncVisible() => spectrum.setVisible(page.isOpen);
    page.addListener(syncVisible);
    addTearDown(() => player.view.removeListener(syncTrack));
    addTearDown(() => page.removeListener(syncVisible));
    // 与 main.dart 一致：接线完成后立刻同步一次当前曲目与可见性。
    syncTrack();
    syncVisible();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerState>.value(value: player),
          ChangeNotifierProvider<LyricsPageController>.value(value: page),
          ChangeNotifierProvider<SpectrumState>.value(value: spectrum),
          ChangeNotifierProvider<ThemeState>.value(value: theme),
        ],
        child: MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.dark)],
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 1200,
                child: RepaintBoundary(
                  key: _shotKey,
                  child: const TransportBar(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await player.playTrack('t1');
    await tester.pump();
    await tester.pump();
    final strip = tester.widget<WaveStrip>(find.byType(WaveStrip));
    expect(strip.playing, isTrue, reason: '首曲已出声，频谱条应处于播放态');

    // 暂停：**不重建父级**，只让内核自己发 playing(false)。
    driver.emitPlaying(false);
    await tester.pump();
    expect(
      tester.widget<WaveStrip>(find.byType(WaveStrip)).playing,
      isFalse,
      reason: '父级没有重建时，频谱条也必须收到「已暂停」（否则暂停后还在动）',
    );
    driver.emitPlaying(true);
    await tester.pump();
    expect(tester.widget<WaveStrip>(find.byType(WaveStrip)).playing, isTrue);

    // 把 PlayerState 那 400ms 的落盘防抖放掉（否则测试结束时报 pending timer）。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('切歌：表到货先于播放态，之后画面必须仍然在动', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 420);

    final tracks = <Track>[
      Track(id: 't1', src: r'D:\m\t1.flac', title: '一', duration: 200),
      Track(id: 't2', src: r'D:\m\t2.flac', title: '二', duration: 180),
    ];
    final driver = FakeAudioDriver();
    final player = PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(driver),
        recent: const _NullRecent(),
        toasts: const _SilentToasts(),
        playlist: Playlist.fromTracks(tracks),
      ),
    );
    addTearDown(player.dispose);
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);
    final spectrum = SpectrumState(source: _CachedSource());
    addTearDown(spectrum.dispose);
    final theme = ThemeState.unloaded();
    addTearDown(theme.dispose);

    void syncTrack() => spectrum.setCurrent(player.current);
    player.view.addListener(syncTrack);
    void syncVisible() => spectrum.setVisible(page.isOpen);
    page.addListener(syncVisible);
    addTearDown(() => player.view.removeListener(syncTrack));
    addTearDown(() => page.removeListener(syncVisible));
    // 与 main.dart 一致：接线完成后立刻同步一次当前曲目与可见性。
    syncTrack();
    syncVisible();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerState>.value(value: player),
          ChangeNotifierProvider<LyricsPageController>.value(value: page),
          ChangeNotifierProvider<SpectrumState>.value(value: spectrum),
          ChangeNotifierProvider<ThemeState>.value(value: theme),
        ],
        child: MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.dark)],
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 1200,
                child: RepaintBoundary(
                  key: _shotKey,
                  child: const TransportBar(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await player.playTrack('t1');
    driver.emitPosition(30);
    await tester.pump();
    await tester.pump();

    // 切到第二首：内核 open 会先发 playing(false)，随后才真的出声。
    await player.next();
    await tester.pump();
    await tester.pump();
    // 表已经到货（缓存命中），但播放态晚到：此刻内核还没出声。
    driver.emitPlaying(false);
    await tester.pump();
    driver.emitPosition(0.2);
    await tester.pump();
    // 真正出声 —— 这一步**不会**触发任何父级重建。
    driver.emitPlaying(true);
    await tester.pump();
    driver.emitPosition(0.4);
    await tester.pump();

    final strip = tester.widget<WaveStrip>(find.byType(WaveStrip));
    expect(strip.playing, isTrue, reason: '已经出声，频谱条必须是播放态');
    expect(strip.track?.id, 't2', reason: '频谱条要跟着换到第二首');
    expect(strip.frameTable, isNotNull, reason: '缓存命中，帧表应已挂上');

    // 像素级：相隔 200ms 的两帧必须不同（= ticker 在跑、不是冻在最后一帧）。
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_shotKey),
    );
    Future<Uint8List> shot() async {
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return bytes!;
    }

    final a = await shot();
    driver.emitPosition(0.6);
    await tester.pump(const Duration(milliseconds: 120));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final b = await shot();
    expect(
      listEquals(a, b),
      isFalse,
      reason: '切歌之后频谱条停在同一帧 → 用户看到的「不律动」',
    );

    await tester.pump(const Duration(milliseconds: 500));
  });
}


