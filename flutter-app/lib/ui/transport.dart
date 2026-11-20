// lib/ui/transport.dart
//
// 控制条：对译 `src/App.tsx:969-1058` 与 `src/styles/app.css` 的 `.transport`
// /`.progress`/`.controls`/`.volume` 四族。
//
//   ┌───────────────────────────────────────────────┐
//   │ 00:12 ├──────●───────────────────┤ 03:46      │  ← 进度行（永远在上面）
//   │ 模式  上一首  播放  下一首      [音量 滑轨]    │  ≥900：四个 40 钮 + gap12 + 音量
//   │ 模式  上一首  播放  下一首  列表               │  <900：五个 40 钮 space-between
//   └───────────────────────────────────────────────┘
//
// 两档断点（`.controls` 的 grid / flex、`.volume` 的 display:none、
// `.controls__queue` 的 display:inline-flex 全在 `@media (900px)` 两侧）：
//   - **窄屏**：音量整块隐藏（手机交给实体键），列表入口挤到最右侧，点开的是
//     与侧栏同一个面板的底部弹层；
//   - **桌面**：右栏常驻列表，控制条不再重复给列表入口；音量块 `min(200px,100%)`
//     靠右、滑轨基准 130。M1 没有歌词页，所以桌面不出现列表按钮，但列位留着不塌陷。
//
// 订阅纪律（这是本文件唯一的硬约束）：整条只挂 `view` 与 `position` 两个
// ValueNotifier，**不 watch PlayerState**，也绝不订阅 buffered ——
// 缓冲事件每秒好几次，跟着重建就等于原版记录过的「一秒四次整树重绘」。
// 音量 / 模式 / 播放态这些语义变化都在 `view` 里，进度只在 `position` 里。
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../playback/audio_player.dart' show kDefaultVolume;
import '../playback/play_mode.dart';
import '../playback/transport_controller.dart';
import '../state/lyrics_page_controller.dart';
import '../state/player_state.dart';
import '../state/spectrum_state.dart';
import 'wave_strip.dart';
import '../theme/app_tokens.dart';
import 'autoplay_gate.dart';
import 'library_sheet.dart';
import 'player_card.dart';
import 'progress_slider.dart';
import 'tool_buttons.dart';
import 'tool_panel.dart' show ToolPanelSide;
import 'volume_slider.dart';
import 'wave_style_picker.dart';

/// 控制条按钮之间的间距：`.controls { gap: 12px }`（桌面 grid）。
const double _controlsGap = 12;

/// 进度行与控制行之间的间距：`.transport { gap: 12px }`。
const double _barVerticalGap = 12;

/// 播放键图标 / 转圈的直径：`.controls > .btn--play .icon { width: 18px }`。
const double _playIconSize = 18;

/// 减少动态效果时转圈停在的位置（0~1 的弧长比例）。
///
/// 取 1/4：与动画里任意一帧同一形状，只是不再转。
const double _staticSpinnerValue = 0.25;

class TransportBar extends StatelessWidget {
  /// 真入口：读 [PlayerState] 的 `view` 与 `position`。
  const TransportBar({super.key})
    : playing = false,
      loading = false,
      modeLabel = '',
      positionSeconds = 0,
      totalSeconds = null,
      bufferedSeconds = null,
      volume = kDefaultVolume,
      muted = false,
      _preview = false;

  /// 纯展示入口：测试与预览用，不碰状态层（回调全是空实现）。
  const TransportBar.preview({
    required this.playing,
    required this.modeLabel,
    required this.positionSeconds,
    this.totalSeconds,
    this.bufferedSeconds,
    this.loading = false,
    this.volume = kDefaultVolume,
    this.muted = false,
    super.key,
  }) : _preview = true;

  final bool playing;
  final bool loading;

  /// 模式文案（原版 `modeLabel`）：`列表循环` / `单曲循环` / `随机播放`。
  final String modeLabel;

