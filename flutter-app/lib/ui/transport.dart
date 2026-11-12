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
import '../playback/play_mode.dart';
import '../playback/track.dart';
import '../playback/transport_controller.dart';
import '../state/lyrics_page_controller.dart';
import '../state/player_state.dart';
import '../state/spectrum_state.dart';
import 'wave_strip.dart';
import '../wave/spectrum_pipeline.dart';
import '../theme/app_tokens.dart';
import 'autoplay_gate.dart';
import 'library_sheet.dart';
import 'player_card.dart';
import 'progress_slider.dart';
import 'tool_buttons.dart';
import 'volume_slider.dart';

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
      volume = 0.7,
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
    this.volume = 0.7,
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
        frameTable: null,
        waveTrack: null,
        wavePlaying: playing,
        wavePosition: positionSeconds,
        wavePositionListenable: null,
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
    // frameTableFor(id) 保证换曲那一帧不会短暂画出上一首的频谱。
    final spectrum = context.watch<SpectrumState?>();
    final waveTrack = player.current;
    final frameTable = waveTrack == null
        ? null
        : spectrum?.frameTableFor(waveTrack.id);
    return _chrome(
      context: context,
      tokens: tokens,
      desktop: desktop,
      showWaveStrip: inLyricsPage,
      frameTable: frameTable,
      waveTrack: waveTrack,
      wavePlaying: player.view.value.playing,
      wavePosition: player.position.value,
      // 真实帧表是按 positionSeconds 取帧的，所以频谱条必须订阅进度。
      // 只把 notifier 传到 WaveStrip 那一片叶子，不整条控制条跟着 4Hz 重建。
      wavePositionListenable: inLyricsPage ? player.position : null,
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
    required SpectrumFrameTable? frameTable,
    required Track? waveTrack,
    required bool wavePlaying,
    required double wavePosition,
    required ValueListenable<double>? wavePositionListenable,
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
        frameTable: frameTable,
        waveTrack: waveTrack,
        wavePlaying: wavePlaying,
        wavePosition: wavePosition,
        wavePositionListenable: wavePositionListenable,
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
        frameTable: frameTable,
        waveTrack: waveTrack,
        wavePlaying: wavePlaying,
        wavePosition: wavePosition,
        wavePositionListenable: wavePositionListenable,
        progress: progress,
        controls: controls,
      ),
    );
  }

  /// 卡内的两行内容（wave 行 + 进度 + 控制）。独立卡与 [PlayerCard] 共用。
  Widget _body({
    required bool desktop,
    required bool showWaveStrip,
    required SpectrumFrameTable? frameTable,
    required Track? waveTrack,
    required bool wavePlaying,
    required double wavePosition,
    required ValueListenable<double>? wavePositionListenable,
    required Widget progress,
    required Widget controls,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        // `.transport { padding: 14px 16px calc(12px + safe-area) }`（:1092）；
        // 窄屏左右 14（老实现沿用）。
        padding: EdgeInsets.fromLTRB(
          desktop ? 16 : 14,
          14,
          desktop ? 16 : 14,
          12,
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
            _WaveRow(
              showWaveStrip: showWaveStrip,
              frameTable: frameTable,
              track: waveTrack,
              playing: wavePlaying,
              positionSeconds: wavePosition,
              positionListenable: wavePositionListenable,
            ),
            const SizedBox(height: 6),
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
  const _WaveRow({
    required this.showWaveStrip,
    required this.frameTable,
    required this.track,
    required this.playing,
    required this.positionSeconds,
    this.positionListenable,
  });

  final bool showWaveStrip;
  final SpectrumFrameTable? frameTable;
  final Track? track;
  final bool playing;
  final double positionSeconds;

  /// 进度 notifier：给了就让 WaveStrip 自己订阅（只有这一片叶子跟着 4Hz 重建）。
  final ValueListenable<double>? positionListenable;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (!showWaveStrip) ...[
          const ToolButtons(),
          const SizedBox(width: 10),
        ],
        if (showWaveStrip)
          Expanded(
            child: WaveStrip(
              frameTable: frameTable,
              track: track,
              playing: playing,
              positionSeconds: positionSeconds,
              positionListenable: positionListenable,
            ),
          ),
      ],
    );
  }
}

/// 控制行：桌面四钮 + 音量，窄屏五钮等距。
class _ControlsRow extends StatelessWidget {  const _ControlsRow({
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
          // 音量：min(200px, 100%) 靠右，行宽不够时被挤压的只有滑轨
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
