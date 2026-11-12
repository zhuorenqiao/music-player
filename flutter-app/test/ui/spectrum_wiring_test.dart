// test/ui/spectrum_wiring_test.dart
//
// D.3 的端到端接线：SpectrumState 里的帧表必须真的流到歌词页的 WaveStrip，
// 而不是像接线前那样永远 `frameTable: null`。
//
// 这条不测渲染像素，只测「装配层把值传下去了」这个结构事实：
//   * 首页 WaveStrip 隐藏（既有行为，不回归）；
//   * 歌词页打开时 WaveStrip 出现，且拿到状态层里那张表；
//   * 状态层 notify 之后，WaveStrip 拿到新表（说明真的订阅了 provider）；
//   * 暂停时帧表到货也应触发重绘（_WavePainter.shouldRepaint 纳入表身份）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

SpectrumFrameTable _table() => SpectrumFrameTable(
      sampleRate: 44100,
      frameMs: 50,
      frameCount: 2,
      bands: Uint8List(2 * 64)..fillRange(0, 128, 120),
      wave: Int8List(2 * 128),
    );

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

/// 假源：缓存永远 miss，request 立刻返回一张表。
class _ImmediateSource implements SpectrumSource {
  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) async =>
      null;

  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) async =>
      _table();
}

/// 可控源：request 的结果由测试用 [complete] 给，用来精确验证
/// 「首帧还是装饰回退 → 到货通知后换成真实帧表」这一跳。
class _GatedSource implements SpectrumSource {
  final Completer<SpectrumFrameTable?> _gate =
      Completer<SpectrumFrameTable?>();

  void complete(SpectrumFrameTable? table) {
    if (!_gate.isCompleted) _gate.complete(table);
  }

  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) async =>
      null;

  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) =>
      _gate.future;
}

/// `testWidgets` 跑在 FakeAsync 里：`Future.delayed(Duration.zero)` 不会被
/// 自动推进，必须靠 `tester.pump()` 一帧一帧把微任务队列跑完。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('歌词页打开后，WaveStrip 拿到 SpectrumState 的真实帧表', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 320);

    final track = Track(
      id: 't1',
      src: '/music/t1.flac',
      title: '测试曲目',
      duration: 200,
    );
    final player = PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver()),
        recent: const _NullRecent(),
        toasts: const _SilentToasts(),
        playlist: Playlist.fromTracks([track]),
      ),
    );
    addTearDown(player.dispose);
    final page = LyricsPageController();
    addTearDown(page.dispose);
    final spectrum = SpectrumState(source: _ImmediateSource());
    addTearDown(spectrum.dispose);
    final theme = ThemeState.unloaded();
    addTearDown(theme.dispose);

    Widget app() => MultiProvider(
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
                child: SizedBox(width: 1200, child: const TransportBar()),
              ),
            ),
          ),
        );

    // 首页：WaveStrip 隐藏（app.css:1111）。
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(WaveStrip), findsNothing);

    // 打开歌词页 + 当前曲目就位（模拟装配层那两条联动）。
    spectrum.setCurrent(track);
    page.open();
    spectrum.setVisible(true);
    await _flush(tester);
    await tester.pumpWidget(app());
    await tester.pump();

    final strip = tester.widget<WaveStrip>(find.byType(WaveStrip));
    expect(strip.frameTable, isNotNull, reason: '帧表必须从 provider 流下来');
    expect(strip.frameTable, same(spectrum.frameTableFor('t1')));
    // 真实帧表按 positionSeconds 取帧，必须订阅进度 notifier。
    expect(strip.positionListenable, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态层到货后 WaveStrip 换成新表（provider 订阅生效）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 320);

    final track = Track(id: 't1', src: '/music/t1.flac', title: 'T');
    final player = PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver()),
        recent: const _NullRecent(),
        toasts: const _SilentToasts(),
        playlist: Playlist.fromTracks([track]),
      ),
    );
    addTearDown(player.dispose);
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);
    final source = _GatedSource();
    final spectrum = SpectrumState(source: source);
    addTearDown(spectrum.dispose);
    final theme = ThemeState.unloaded();
    addTearDown(theme.dispose);

    Widget app() => MultiProvider(
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
                child: SizedBox(width: 1200, child: const TransportBar()),
              ),
            ),
          ),
        );

    spectrum.setCurrent(track);
    spectrum.setVisible(true);
    await tester.pumpWidget(app());
    await tester.pump();
    // 首帧：解析还没回来，走装饰回退。
    expect(tester.widget<WaveStrip>(find.byType(WaveStrip)).frameTable, isNull);

    // 帧表到货 → SpectrumState.notifyListeners → WaveStrip 重建。
    source.complete(_table());
    await _flush(tester);
    await tester.pump();

    expect(
      tester.widget<WaveStrip>(find.byType(WaveStrip)).frameTable,
      isNotNull,
      reason: 'SpectrumState.notifyListeners 之后应自动换成真实帧表',
    );
    expect(tester.takeException(), isNull);
  });
}