  final double positionSeconds;
  final double? totalSeconds;
  final double? bufferedSeconds;
  final double volume;
  final bool muted;
  final bool _preview;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 断点看的是视口宽度，不是控件自己拿到的宽度：桌面档里控制条只占左列，
    // 用 LayoutBuilder 会在 900~1400 之间被误判成窄屏。
    final desktop = isDesktop(MediaQuery.sizeOf(context).width);
    if (_preview) {
      return _chrome(
        context: context,
        tokens: tokens,
        desktop: desktop,
        showWaveStrip: false,
        // 预览入口不挂状态层：给一条纯展示的条子（showWaveStrip=false 时反正不画）。
        waveStrip: WaveStrip(
          frameTable: null,
          track: null,
          playing: playing,
          positionSeconds: positionSeconds,
        ),
        progress: ProgressSlider(
          position: positionSeconds,
          buffered: bufferedSeconds,
          duration: totalSeconds,
          onSeekStart: () {},
          onSeekUpdate: (_) {},
          onSeekEnd: (_) {},
        ),
        controls: _ControlsRow(
          desktop: desktop,
          playing: playing,
          loading: loading,
          modeLabel: modeLabel,
          volume: volume,
          muted: muted,
        ),
      );
    }
    final player = context.read<PlayerState>();
    // M3 T11：歌词页开着时 WaveStrip 显示在 transport 行（app.css:3926），
    // 首页隐藏（:1111）。
    final inLyricsPage = context.watch<LyricsPageController?>()?.isOpen ?? false;
    // D.3：帧表从组合根注入的 SpectrumState 取。provider 可空 watch ——
    // 与歌词/封面那几处同一容错模式（纯展示测试没注册时退回装饰回退）。
    //
    // **不要在 build 里现取 `player.view.value.playing` 往下传**：本控制条是
    // `const`（home_page.dart），整条不订阅 PlayerState，这一次 build 读到的
    // 只是当时那一瞬的快照。真机上换曲时控制条会被 SpectrumState 的通知重建
    // 一次 —— 那一刻内核还在 open、playing 还是 false；等内核真的出声，
    // 没有任何东西会再重建控制条，`playing` 就永远停在 false：
    // ticker 不跑、`read(playing:false)` 冻在最后一帧，就是用户说的
    // 「手动切歌后频谱不律动」「下一首要过一会儿才律动」。
    // 频谱条自己订阅 `player.view`（见 [_LiveWaveStrip]），播放态 / 曲目 /
    // 帧表都在它那一片叶子里现取。
    final spectrum = context.watch<SpectrumState?>();
    final waveStrip = _LiveWaveStrip(
      player: player,
      spectrum: spectrum,
      positionListenable: inLyricsPage ? player.position : null,
      height: isUltraWide(MediaQuery.sizeOf(context).width)
          ? kWaveStripHeightUltra
          : kWaveStripHeight,
    );
    return _chrome(
      context: context,
      tokens: tokens,
      desktop: desktop,
      showWaveStrip: inLyricsPage,
      waveStrip: waveStrip,
      // 进度行只挂 position：缓冲值在重建时顺带读一次，不单独订阅。
      progress: ValueListenableBuilder<double>(
        valueListenable: player.position,
        builder: (context, position, _) => ProgressSlider(
          position: position,
          buffered: player.buffered.value,
          duration: _totalOf(player),
          onSeekStart: () {},
          onSeekUpdate: (_) {},
          onSeekEnd: (seconds) => unawaited(player.seekTo(seconds)),
        ),
      ),
      // 控制行只挂 view：语义变化才重建，进度 tick 与缓冲 tick 都不动它。
      controls: ValueListenableBuilder<TransportView>(
        valueListenable: player.view,
        builder: (context, view, _) => _ControlsRow(
          desktop: desktop,
          playing: view.playing,
          loading: view.loading,
          modeLabel: playModeLabel(view.mode),
          volume: view.volume,
          muted: view.muted,
          onPlay: () => unawaited(player.togglePlay()),
          onNext: () => unawaited(player.next()),
          onPrev: () => unawaited(player.previous()),
          onCycleMode: player.cycleMode,
          onVolume: (value) => unawaited(player.setVolume(value)),
          onMute: () => unawaited(player.toggleMute()),
          onQueue: () => showLibrarySheet(context),
          // 桌面档：歌词页占掉右栏时才补列表入口（React 同款规则）。
          // 大屏（≥1280）歌词页左列已常驻列表，这颗入口就多余了
          // （`body.is-lyrics-page .controls__queue { display: none }`，app.css:5035-5037）。
          showQueue: inLyricsPage &&
              !isWide(MediaQuery.sizeOf(context).width),
        ),
      ),
    );
  }

  /// 总时长：内核报的优先，其次曲目元数据；两处都未知时 null（`--:--`）。
  static double? _totalOf(PlayerState player) {
    final reported = player.duration.value;
    if (reported != null && reported.isFinite && reported > 0) return reported;
    final track = player.view.value.current;
    return track != null && track.hasDuration ? track.duration : null;
  }

  Widget _chrome({
    required BuildContext context,
    required AppTokens tokens,
    required bool desktop,
    required bool showWaveStrip,
    required Widget waveStrip,
    required Widget progress,
    required Widget controls,
  }) {
    // 在 [PlayerCard] 里：`.player > .transport` 要把边框 / 圆角 / 玻璃底 /
    // 阴影全剥掉（app.css:510-518），只保留 padding 与内部两行，避免合成卡
    // 中间多出一道缝。纯展示 / 测试没有 scope 时仍是独立卡（既有断言不破）。
    if (PlayerCardScope.maybeOf(context) != null) {
      return _body(
        desktop: desktop,
        showWaveStrip: showWaveStrip,
        waveStrip: waveStrip,
        progress: progress,
        controls: controls,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: tokens.border),
          left: BorderSide(color: tokens.border),
          right: BorderSide(color: tokens.border),
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(kRadiusXl),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.barA, tokens.barB],
        ),
        boxShadow: tokens.shadowBar,
      ),
      // 透明 Material 只为 InkWell 铺一块画布，底色已经在上面画好了
      child: _body(
        desktop: desktop,
        showWaveStrip: showWaveStrip,
        waveStrip: waveStrip,
        progress: progress,
        controls: controls,
      ),
    );
  }

  /// 卡内的两行内容（wave 行 + 进度 + 控制）。独立卡与 [PlayerCard] 共用。
  Widget _body({
    required bool desktop,
    required bool showWaveStrip,
    required Widget waveStrip,
    required Widget progress,
    required Widget controls,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        // `.transport { padding: 14px 16px calc(12px + safe-area) }`（:1130）；
        // 窄屏左右 14（老实现沿用）。窄屏底边从 12 加到 30：页面已经铺满
        // （`.app { padding: 0 }`），原来那 12px 是贴着卡片内留白用的，
        // 现在控制行直接落到屏幕底边，补一层留白才不会压住手势条
        // （`@media (max-width: 899px) { .transport { padding-bottom:
        // calc(30px + env(safe-area-inset-bottom)) } }`）。安全区在本层之外
        // 由 [SafeArea] 让出，与 CSS 的 env() 同效。
        padding: EdgeInsets.fromLTRB(
          desktop ? 16 : 14,
          14,
          desktop ? 16 : 14,
          desktop ? 12 : 30,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // 拉伸：控制行的 space-between 要的是整行宽度，不是按钮自身宽度
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // M3 T11：进度行上方的「transport__wave」行——简约模式左端是
            // T（歌词高亮色）、水滴（卡面透明/磨砂）与睡眠定时器，其后
            // WaveStrip；歌词页（沉浸模式）开着时那三颗按钮搬到歌词页页头，
            // 这行只剩频谱。
            _WaveRow(showWaveStrip: showWaveStrip, strip: waveStrip),
            // 这一行到进度条的间距按 Web 的两条规则分开给：
            //  · 沉浸模式（歌词页，频谱条在场）：`.transport { row-gap: 0 }`
            //    + `.transport__wave { padding-bottom: 2px }` → 频谱底边到进度条
            //    顶边就 **2px**（app.css:1173-1188）。之前写死 6px，正是用户看到的
            //    「Flutter 的音谱条离进度条比 Web 远一截」。
            //  · 简约模式（这行只有 T / 水滴 / 闹钟）：`.transport { gap: 12px }`
            //    被 `.transport__wave { margin-bottom: -4px }` 抵掉 4px → **8px**
            //    （app.css:1159-1163）。
            SizedBox(height: showWaveStrip ? 2 : 8),
            progress,
            const SizedBox(height: _barVerticalGap),
            controls,
          ],
        ),
      ),
    );
  }
}

