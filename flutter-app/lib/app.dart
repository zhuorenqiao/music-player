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
import 'cover/cover_disk_cache.dart';
import 'cover/cover_source.dart';
import 'library/duration_probe.dart';
import 'library/import_service.dart';
import 'library/library_repository.dart';
import 'library/recent_store.dart';
import 'playback/media_session_bridge.dart' show MediaSessionCoordinator;
import 'playback/playlist.dart';
import 'playback/transport_controller.dart';
import 'state/library_state.dart';
import 'state/bilingual_state.dart';
import 'state/cover_state.dart';
import 'state/lightbox_controller.dart';
import 'state/lyrics_page_controller.dart';
import 'state/lyrics_state.dart';
import 'state/panel_controller.dart';
import 'state/player_state.dart';
import 'state/recent_state.dart';
import 'state/sleep_timer_state.dart';
import 'state/spectrum_state.dart';
import 'state/toast_state.dart';
import 'lyrics/upstream.dart' show HttpJsonClient, HttpJsonClientImpl;
import 'wave/spectrum_pipeline.dart' show SpectrumFrameTable, SpectrumSource;
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';
import 'theme/theme_state.dart';
import 'ui/autoplay_gate.dart';
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
    this.durationProbe,
    required this.lyrics,
    required this.bilingual,
    required this.onLyricsViewChanged,
    LyricsPageController? lyricsPage,
    LightboxController? lightbox,
    CoverState? cover,
    VoidCallback? onCoverViewChanged,
    ThemeState? theme,
    SpectrumState? spectrum,
    VoidCallback? onSpectrumViewChanged,
    VoidCallback? onSpectrumVisibilityChanged,
    SleepTimerState? sleepTimer,
  }) : // 全屏歌词页的开合开关（T18 建、T19 接页面本体）。
       // 可空入参 + 在这里兜底建：`buildBootstrap` 传它（Stage 与 T19 的页面 /
       // 快捷键要共用同一份），测试里直接 new `AppBootstrap` 的路径也不必改。
       lyricsPage = lyricsPage ?? LyricsPageController(),
       // 封面放大层的开合开关（M2b T9）：曲目区 / 歌词页右栏的封面热区
       // `open()`，灯箱本体与 Esc `close()`。层叠在歌词页之上。
       lightbox = lightbox ?? LightboxController(),
       // 封面显示层（M2b T8/T6）：可空入参 + 兜底建，同 lyricsPage 的模式。
       // 测试直接 new AppBootstrap 时给一个离线 CoverState（假网络替身由
       // 测试自己装配；这里兜底只能给真实现的默认构造 —— 它的内核全懒建，
       // 不发请求就不会碰网络）。onCoverViewChanged 为 null 时兜底 no-op，
       // dispose 的 removeListener 相应跳过。
       cover =
           cover ??
           CoverState(
             json: _defaultCoverJson,
             bytes: ImageBytesClientImpl(),
             diskStore: CoverDiskStore(directory: ''),
             artistImageDirectory: '',
           ),
       onCoverViewChanged = onCoverViewChanged ?? (() {}),
       // 外观状态机（M3 T4/T5）：兜底用 unloaded（默认值，不读 prefs）——
       // 要验主题的测试自己传真实例。
       theme = theme ?? ThemeState.unloaded(),
       // D.3：实时频谱调度层。测试直接 new AppBootstrap 时给一个「源永远
       // 返回 null」的离线实例，不发请求就不碰平台通道，也不解码。
       spectrum = spectrum ?? SpectrumState(source: const _NullSpectrumSource()),
       onSpectrumViewChanged = onSpectrumViewChanged ?? (() {}),
       onSpectrumVisibilityChanged =
           onSpectrumVisibilityChanged ?? (() {}),
       // 睡眠定时器：可空入参 + 兜底建（同 lyricsPage 的模式）。测试直接 new
       // AppBootstrap 时不必管它；生产由 buildBootstrap 传真的那份，并在
       // runApp 之前 restore —— 把上次留下的截止时刻接回来。
       sleepTimer =
           sleepTimer ??
           SleepTimerState(prefs: prefs, player: player, toasts: toasts);

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

  /// 时长探测那台**独立**内核（终审 I1 接上的，不属于 [transport] 的主播放器）。
  ///
  /// 组合根必须持有它，理由不是「要用」而是「要关」：`MediaKitDurationOpener`
  /// 懒建一台 media_kit 的 `Player` 复用到底，从前没有任何释放点（终审 A2）。
  /// 现在由 [dispose] 关掉，[LightMusicApp] 卸载时调用。
  final DurationProbe? durationProbe;

  /// 歌词状态机（T13）。播放卡与歌词页共读它；匹配成功会经 `onChanged` 落库。
  final LyricsState lyrics;

  /// 双语状态机（T14）。转发 `lyrics.translatable`，自己管译文与三条生命周期规则。
  final BilingualState bilingual;

  /// `buildBootstrap` 挂在 `player.transport.view` 上的那个回调引用。
  /// [dispose] 要用**同一个函数对象**才能 `removeListener` 掉，不能另写一份闭包。
  final VoidCallback onLyricsViewChanged;

  /// 全屏歌词页的开合开关（T18 建、T19 消费）。
  ///
  /// **不是** `LyricsState` 的一部分：播放卡（T18）负责 `open()`，页面本体与
  /// overlay 槽（T19）负责 `close()` / 读 [LyricsPageController.isOpen]，
  /// 快捷键层再做 `toggle()`。三方读同一个 flag，所以只能有一份实例，归组合根。
  final LyricsPageController lyricsPage;

  /// 封面放大层的开合开关（M2b T9 建、T11 消费）。
  ///
  /// 层叠在歌词页之上：灯箱开着时 Esc 只关灯箱（App.tsx:1581-1591 的顶层
  /// 优先语义），歌词页保持其下渲染。**不是** `CoverState` 的一部分：灯箱是
  /// 纯界面态，与封面数据无关（[LyricsPageController] 同款裁定）——封面热区
  /// `open()`（T11），灯箱本体与 Esc `close()`，三方读同一个 flag。
  final LightboxController lightbox;

  /// 外观状态机（M3 T4/T5）：换肤 / 玻璃 / 波形 / 歌词色七维。
  final ThemeState theme;

  /// 封面显示层（M2b T6/T8）。resolver（coverForDisplay）、当前曲目在线
  /// 匹配、写真表与预取调度都在这一层；界面（Stage / Panel / 灯箱）只读它。
  final CoverState cover;

  /// `buildBootstrap` 挂在 `player.transport.view` 上的封面联动回调引用
  /// （切歌时对当前曲目 `matchFor`）。[dispose] 用它 removeListener，
  /// 同 [onLyricsViewChanged] 的「同一个函数对象」要求。
  final VoidCallback onCoverViewChanged;

  /// 实时频谱调度层（D.3）：歌词页的 WaveStrip 从这里取当前曲目的帧表。
  final SpectrumState spectrum;

  /// `buildBootstrap` 挂在 `player.transport.view` 上的频谱联动回调引用。
  final VoidCallback onSpectrumViewChanged;

  /// `buildBootstrap` 挂在 `LyricsPageController` 上的可见性联动回调引用。
  final VoidCallback onSpectrumVisibilityChanged;

  /// 睡眠定时器：到点暂停播放。控制条上的闹钟按钮与这一份读同一处状态。
  final SleepTimerState sleepTimer;

  /// 下面几个是状态层内部持有的原对象：界面层要用时不必知道它们被包在哪一层。
  Playlist get playlist => library.playlist;
  TransportController get transport => player.transport;
  ImportService get importer => library.importer;
  RecentStore get recentStore => recent.store;

  /// 释放组合根自己持有的原生资源与监听器。幂等，且绝不抛。
  ///
  /// 只管时长探测的内核与切歌联动的监听：四个状态层与
  /// [TransportController] 由各自的宿主（provider / 测试的 `addTearDown`）负责，
  /// 这里不越权去 dispose 它们，否则应用退出时会出现「先关掉播放器再关掉监听
  /// 它的界面」这种顺序问题。
  Future<void> dispose() async {
    player.transport.view.removeListener(onLyricsViewChanged);
    player.transport.view.removeListener(onCoverViewChanged);
    player.transport.view.removeListener(onSpectrumViewChanged);
    lyricsPage.removeListener(onSpectrumVisibilityChanged);
    // 频谱状态只关一次：ChangeNotifier.dispose() 在 debug 下重复调用会抛
    // 「已 dispose」断言，而这份 dispose 是**承诺幂等**的（测试里就调了两次）。
    if (!_spectrumDisposed) {
      _spectrumDisposed = true;
      spectrum.dispose();
    }
    await durationProbe?.close();
  }

  /// [spectrum] 是否已经 dispose 过（见 [dispose]）。
  bool _spectrumDisposed = false;
}

