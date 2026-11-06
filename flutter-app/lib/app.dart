// lib/app.dart
//
// 应用根：组合根的产物 [AppBootstrap] + 界面装配（provider / 主题 / 路由）。
//
// 界面层不 new 任何业务对象：`main()` 把 [AppBootstrap] 建好注入，这里只负责
// 注册给 provider 并挂上骨架页。provider 放在 `MaterialApp` **外面**（与原版
// Context 的位置一致），后续任何页面 / 弹层都能 `context.watch` 到同一份实例。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_prefs.dart';
import 'core/shortcuts.dart';
import 'library/import_service.dart';
import 'library/library_repository.dart';
import 'library/recent_store.dart';
import 'playback/media_session_bridge.dart' show MediaSessionCoordinator;
import 'playback/playlist.dart';
import 'playback/transport_controller.dart';
import 'state/library_state.dart';
import 'state/panel_controller.dart';
import 'state/player_state.dart';
import 'state/recent_state.dart';
import 'state/toast_state.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';
import 'ui/home_page.dart';
import 'ui/toasts.dart';

/// 组合根的构造结果。界面层从这里取对象，不自己 new 业务单例。
class AppBootstrap {
  AppBootstrap({
    required this.prefs,
    required this.repository,
    required this.library,
    required this.player,
    required this.recent,
    required this.toasts,
    required this.mediaSession,
    required this.notificationGranted,
    required this.notificationPermission,
  });

  final AppPrefs prefs;
  final LibraryRepository repository;

  /// 曲库（播放列表、搜索、导入、落库）。
  final LibraryState library;

  /// 播放器（进度 notifier、模式、音量、持久化时机）。
  final PlayerState player;

  /// 最近播放（薄包装，条目本体在 [RecentState.store]）。
  final RecentState recent;

  final ToastState toasts;

  /// 把系统侧动作接回 [TransportController] 的协调器；已在组合根里 attach 过，
  /// 界面层只持有引用，不需要再启动它。
  final MediaSessionCoordinator mediaSession;

  /// 通知权限是否可用。false 只影响通知栏 / 锁屏控件的可见性，不影响播放。
  ///
  /// 这是**首帧时**的快照：Android 上 `activate()` 的弹窗在 attach 里已经弹完，
  /// 所以通常就是用户的真实选择。它有两个不新鲜的时刻 —— 权限框的答复晚于
  /// attach 的 3 秒上限、以及用户后来在系统设置里改权限 —— 需要实时值时用
  /// [notificationPermission]（只查询、绝不弹窗）。
  final bool notificationGranted;

  /// 实时查询通知权限，不弹窗（申请归 `activate()`）。提示条用它。
  final Future<bool> Function() notificationPermission;

  /// 下面几个是状态层内部持有的原对象：界面层要用时不必知道它们被包在哪一层。
  Playlist get playlist => library.playlist;
  TransportController get transport => player.transport;
  ImportService get importer => library.importer;
  RecentStore get recentStore => recent.store;
}

/// 应用根：注册状态层给 provider，再挂主题、提示条与首页。
///
/// `.value` 不接管 dispose —— 这些状态在应用生命周期内常驻。
class LightMusicApp extends StatelessWidget {
  const LightMusicApp({required this.bootstrap, super.key});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryState>.value(value: bootstrap.library),
        ChangeNotifierProvider<PlayerState>.value(value: bootstrap.player),
        ChangeNotifierProvider<RecentState>.value(value: bootstrap.recent),
        ChangeNotifierProvider<ToastState>.value(value: bootstrap.toasts),
        // 面板的选中 tab 是纯界面态：不属于组合根，界面装配时建即可。
        // 放在路由之上，T29 的弹层复用同一份。
        ChangeNotifierProvider<PanelController>(create: (_) => PanelController()),
        Provider<AppPrefs>.value(value: bootstrap.prefs),
      ],
      child: MaterialApp(
        title: '流光音乐',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tokens: AppTokens.dark),
        // 提示条压在路由之上：任何页面 / 弹层看到的都是同一条，且不随页面重建
        // 丢失计时。`home` 只放骨架页，提示条不该由它自己挂。
        builder: (context, child) => Stack(
          children: [?child, const ToastsHost()],
        ),
        // 桌面快捷键（T30）：包在 HomePage 外面、路由里面 —— 弹层与对话框自带
        // 焦点域，按键不会从它们背后漏到播放器上（与原版「弹层开着时只认 Esc」
        // 同一效果）。提示条宿主在 Stack 的另一支上，语义 liveRegion 不受影响。
        home: withAppShortcuts(
          playerCallback: (name, [arg]) {
            final player = bootstrap.player;
            switch (name) {
              case 'togglePlay':
                unawaited(player.togglePlay());
              case 'seekBy':
                unawaited(player.seekBy(arg! as double));
              case 'volumeBy':
                // 与原版同一句：Math.min/max 夹在 0~1，步长由快捷键层给
                unawaited(
                  player.setVolume((player.volume + (arg! as double)).clamp(0.0, 1.0)),
                );
              case 'toggleMute':
                unawaited(player.toggleMute());
            }
          },
          child: const HomePage(),
        ),
      ),
    );
  }
}