/// 进度行上方那条（App.tsx:973-977 的 transport__wave 对译）：
/// 左端 T（歌词高亮色，T12）与水滴（卡面透明/磨砂，T7），其后 WaveStrip。
/// **首页该行 WaveStrip 隐藏**（app.css:1111），[showWaveStrip] 只在歌词页为真。
///
/// **歌词页开着 = 沉浸模式**：这时三颗按钮已经搬到歌词页页头（歌名右边），
/// 这行只剩频谱 —— 与 React 的 `{!immersive && <ToolButtons />}` 同构
/// （src/App.tsx:1043-1046）。
class _WaveRow extends StatelessWidget {
  const _WaveRow({required this.showWaveStrip, required this.strip});

  final bool showWaveStrip;

  /// 频谱条本体（真入口是 [_LiveWaveStrip]，预览入口是静态 WaveStrip）。
  final Widget strip;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final row = Row(
      children: [
        if (!showWaveStrip) ...[
          const ToolButtons(),
          const SizedBox(width: 10),
        ],
        if (showWaveStrip) Expanded(child: strip),
      ],
    );
    // 窄屏歌词页：页头那组（T / 毛玻璃 / 睡眠 + 波形样式下拉）挪到频谱条上方
    // 单独成行 —— 手机上一只手够不到页头顶端（app.css 的 `.transport__lyric-row`）。
    // 三颗按钮仍在同一个 Padding 里起排，左端与简约模式那行完全对齐。
    //
    // 这一行与上面的歌词页同属「点哪儿都切回简约模式」的热区：手机退出沉浸
    // 只剩点空白，行里两颗控件之外的地方（按钮之间、贴右的留白）点下去也该退出。
    // 里层按钮 / 下拉自己会先进竞技场，点它们仍弹各自的面板。
    if (showWaveStrip && !isDesktop(width)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: const Key('transport-tap-to-simple'),
            // opaque：Spacer 那块没底的像素也要能点到
            behavior: HitTestBehavior.opaque,
            onTap: () => context.read<LyricsPageController?>()?.close(),
            child: Row(
              children: const [
                ToolButtons(),
                Spacer(),
                // 面板向上弹：这行已经贴着屏幕底部（React 侧同一处 `bottom: 100%`）
                WaveStylePicker(side: ToolPanelSide.above),
              ],
            ),
          ),
          const SizedBox(height: 6),
          row,
        ],
      );
    }
    // 窄屏简约模式：这一行里三颗按钮之外的空白（它们右边到行尾）也是
    // 「进沉浸模式」的热区 —— 与曲目区整块 `stage-tap-to-lyrics` 同一套语义，
    // 红框下沿那一条点了同样能切过去。按钮自己是内层识别器，照旧弹面板。
    if (!showWaveStrip && !isDesktop(width)) {
      return GestureDetector(
        key: const Key('transport-wave-tap-to-lyrics'),
        behavior: HitTestBehavior.opaque,
        onTap: () => context.read<LyricsPageController?>()?.open(),
        child: row,
      );
    }
    return row;
  }
}