/// 离线兜底源：只在「测试直接 new AppBootstrap、没传 spectrumState」时用。
/// 永远返回 null，于是 WaveStrip 保持装饰回退，且不碰任何平台通道。
class _NullSpectrumSource implements SpectrumSource {
  const _NullSpectrumSource();

  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) async =>
      null;

  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) async =>
      null;
}

/// 应用根：注册状态层给 provider，再挂主题、提示条与首页。
///

/// [CoverState] 兜底构造用的 JSON 客户端：懒建内核的 [HttpJsonClientImpl]。
/// 只在「直接 new AppBootstrap 的测试路径没传 cover」时用到 —— 不发请求
/// 就一个 socket 都不开。
final HttpJsonClient _defaultCoverJson = HttpJsonClientImpl();
/// `.value` 不接管 dispose —— 这些状态在应用生命周期内常驻。
/// 之所以是 `StatefulWidget`：组合根自己持有的原生资源（时长探测的独立
/// `Player`，终审 A2）需要一个明确的释放点，而应用根的卸载就是它。
class LightMusicApp extends StatefulWidget {
  const LightMusicApp({required this.bootstrap, super.key});

  final AppBootstrap bootstrap;

  @override
  State<LightMusicApp> createState() => _LightMusicAppState();
}

class _LightMusicAppState extends State<LightMusicApp> {
  @override
  void dispose() {
    // 不 await：`State.dispose` 是同步契约，而 [AppBootstrap.dispose] 只是把
    // 关闭排在探测队列的尾部（它自己绝不抛）。真等到原生 Player 释放完再返回
    // 反而会把卸载卡在平台通道上。
    unawaited(widget.bootstrap.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = widget.bootstrap;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryState>.value(value: bootstrap.library),
        ChangeNotifierProvider<PlayerState>.value(value: bootstrap.player),
        ChangeNotifierProvider<RecentState>.value(value: bootstrap.recent),
        ChangeNotifierProvider<ToastState>.value(value: bootstrap.toasts),
        // T15：歌词与双语状态。`.value` 由组合根持有，应用生命周期内常驻。
        ChangeNotifierProvider<LyricsState>.value(value: bootstrap.lyrics),
        ChangeNotifierProvider<BilingualState>.value(value: bootstrap.bilingual),
        // 封面显示层（M2b T8）：Stage / Panel / 灯箱的 resolver 共读这一份。
        ChangeNotifierProvider<CoverState>.value(value: bootstrap.cover),
        // 全屏歌词页的开合开关（T18）：播放卡的点击与 T19 的页面本体 / overlay
        // 槽 / 快捷键读同一份，登记在路由之上。
        ChangeNotifierProvider<LyricsPageController>.value(
          value: bootstrap.lyricsPage,
        ),
        // 封面放大层的开合开关（M2b T9）：封面热区（T11）与灯箱本体 / Esc
        // 读同一份，登记在路由之上。
        ChangeNotifierProvider<LightboxController>.value(
          value: bootstrap.lightbox,
        ),
        // 面板的选中 tab 是纯界面态：不属于组合根，界面装配时建即可。
        // 放在路由之上，T29 的弹层复用同一份。
        ChangeNotifierProvider<PanelController>(create: (_) => PanelController()),
        // 外观状态机（M3 T5）：换肤 / 玻璃 / 波形 / 歌词色七维共读这一份。
        ChangeNotifierProvider<ThemeState>.value(value: bootstrap.theme),
        // D.3：实时频谱帧表调度。歌词页的 WaveStrip 从这里取表；
        // ChangeNotifier 只在「表到货 / 被清掉」时通知，不随进度 tick 重建。
        ChangeNotifierProvider<SpectrumState>.value(value: bootstrap.spectrum),
        // 睡眠定时器：控制条上的闹钟按钮读这一份；到点由它暂停播放。
        ChangeNotifierProvider<SleepTimerState>.value(value: bootstrap.sleepTimer),
        Provider<AppPrefs>.value(value: bootstrap.prefs),
      ],
      child: Consumer<ThemeState>(
        builder: (context, themeState, _) => MaterialApp(
        title: '流光音乐',
        debugShowCheckedModeBanner: false,
        // M3 T5：主题随 ThemeState 切换（main() 先 await 读完 prefs 再
        // runApp —— 等价 React useLayoutEffect 的「首帧前挂属性」，
        // 浅色用户不会先闪一帧深色）。system 模式按平台亮度解析。
        // Consumer 包住：watch 发生在 MultiProvider 之下，浅色首帧就位。
        theme: buildTheme(
          tokens: AppTokens.resolve(
            themeState.resolvedMode,
            themeState.color.name,
          ),
        ),
        // 提示条压在路由之上：任何页面 / 弹层看到的都是同一条，且不随页面重建
        // 丢失计时。`home` 只放骨架页，提示条不该由它自己挂。
        // 网关（终审 I5，覆盖面按 R7 补齐）再压一层：原版的 pointerdown /
        // keydown 监听挂在 document 的**捕获阶段**，所以弹层、抽屉、提示条里的
        // 一次交互、以及**被快捷键层或输入框消费掉的一次按键**都算数。
        // 指针走这里的 `Listener`（路由与提示条都在它下面），按键走
        // `HardwareKeyboard` 的全局回调 —— 位置等价，顺序细节见
        // `lib/ui/autoplay_gate.dart` 文件头。
        builder: (context, child) => AutoplayGestureGate(
          child: Stack(
            children: [?child, const ToastsHost()],
          ),
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
              // 终审 I5：N / P 是原版键盘表里漏移植的两张牌（上下曲）
              case 'playNext':
                unawaited(player.next());
              case 'playPrev':
                unawaited(player.previous());
              // T19：L 开 / 关全屏歌词页；Esc 只在开着时才关（原版
              // `src/App.tsx:1595` 的 Escape 分支同样是「有层才关」）。
              case 'toggleLyricsPage':
                bootstrap.lyricsPage.toggle();
              case 'closeOverlay':
                // 放大层叠在歌词页之上：Esc 只认顶层（App.tsx:1581-1591，
                // 灯箱开着时其它快捷键全部让位、歌词页保持其下渲染）。
                if (bootstrap.lightbox.isOpen) {
                  bootstrap.lightbox.close();
                } else if (bootstrap.lyricsPage.isOpen) {
                  bootstrap.lyricsPage.close();
                }
            }
          },
          child: const HomePage(),
        ),
        ),
      ),
    );
  }
}
