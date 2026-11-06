// test/ui/panel_harness.dart
//
// 面板的测试装配壳：真状态层 + 内存 prefs + 临时目录仓储，播放列表与最近
// 条目都是构造出来的假数据 —— 不读文件、不碰音频内核（`FakeAudioDriver`
// 只记调用，不会打开任何东西）。
//
// 为什么不塞 `lib/`：面板本身不该有「测试模式」分支。三个状态层都是真的，
// 面板看到的依赖与线上完全一致；只有两处假：播放列表的内容（由 [titles]
// 生成）和播放器要展示的两种常驻提示（[notice] / [circuitOpen]）——
// 后两者由子类覆写 getter 提供，不动真实状态。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/library/recent_store.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/panel_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/ui/panel.dart';

/// 一曲 226 秒：两条 = 452 秒 = `07:32`，统计行用例按这个值断言。
const double kHarnessDuration = 226;

class PanelHarness {
  PanelHarness({
    List<String> titles = const <String>[],
    int recentCount = 0,
    this.notice,
    this.circuitOpen = false,
    this.tall = false,
  }) : _directory = Directory.systemTemp.createTempSync('light-panel') {
    playlist = Playlist.fromTracks(<Track>[
      for (var i = 0; i < titles.length; i++)
        Track(
          id: '$i',
          src: '/$i.flac',
          title: titles[i],
          artist: '某人',
          album: '某专辑',
          duration: kHarnessDuration,
        ),
    ]);
    toasts = ToastState();
    library = LibraryState(
      prefs: AppPrefs.inMemory(),
      repo: LibraryRepository(directory: _directory.path),
      importer: ImportService(playlist: playlist, toasts: toasts),
      toasts: toasts,
    );
    player = _HarnessPlayer(
      playlist,
      notice: notice,
      breaker: circuitOpen,
    );
    recent = RecentState(RecentStore(AppPrefs.inMemory()));
    for (var i = 0; i < recentCount; i++) {
      recent.store.record(
        Track(
          id: 'r$i',
          src: '/r$i.flac',
          title: '旧歌$i',
          artist: '旧人',
          duration: 180,
        ),
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000 - i * 60000),
      );
    }
    // 历史里的 id 都不在当前列表里：刷新一次把「已失效」标出来（循环体是
    // 同步执行的，通知排在微任务里，首帧之前就已生效）。
    if (recentCount > 0) {
      unawaited(recent.refresh(const <String>{}));
    }
  }

  /// 面板内容区的高度。非 tall 时由外层约束（测试里是 700）决定。
  final bool tall;

  /// 播放器要展示的被拦文案；null 表示没有被拦。
  final String? notice;

  /// 熔断（全列表失败）状态。
  final bool circuitOpen;

  final Directory _directory;

  late final Playlist playlist;
  late final ToastState toasts;
  late final LibraryState library;
  late final PlayerState player;
  late final RecentState recent;

  Widget build() => MultiProvider(
    providers: [
      ChangeNotifierProvider<LibraryState>.value(value: library),
      ChangeNotifierProvider<PlayerState>.value(value: player),
      ChangeNotifierProvider<RecentState>.value(value: recent),
      ChangeNotifierProvider<PanelController>(create: (_) => PanelController()),
    ],
    child: SizedBox(height: tall ? 700 : null, child: const Panel()),
  );

  void dispose() {
    player.dispose();
    library.dispose();
    recent.dispose();
    toasts.dispose();
    if (_directory.existsSync()) {
      _directory.deleteSync(recursive: true);
    }
  }
}

/// 只覆写两条提示 getter 的播放器：其余行为全是真 [PlayerState]。
class _HarnessPlayer extends PlayerState {
  _HarnessPlayer(Playlist playlist, {this.notice, this.breaker = false})
    : super(
        prefs: AppPrefs.inMemory(),
        transport: TransportController(
          player: AudioPlayer(FakeAudioDriver()),
          recent: const _NoRecent(),
          toasts: const _NoToasts(),
          playlist: playlist,
        ),
      );

  final String? notice;
  final bool breaker;

  @override
  String? get blockedMessage => notice;

  @override
  bool get circuitOpen => breaker;
}

/// fake 内核用：不记最近播放。
class _NoRecent implements RecentRecorder {
  const _NoRecent();

  @override
  void record(Track track, {DateTime? at}) {}
}

/// fake 内核用：吞掉全部提示（面板自己的提示走 [PanelHarness.toasts]）。
class _NoToasts implements ToastSink {
  const _NoToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message) {}
}