/// 真入口的频谱条：**自己订阅播放态 / 曲目 / 帧表**。
///
/// 为什么不能像以前那样在 [TransportBar.build] 里现取 `player.view.value.playing`
/// 往下传：控制条在首页是 `const`，它不订阅 `PlayerState`（订阅纪律见文件头），
/// 于是那个 `playing` 只是「恰好重建的那一刻」的快照。换曲时控制条会被
/// `SpectrumState` 的通知重建一次，而那一刻内核还在 open、`playing` 仍是 false；
/// 等内核真的出声，没有东西会再重建控制条 —— `WaveStrip` 就永远停在
/// `playing=false`：ticker 不跑、`read(playing:false)` 冻在最后一帧。
/// 真机上正是「手动切歌后频谱不律动」与「自动续播要等一阵才律动」。
///
/// 这里把 `player.view` 挂到频谱条这一片叶子上：播放态一变就重建
/// （语义变化只有每次切歌几个，不是进度那种 4Hz），而且：
///   * 曲目取 `view.current` —— 换曲时同一次通知里就是新的一首；
///   * 帧表用 `spectrum.frameTableFor(id)` **现取** —— 它读的是状态层的当前值，
///     所以即使这次重建比「表到货」的通知早，也不会把上一首的表画到新歌上。
class _LiveWaveStrip extends StatelessWidget {
  const _LiveWaveStrip({
    required this.player,
    required this.spectrum,
    required this.positionListenable,
    required this.height,
  });

  final PlayerState player;

  /// 组合根注入的频谱状态层；纯展示 / 未注册 provider 时为 null（装饰回退）。
  final SpectrumState? spectrum;

  /// 进度 notifier：给了就让 WaveStrip 自己订阅（只有这一片叶子跟着 4Hz 重建）。
  final ValueListenable<double>? positionListenable;

  /// 画布高度：48，满宽档（≥1680）56（app.css:2488-2494 / :5098-5100）。
  final double height;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TransportView>(
      valueListenable: player.view,
      builder: (context, view, _) {
        final track = view.current;
        return WaveStrip(
          frameTable: track == null ? null : spectrum?.frameTableFor(track.id),
          track: track,
          playing: view.playing,
          positionSeconds: player.position.value,
          positionListenable: positionListenable,
          height: height,
        );
      },
    );
  }
}

/// 控制行：桌面四钮 + 音量，窄屏五钮等距。
class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.desktop,
    required this.playing,
    required this.loading,
    required this.modeLabel,
    required this.volume,
    required this.muted,
    this.onPlay,
    this.onNext,
    this.onPrev,
    this.onCycleMode,
    this.onVolume,
    this.onMute,
    this.onQueue,
    this.showQueue = false,
  });

  final bool desktop;
  final bool playing;
  final bool loading;
  final String modeLabel;
  final double volume;
  final bool muted;

  /// 预览入口不接状态层：回调为空时按钮仍画成可用态，只是点了没反应。
  final VoidCallback? onPlay;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final VoidCallback? onCycleMode;
  final ValueChanged<double>? onVolume;
  final VoidCallback? onMute;
  final VoidCallback? onQueue;

  /// 是否显示「播放列表」入口（桌面档）。
  ///
  /// React 规则（app.css:1379-1381 / 4377-4379）：`.controls__queue` 默认
  /// `display:none`，**只在歌词页让出右栏时**才出现（`body.is-lyrics-page
  /// .controls__queue { display: inline-flex }`）—— 桌面平时右栏常驻列表，
  /// 不需要重复一个入口；歌词页占掉右栏，列表面板没处摆，才补这颗按钮。
  /// 窄屏（≤899px）则常驻（原版窄屏没有右栏）。
  final bool showQueue;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final mode = _TransportButton(
      id: 'btn-mode',
      label: '播放模式：$modeLabel',
      icon: _modeIcon(),
      onTap: onCycleMode,
    );
    final previous = _TransportButton(
      id: 'btn-prev',
      label: '上一首',
      icon: Icons.skip_previous,
      onTap: onPrev,
    );
    final next = _TransportButton(
      id: 'btn-next',
      label: '下一首',
      icon: Icons.skip_next,
      onTap: onNext,
    );
    // 加载中只留转圈（原版 `.btn--play.is-loading` 把图标位空出来给 spinner）。
    // 减少动态效果时换成静止的 1/4 弧：`CircularProgressIndicator` 只在 value 为
    // null 时才起 AnimationController，给了值就是同一形状的一帧定格 —— 不留常驻
    // ticker，也不占帧预算（README 的 `prefers-reduced-motion` 那一节要求的就是这个）。
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 终审 R7：这颗按钮自己就会发起播放（`togglePlay`），所以它吃掉的
    // pointer-down 由 [GestureOwnedRegion] 认领，网关不再补一次重试 ——
    // 原版 `closest('.btn--play, …')`（`src/App.tsx:1562`）防的就是「一次意图
    // 花两格额度」。
    final play = GestureOwnedRegion(
      child: _TransportButton(
        id: 'btn-play',
        label: playing ? '暂停' : '播放',
        icon: playing ? Icons.pause : Icons.play_arrow,
        onTap: onPlay,
        child: loading
            ? SizedBox.square(
                dimension: _playIconSize,
                child: CircularProgressIndicator(
                  value: reduceMotion ? _staticSpinnerValue : null,
                  strokeWidth: 2,
                  color: tokens.accent,
                  backgroundColor: tokens.accentSoft,
                ),
              )
            : null,
      ),
    );

    if (desktop) {
      return Row(
        children: [
          mode,
          const SizedBox(width: _controlsGap),
          previous,
          const SizedBox(width: _controlsGap),
          play,
          const SizedBox(width: _controlsGap),
          next,
          const SizedBox(width: _controlsGap),
          // 音量：React 的 `.volume` 是 `flex: 1 1 auto`（grid-column 1/-1），
          // 滑杆 `flex: 1 1 auto` 吃掉剩余宽度、按钮 `flex: 0 0 auto` 钉死
          // 40px 不被压扁；`.volume__input` 上限 200px（app.css:1307-1331）。
          // 这里保持同一形状：滑杆撑开、音量钮固定在最左、整体靠右。
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kVolumeMaxWidth),
                child: VolumeSlider(
                  value: volume,
                  muted: muted,
                  onChanged: onVolume ?? (_) {},
                  onToggleMute: onMute ?? () {},
                ),
              ),
            ),
          ),
          // 列表入口：桌面平时右栏常驻列表，不重复给；歌词页占掉右栏时才出现
          // （React `body.is-lyrics-page .controls__queue`，app.css:4377-4379）。
          if (showQueue) ...[
            const SizedBox(width: _controlsGap),
            _TransportButton(
              id: 'btn-queue',
              label: '播放列表',
              icon: Icons.queue_music,
              onTap: onQueue,
            ),
          ],
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        mode,
        previous,
        play,
        next,
        // 列表入口：打开的是与侧栏同一个面板的底部弹层（原版两处共用一份 Panel）
        _TransportButton(
          id: 'btn-queue',
          label: '播放列表',
          icon: Icons.queue_music,
          onTap: onQueue,
        ),
      ],
    );
  }

  /// 模式图标：原版 `<ModeIcon name=...>`，三种模式三个形状。
  ///
  /// 控制条只拿到的是文案（预览入口也只给文案），所以按文案换图标；
  /// 真入口的文案由 `playModeLabel(mode)` 生成，两者一一对应。
  IconData _modeIcon() => switch (modeLabel) {
    '单曲循环' => Icons.repeat_one,
    '随机播放' => Icons.shuffle,
    _ => Icons.repeat,
  };
}

/// 控制条上的 40×40 圆钮：`.controls > .btn { width: 40px; height: 40px }`。
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.id,
    required this.label,
    this.icon,
    this.child,
    this.onTap,
  });

  final String id;

  /// 读屏名：`播放模式：…` / `上一首` / `播放` / `暂停` / `下一首` / `播放列表`。
  final String label;

  final IconData? icon;

  /// 自定义内容（播放键的转圈走这里）。
  final Widget? child;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox(
        key: Key(id),
        width: kButtonSize,
        height: kButtonSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: tokens.border),
            color: tokens.cardB,
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
            child: Center(
              child:
                  child ??
                  Icon(
                    icon,
                    // 播放键 18、其余 20（`.btn--play .icon` / `.icon`）
                    size: id == 'btn-play' ? 18 : 20,
                    color: tokens.text,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
