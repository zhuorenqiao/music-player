// lib/ui/sleep_page.dart
//
// 休眠页（2026-11-23 新增）：页头 + 问候语 + 夜色播放卡 + 播放状线 +
// 分类页签（声景 / 摇篮 / 白噪）+ 单列声景表 + 页脚一句话。
//
// 版式沿用电台页那套，但夜色卡是模块自己的固定深蓝 + 月亮，**不随主题翻**：
// 浅色 / 换肤时页面其余部分照常跟 token 走，卡面仍是那块「另一个时空」。
// 卡面的流星（5 秒一轮、右上→左下）与 React `sleep-meteor-arc` 同一套参数。
// 与 React `src/components/SleepPage.tsx` 逐项对齐（尺寸 / 字号 / 圆角 / 间距），
// 改一处必须改另一处。
//
// 页签不搞横滑：React 端这一版只做点击 + 键盘左右键，Flutter 就只做点击；
// 多一种手势会让两端的行为悄悄分叉。
//
// 页头右侧四颗：睡眠定时器 → 「电台」互跳 → 「音乐」回退 → 「更多」。
// 「电台」是这一页的邻居入口（另一枚在电台页，是「休眠」），三颗带壳的胶囊
// 共用 `page_link_chip.dart` 的 [PageLinkChip]。
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../sleep/sleep_palette.dart';
import '../sleep/sleep_state.dart';
import '../sleep/sleep_track.dart';
import '../theme/app_tokens.dart';
import 'more_menu.dart';
import 'page_link_chip.dart';
import 'scroll_physics.dart';
import 'sleep_moon.dart';
import 'sleep_timer_button.dart';
import 'tool_panel.dart';

/// 播放卡圆角：与音乐页 / 电台页同一档（`--radius-xl`）。
const double _radius = 24;

/// 桌面版心：与电台页同一条 760。
const double _maxContent = 760;

/// 桌面版心的左右内边距（React `.app--sleep` 的 28px）。
const double _desktopInset = 28;

/// 卡面上的星点：固定坐标（比例 + 直径 + 透明度），两端共用同一张表。
const List<({double x, double y, double size, double alpha})> _kStars = [
  (x: 0.07, y: 0.13, size: 1.6, alpha: 0.55),
  (x: 0.18, y: 0.08, size: 1.2, alpha: 0.40),
  (x: 0.31, y: 0.18, size: 1.9, alpha: 0.70),
  (x: 0.44, y: 0.07, size: 1.2, alpha: 0.45),
  (x: 0.58, y: 0.15, size: 1.5, alpha: 0.60),
  (x: 0.69, y: 0.06, size: 1.0, alpha: 0.35),
  (x: 0.12, y: 0.34, size: 1.2, alpha: 0.45),
  (x: 0.25, y: 0.30, size: 0.9, alpha: 0.30),
  (x: 0.38, y: 0.27, size: 1.4, alpha: 0.50),
  (x: 0.52, y: 0.33, size: 1.1, alpha: 0.40),
  (x: 0.66, y: 0.29, size: 1.7, alpha: 0.65),
  (x: 0.78, y: 0.38, size: 1.0, alpha: 0.35),
  (x: 0.09, y: 0.57, size: 0.9, alpha: 0.30),
  (x: 0.21, y: 0.51, size: 1.3, alpha: 0.50),
  (x: 0.35, y: 0.61, size: 1.0, alpha: 0.35),
  (x: 0.48, y: 0.48, size: 1.2, alpha: 0.45),
  (x: 0.62, y: 0.56, size: 0.8, alpha: 0.28),
  (x: 0.74, y: 0.63, size: 1.4, alpha: 0.45),
  (x: 0.88, y: 0.44, size: 1.1, alpha: 0.35),
];

class SleepPage extends StatefulWidget {
  const SleepPage({required this.onBack, this.onOpenRadio, super.key});

  /// 回音乐播放器（通常是 `Navigator.pop`；声景不停）。
  final VoidCallback onBack;

  /// 「电台」入口：整页切到电台页（由 home_page 接线）。为空时不显示这一颗
  /// —— 与 [AppHeader] 对可选入口的处理同一套，独立预览 / 测试不必摆一颗死按钮。
  final VoidCallback? onOpenRadio;

  @override
  State<SleepPage> createState() => _SleepPageState();
}

class _SleepPageState extends State<SleepPage> {
  /// 当前页签：进页面时跟着「正在播的声景」走，没播过就落在声景。
  late SleepCategory _active;

  @override
  void initState() {
    super.initState();
    _active =
        context.read<SleepState>().current?.category ?? SleepCategory.scape;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final sleep = context.watch<SleepState>();
    final tracks = sleepTracksOf(_active);
    return Scaffold(
      backgroundColor: tokens.bg,
      body: DecoratedBox(
        // `body::before`：与音乐页同一张对角渐变，只是两端的色落在 token 上。
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.bgGradA, tokens.bgGradB],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final desktop = isDesktop(width);
              // 760 是**版心内容**宽（卡与行表 760，与 React `.sleep-page`
              // max-width 一致）；左右 28 的内边距在版心之外，所以约束要加回来。
              final maxWidth = desktop
                  ? math.min(
                      _maxContent + _desktopInset * 2,
                      contentMaxWidth(MediaQuery.sizeOf(context).width),
                    )
                  : width;
              // 内容短于视口时也必须贴顶：`Center` 会把整页垂直居中，
              // 页面看起来像「浮在半空」，与 React 的 top 对齐不一致。
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: SingleChildScrollView(
                    key: const Key('sleep-scroll'),
                    physics: const SoftBouncingScrollPhysics(),
                    padding: desktop
                        ? const EdgeInsets.fromLTRB(
                            _desktopInset,
                            24,
                            _desktopInset,
                            32,
                          )
                        : EdgeInsets.fromLTRB(
                            16,
                            // 页头内容顶部内缩 18（与 Web 侧 `.app--sleep` 的
                            // `padding-top: calc(18px + env(safe-area-inset-top))` 同档）；
                            // 刘海 / 状态栏那截由外层 SafeArea 让出。
                            18,
                            16,
                            24 + MediaQuery.paddingOf(context).bottom,
                          ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Header(
                          onBack: widget.onBack,
                          onOpenRadio: widget.onOpenRadio,
                        ),
                        _Greeting(desktop: desktop),
                        SizedBox(height: desktop ? 24 : 20),
                        _HeroCard(sleep: sleep, desktop: desktop),
                        const SizedBox(height: 14),
                        _StatusLine(sleep: sleep),
                        SizedBox(height: desktop ? 22 : 18),
                        _TabBar(
                          active: _active,
                          onChange: (next) {
                            if (next == _active) return;
                            setState(() => _active = next);
                          },
                        ),
                        const SizedBox(height: 4),
                        _SleepList(
                          tracks: tracks,
                          sleep: sleep,
                          desktop: desktop,
                        ),
                        const SizedBox(height: 26),
                        const _FootLine(text: '晚安，好梦。'),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 页头：左侧夜色 logo + 休眠 / SLEEP MODE；
/// 右侧睡眠定时器 + 「电台」互跳 + 音乐回退 + 更多。
class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.onOpenRadio});

  final VoidCallback onBack;
  final VoidCallback? onOpenRadio;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final narrow = !isDesktop(MediaQuery.sizeOf(context).width);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: SleepPalette.logoLine),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SleepPalette.logoTop, SleepPalette.logoBottom],
            ),
            boxShadow: [
              BoxShadow(
                color: SleepPalette.moonHalo.withValues(alpha: 0.6),
                blurRadius: 26,
                spreadRadius: -10,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const SleepMoonIcon(size: 18, color: SleepPalette.moonHalo),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '助眠',
              style: TextStyle(
                fontSize: 15,
                height: 1.1,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'SLEEP MODE',
              style: TextStyle(
                fontSize: 10,
                height: 1.1,
                letterSpacing: 1.7,
                color: tokens.textFaint,
              ),
            ),
          ],
        ),
        const Spacer(),
        _HeadActions(
          onBack: onBack,
          onOpenRadio: onOpenRadio,
          narrow: narrow,
        ),
      ],
    );
  }
}

class _HeadActions extends StatelessWidget {
  const _HeadActions({
    required this.onBack,
    required this.onOpenRadio,
    required this.narrow,
  });

  final VoidCallback onBack;
  final VoidCallback? onOpenRadio;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    // 间距 8 与音乐页顶栏同一档（`AppHeader` 里那几个 `SizedBox(width: 8)`）——
    // 三页的右上角是同一排按钮，切页时不该看到间距变化。
    const gap = 8.0;
    final openRadio = onOpenRadio;
    final row = Row(
      key: const Key('sleep-head-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SleepTimerButton(side: ToolPanelSide.below),
        SizedBox(width: gap),
        if (openRadio != null) ...[
          PageLinkChip(
            chipKey: const Key('sleep-radio-button'),
            semanticLabel: '打开电台页',
            label: '电台',
            tone: PageLinkTone.accent,
            onTap: openRadio,
            iconBuilder: (size, color) => CustomPaint(
              size: Size.square(size),
              painter: BroadcastPainter(color: color),
            ),
          ),
          SizedBox(width: gap),
        ],
        PageLinkChip(
          chipKey: const Key('sleep-back-button'),
          semanticLabel: '返回音乐播放器',
          label: '音乐',
          // 壳素、音符 accent：与「电台」旁边那颗「休眠」写月亮同一条规矩 ——
          // 另一页 / 另一位置的入口，颜色是它的身份标记。
          tone: PageLinkTone.accentIcon,
          narrowIconSize: 16,
          onTap: onBack,
          iconBuilder: (size, color) => CustomPaint(
            size: Size.square(size),
            painter: MusicNotePainter(color: color),
          ),
        ),
        SizedBox(width: gap),
        MoreMenu(showLibraryActions: false, iconOnly: narrow),
      ],
    );
    if (!narrow) return row;
    // 窄屏：页头左右各内缩 16，而 Web 这四颗贴视口右侧 10 —— 差的 6px 只挪绘制、
    // 不占排版，与音乐页顶栏同一落位（三颗图标 32×32、彼此 8px、定时器 26）。
    // 纵向同理只挪绘制：整组原本跟着 40px 品牌块居中（内容上内缩 18 → 中心 38），
    //  统一口径是**按钮上缘 12、图标中心 28**，所以整组上提 10px（38 - 28），
    //  三页切来切去不上下跳。
    return Transform.translate(offset: const Offset(6, -10), child: row);
  }
}

/// 问候语 + 大标题（与 React 的 `.sleep-greet` 同尺寸）。
class _Greeting extends StatelessWidget {
  const _Greeting({required this.desktop});

  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: EdgeInsets.only(top: desktop ? 30 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sleepGreeting(DateTime.now().hour),
            style: TextStyle(
              fontSize: 13,
              height: 1.1,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.4,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '把今天，轻轻放下',
            style: TextStyle(
              fontSize: desktop ? 34 : 30,
              height: 1.24,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              color: tokens.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// 大播放卡：没选过曲目时先拿目录第一首当门面，点一下就从它开始。
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.sleep, required this.desktop});

  final SleepState sleep;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final track = sleep.current ?? kSleepFirstTrack;
    final tab = sleepTabOf(track.category);
    final playing = sleep.playing;
    final loading = sleep.loading;
    final height = desktop ? 248.0 : 226.0;
    final inset = desktop ? 22.0 : 18.0;
    final playSize = desktop ? 58.0 : 52.0;
    final stemTop = desktop ? 52.0 : 46.0;

    return Semantics(
      container: true,
      label: '当前声景：${track.name}',
      child: Container(
        key: const Key('sleep-art-card'),
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: SleepPalette.cardLine),
          color: SleepPalette.nightBottom,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            return Stack(
              children: [
                Positioned.fill(
                  child: _SleepArt(
                    track: track,
                    playing: playing,
                    desktop: desktop,
                  ),
                ),
                // 流星：只在正在播放时每 5 秒划一道，独立一层重绘
                Positioned.fill(
                  child: _Meteor(playing: playing, desktop: desktop),
                ),
                // 压一层底：文字落在这一层上，浅色模式也不会糊在月亮的亮部上。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          SleepPalette.nightBottom.withValues(alpha: 0.0),
                          SleepPalette.nightBottom.withValues(alpha: 0.14),
                          SleepPalette.nightBottom.withValues(alpha: 0.48),
                          SleepPalette.nightBottom.withValues(alpha: 0.90),
                        ],
                        stops: const [0.10, 0.40, 0.68, 1.0],
                      ),
                    ),
                  ),
                ),
                // 顶部两行小字：左「此刻声景」，右英文角标
                Positioned(
                  top: desktop ? 20 : 16,
                  left: inset,
                  right: inset,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '此刻声景',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            letterSpacing: 2.4,
                            color: SleepPalette.cardLabel,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        tab.en,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          letterSpacing: 2.4,
                          color: SleepPalette.cardLabelDim,
                        ),
                      ),
                    ],
                  ),
                ),
                // 「播放头」：一根竖线 + 末端小点，在播时点亮成月金
                Positioned(
                  top: stemTop,
                  left: inset,
                  width: 1,
                  height: h * 0.44,
                  child: _PlayheadStem(
                    color: SleepPalette.moonHalo,
                    lit: playing,
                  ),
                ),
                // 底部：大字曲名 + 副标题（右侧留给圆形播放键）
                Positioned(
                  left: inset,
                  right: inset + playSize + 8,
                  bottom: inset,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: desktop ? 30 : 26,
                          height: 1.16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: desktop ? 2.4 : 2.0,
                          color: SleepPalette.cardText,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          letterSpacing: 0.4,
                          color: SleepPalette.cardDetail,
                        ),
                      ),
                      if (sleep.error != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          sleep.error!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: SleepPalette.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  right: inset,
                  bottom: inset,
                  child: _SleepPlayButton(
                    playing: playing,
                    loading: loading,
                    size: playSize,
                    onTap: () {
                      if (sleep.current == null) {
                        unawaited(sleep.tune(track));
                      } else {
                        unawaited(sleep.toggle());
                      }
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 播放头：竖线末端一枚小圆点（在播时更亮、带一圈微光）。
class _PlayheadStem extends StatelessWidget {
  const _PlayheadStem({required this.color, required this.lit});

  final Color color;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(width: 1, color: color.withValues(alpha: 0.34)),
        ),
        Positioned(
          left: -2.5,
          bottom: -2.5,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: lit ? 1.0 : 0.62),
              boxShadow: lit
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.85),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放状线：左侧状态（点 + 文案），右侧 REST / IDLE，底线一根发丝线。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.sleep});

  final SleepState sleep;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final playing = sleep.playing;
    final status = sleep.loading
        ? '准备中'
        : (playing ? '正在播放' : (sleep.current != null ? '已暂停' : '还没开始'));
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: playing ? tokens.accent : tokens.textFaint,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            status,
            style: TextStyle(
              fontSize: 11,
              height: 1.1,
              letterSpacing: 0.6,
              color: tokens.text.withValues(alpha: 0.62),
            ),
          ),
          const Spacer(),
          Text(
            playing ? 'REST' : 'IDLE',
            style: TextStyle(
              fontSize: 9,
              height: 1.1,
              letterSpacing: 1.8,
              color: playing ? tokens.accent : tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分类页签：短名 + 曲目数，选中走 accent 与一根短下划线。
class _TabBar extends StatelessWidget {
  const _TabBar({required this.active, required this.onChange});

  final SleepCategory active;
  final ValueChanged<SleepCategory> onChange;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.only(top: desktop ? 22 : 18),
      child: Row(
        children: [
          for (final tab in kSleepTabs)
            Padding(
              padding: EdgeInsets.only(right: tab == kSleepTabs.last ? 0 : 24),
              child: _SleepTabButton(
                key: Key('sleep-tab-${tab.id.name}'),
                tab: tab,
                selected: tab.id == active,
                onTap: () => onChange(tab.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _SleepTabButton extends StatelessWidget {
  const _SleepTabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final SleepTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final count = sleepTracksOf(tab.id).length;
    return Semantics(
      button: true,
      selected: selected,
      label: '${tab.label} $count 段',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Container(
          padding: const EdgeInsets.only(bottom: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? tokens.accent : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tab.label,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.6,
                  color: selected ? tokens.text : tokens.textDim,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 9,
                  height: 1.1,
                  letterSpacing: 1.0,
                  color: selected
                      ? tokens.accent.withValues(alpha: 0.8)
                      : tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单列声景表：缩略 + 曲名 / 质地 + 右侧「循环」或均衡柱，发丝线分隔。
class _SleepList extends StatelessWidget {
  const _SleepList({
    required this.tracks,
    required this.sleep,
    required this.desktop,
  });

  final List<SleepTrack> tracks;
  final SleepState sleep;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tracks.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: tokens.border),
          _SleepRow(
            key: Key('sleep-row-${tracks[i].id}'),
            track: tracks[i],
            selected: sleep.current?.id == tracks[i].id,
            live: sleep.current?.id == tracks[i].id && sleep.playing,
            desktop: desktop,
            onTap: () {
              if (sleep.current?.id == tracks[i].id) {
                unawaited(sleep.toggle());
              } else {
                unawaited(sleep.tune(tracks[i]));
              }
            },
          ),
        ],
      ],
    );
  }
}

/// 一行声景：48（窄屏 44）缩略方块 + 曲名 / 质地 + 右侧角标（在播时换成静息柱）。
class _SleepRow extends StatelessWidget {
  const _SleepRow({
    required this.track,
    required this.selected,
    required this.live,
    required this.desktop,
    required this.onTap,
    super.key,
  });

  final SleepTrack track;
  final bool selected;
  final bool live;
  final bool desktop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final thumb = desktop ? 48.0 : 44.0;
    return Semantics(
      button: true,
      selected: selected,
      label: '${track.name} ${track.detail}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: desktop ? 14 : 12),
          child: Row(
            children: [
              Container(
                width: thumb,
                height: thumb,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(desktop ? 13 : 12),
                  border: Border.all(color: tokens.borderStrong),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [track.artFrom, track.artTo],
                  ),
                ),
                child: Stack(
                  children: [
                    const Center(
                      child: SleepMoonIcon(
                        size: 17,
                        color: SleepPalette.thumbMoon,
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 9,
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: SleepPalette.star.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.6,
                        color: selected ? tokens.accent : tokens.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        letterSpacing: 0.2,
                        color: tokens.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (live)
                _EqualizerBars(color: tokens.accent)
              else
                Text(
                  '循环',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    letterSpacing: 0.8,
                    color: tokens.textFaint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 在播的三根均衡柱：只在「正在响」的那一行挂，减少动效时停在一帧。
class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars({required this.color});

  final Color color;

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  static const List<double> _base = <double>[12, 7, 15];
  static const double _boxHeight = 15;

  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _beat.value = 0.28;
      _beat.stop();
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  double _factor(int index) {
    final phase = (_beat.value + index / 3.0) % 1.0;
    return 0.42 + 0.58 * (0.5 - 0.5 * math.cos(2 * math.pi * phase));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _boxHeight,
      child: AnimatedBuilder(
        animation: _beat,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < _base.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Container(
                  width: 2,
                  height: _base[i] * _factor(i),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: i == 1 ? 0.55 : 0.9),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 页脚：一句轻话，前面一根短横。
class _FootLine extends StatelessWidget {
  const _FootLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      children: [
        Container(
          width: 26,
          height: 1,
          color: tokens.accent.withValues(alpha: 0.34),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.2,
            letterSpacing: 1.6,
            color: tokens.textFaint,
          ),
        ),
      ],
    );
  }
}

/// 夜空卡：固定的深蓝渐变 + 右上光晕 + 月亮 + 三圈呼吸环 + 星点 + 流星。
class _SleepArt extends StatefulWidget {
  const _SleepArt({
    required this.track,
    required this.playing,
    required this.desktop,
  });

  final SleepTrack track;
  final bool playing;
  final bool desktop;

  @override
  State<_SleepArt> createState() => _SleepArtState();
}

class _SleepArtState extends State<_SleepArt>
    with SingleTickerProviderStateMixin {
  /// 与 React `sleep-breathe` 同一个时长：11 秒一圈，三道相位各差 1/3。
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 11),
  );

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _SleepArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_reduceMotion) {
      _breathe.stop();
      _breathe.value = 0;
      return;
    }
    if (widget.playing) {
      if (!_breathe.isAnimating) _breathe.repeat();
      return;
    }
    // 暂停 / 没播过：停在当前相位，三圈环仍留在画面里（与 React 的
    // `animation-play-state: paused` 同一套语义）。
    _breathe.stop();
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SleepArtPainter(
        track: widget.track,
        desktop: widget.desktop,
        breathe: _breathe,
      ),
    );
  }
}

class _SleepArtPainter extends CustomPainter {
  _SleepArtPainter({
    required this.track,
    required this.desktop,
    required this.breathe,
  }) : super(repaint: breathe);

  final SleepTrack track;
  final bool desktop;
  final Animation<double> breathe;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 夜空底：固定三段深蓝，不随主题翻。
    final base = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        SleepPalette.nightTop,
        SleepPalette.nightMid,
        SleepPalette.nightBottom,
      ],
      stops: [0.0, 0.55, 1.0],
    );
    canvas.drawRect(rect, Paint()..shader = base.createShader(rect));

    // 当前曲目的一团微光：右上角，随曲目换色。
    final glowCenter = Offset(size.width * 0.80, size.height * 0.18);
    final glowRadius = size.shortestSide * 0.62;
    canvas.drawCircle(
      glowCenter,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            track.glow.withValues(alpha: 0.20),
            track.glow.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: glowCenter, radius: glowRadius)),
    );

    // 星点：固定坐标，不闪（动效留给月亮）。
    for (final star in _kStars) {
      canvas.drawCircle(
        Offset(size.width * star.x, size.height * star.y),
        star.size / 2,
        Paint()..color = SleepPalette.star.withValues(alpha: star.alpha),
      );
    }

    final moonSize = desktop ? 96.0 : 88.0;
    final moonRight = desktop ? 40.0 : 34.0;
    final moonTop = desktop ? 62.0 : 56.0;
    final moonCenter = Offset(
      size.width - moonRight - moonSize / 2,
      moonTop + moonSize / 2,
    );

    // 呼吸环：从月亮边缘向外推，11 秒一轮；暂停时停在各自相位上。
    final phase = breathe.value;
    for (var i = 0; i < 3; i++) {
      final t = (phase + i / 3.0) % 1.0;
      final scale = 1 + 1.06 * t;
      final alpha = t < 0.66
          ? 0.4 - (0.4 - 0.14) * (t / 0.66)
          : 0.14 * (1 - (t - 0.66) / 0.34);
      if (alpha <= 0.004) continue;
      canvas.drawCircle(
        moonCenter,
        (moonSize / 2) * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = SleepPalette.moonHalo.withValues(alpha: alpha),
      );
    }

    // 月亮的外光：CSS 的 box-shadow 用一层大范围的月金雾近似。
    canvas.drawCircle(
      moonCenter,
      moonSize * 0.78,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                SleepPalette.moonHalo.withValues(alpha: 0.30),
                SleepPalette.moonHalo.withValues(alpha: 0.12),
                SleepPalette.moonHalo.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.55, 1.0],
            ).createShader(
              Rect.fromCircle(center: moonCenter, radius: moonSize * 0.78),
            ),
    );

    // 月亮本体：径向暖白，边缘落到淡金。
    final moonRect = Rect.fromCircle(center: moonCenter, radius: moonSize / 2);
    canvas.drawCircle(
      moonCenter,
      moonSize / 2,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.24, -0.36),
          colors: [
            SleepPalette.moonCore,
            SleepPalette.moonMid,
            SleepPalette.moonEdge,
          ],
          stops: [0.0, 0.52, 1.0],
        ).createShader(moonRect),
    );

    // 三枚环形山：只给月亮一点「表面」，太干净会像个灯泡。
    final moonLeft = moonCenter.dx - moonSize / 2;
    final moonTopEdge = moonCenter.dy - moonSize / 2;
    void crater(double left, double top, double diameter, Color color) {
      canvas.drawCircle(
        Offset(
          moonLeft + moonSize * left + moonSize * diameter / 2,
          moonTopEdge + moonSize * top + moonSize * diameter / 2,
        ),
        moonSize * diameter / 2,
        Paint()..color = color,
      );
    }

    crater(0.24, 0.30, 0.18, SleepPalette.craterStrong);
    crater(0.54, 0.54, 0.26, SleepPalette.craterSoft);
    crater(0.34, 0.68, 0.11, SleepPalette.craterStrong);

    // 底部压暗：卡面大字落在这一层上。
    final horizonRect = Rect.fromLTWH(
      0,
      size.height * 0.56,
      size.width,
      size.height * 0.44,
    );
    canvas.drawRect(
      horizonRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            SleepPalette.horizon.withValues(alpha: 0.0),
            SleepPalette.horizon,
          ],
        ).createShader(horizonRect),
    );
  }

  @override
  bool shouldRepaint(covariant _SleepArtPainter oldDelegate) =>
      oldDelegate.track.id != track.id ||
      oldDelegate.desktop != desktop ||
      oldDelegate.breathe != breathe;
}

/// 流星：每 5 秒从卡面右上（68% / 16%）沿一条极轻微的弧线掠向左下（16% / 58%），
/// 1.25 秒飞完、随后静默 3.75 秒。只在「正在播放」时点火 —— 暂停即收掉，
/// 重新起播从右上重新亮起。
/// 走位与收尾节奏取自 React `.sleep-art__meteor` / `sleep-meteor-arc`
/// （同一组关键帧，改一处必须改另一处）。
class _Meteor extends StatefulWidget {
  const _Meteor({required this.playing, required this.desktop});

  final bool playing;
  final bool desktop;

  @override
  State<_Meteor> createState() => _MeteorState();
}

class _MeteorState extends State<_Meteor> with SingleTickerProviderStateMixin {
  /// 一轮 5 秒（与 CSS `animation: sleep-meteor-arc 5s linear infinite` 同周期）。
  late final AnimationController _arc = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Meteor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    // 没在播 / 减少动效：停在「已经飞过去」的一帧，画面里什么都不留
    if (!widget.playing || MediaQuery.of(context).disableAnimations) {
      _arc.stop();
      _arc.value = 1;
      return;
    }
    if (!_arc.isAnimating) {
      // 重新起播：从右上重新点火，而不是接着半空里的旧相位
      _arc.value = 0;
      _arc.repeat();
    }
  }

  @override
  void dispose() {
    _arc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 单独一层：飞的那 1.25 秒每帧只重画这道光，不带着整张夜空一起刷。
    return RepaintBoundary(
      child: CustomPaint(
        painter: _MeteorPainter(arc: _arc, desktop: widget.desktop),
      ),
    );
  }
}

class _MeteorPainter extends CustomPainter {
  _MeteorPainter({required this.arc, required this.desktop})
    : super(repaint: arc);

  final Animation<double> arc;
  final bool desktop;

  /// 起点 / 终点（卡面比例）：右上 68% / 16% → 左下 16% / 58%。
  static const Offset _from = Offset(0.68, 0.16);
  static const Offset _to = Offset(0.16, 0.58);

  /// 弧线控制点：比弦中再压低一点，走一条极轻微的抛物线
  /// （入口 19°、出口 9°，尾巴始终贴着当帧的切线）。与 CSS
  /// `.sleep-art__meteor i` 的七个 `--meteor-rot-*` 采样同一组角度。
  static const Offset _bow = Offset(0.40, 0.46);

  /// 5 秒一轮的节奏表：每行是（时刻, 走位进度, 尾长占比, 亮度），
  /// 与 CSS `sleep-meteor-arc` / `sleep-meteor-burn` 的关键帧逐项相同：
  /// 点火 → 11.5% 峰值（尾抽满） → 16% 开始收 → 25%（1.25 秒）燃尽归零。
  static const List<(double, double, double, double)> _keys = [
    (0.000, 0.00, 0.30, 0.00),
    (0.035, 0.12, 0.58, 0.50),
    (0.070, 0.30, 0.84, 0.86),
    (0.115, 0.55, 1.00, 1.00),
    (0.160, 0.78, 0.96, 0.90),
    (0.205, 0.93, 0.66, 0.50),
    (0.250, 1.00, 0.24, 0.00),
    (1.000, 1.00, 0.24, 0.00),
  ];

  /// 在节奏表里线性插值，取这一刻的（进度, 尾长, 亮度）。
  (double, double, double) _frameAt(double t) {
    final keys = _keys;
    for (var i = 1; i < keys.length; i++) {
      final next = keys[i];
      if (t <= next.$1) {
        final prev = keys[i - 1];
        final span = next.$1 - prev.$1;
        final f = span <= 0 ? 1.0 : (t - prev.$1) / span;
        return (
          prev.$2 + (next.$2 - prev.$2) * f,
          prev.$3 + (next.$3 - prev.$3) * f,
          prev.$4 + (next.$4 - prev.$4) * f,
        );
      }
    }
    final last = keys.last;
    return (last.$2, last.$3, last.$4);
  }

  /// 弧线上的点（二次贝塞尔，t 就是走位进度）。
  Offset _pointAt(double p, Size size) {
    final u = 1 - p;
    return Offset(
      size.width * (u * u * _from.dx + 2 * u * p * _bow.dx + p * p * _to.dx),
      size.height * (u * u * _from.dy + 2 * u * p * _bow.dy + p * p * _to.dy),
    );
  }

  /// 该点的切线方向（未归一化）。
  Offset _tangentAt(double p, Size size) {
    final u = 1 - p;
    return Offset(
      size.width * (2 * u * (_bow.dx - _from.dx) + 2 * p * (_to.dx - _bow.dx)),
      size.height * (2 * u * (_bow.dy - _from.dy) + 2 * p * (_to.dy - _bow.dy)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final frame = _frameAt(arc.value);
    final progress = frame.$1;
    final tailPart = frame.$2;
    final alpha = frame.$3;
    if (alpha <= 0.004 || tailPart <= 0.01) return;

    final head = _pointAt(progress, size);

    // 拖尾顺着来路往回长：长度按节奏表伸缩（桌面 176 / 窄屏 146），
    // 粗细跟着卡面收（桌面 2 / 窄屏 1.6）。
    final maxTrail = desktop ? 176.0 : 146.0;
    final thick = desktop ? 2.0 : 1.6;
    final tangent = _tangentAt(progress, size);
    final len = tangent.distance;
    if (len <= 0) return;
    final unit = tangent / len;
    final tail = head - unit * (maxTrail * tailPart);

    // 外圈柔光：同一条线加粗再糊开，别让整道线亮成一根灯管。
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = thick * 3.4
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..shader = ui.Gradient.linear(tail, head, [
          const Color(0x00FFF5DA),
          const Color(0xFFFFF5DA).withValues(alpha: 0.20 * alpha),
        ]),
    );

    // 本体：星头亮、拖尾一路淡出（与 CSS 那条 90° 线性渐变同一组色标）。
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = thick
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..shader = ui.Gradient.linear(
          tail,
          head,
          [
            const Color(0x00FFF4D6),
            const Color(0xFFFFF4D6).withValues(alpha: 0.03 * alpha),
            const Color(0xFFFFF4D6).withValues(alpha: 0.14 * alpha),
            const Color(0xFFFFF4D6).withValues(alpha: 0.55 * alpha),
            const Color(0xFFFFFDF4).withValues(alpha: 0.98 * alpha),
          ],
          const [0.0, 0.28, 0.50, 0.78, 1.0],
        ),
    );

    // 星头：一枚亮核 + 一圈柔光（柔光用径向渐变，边缘别落成一颗灰珠子）。
    canvas.drawCircle(
      head,
      6,
      Paint()
        ..shader = ui.Gradient.radial(head, 6, [
          const Color(0xFFFFF6DE).withValues(alpha: 0.30 * alpha),
          const Color(0xFFFFF6DE).withValues(alpha: 0.0),
        ]),
    );
    canvas.drawCircle(
      head,
      1.5,
      Paint()..color = const Color(0xFFFFFDF6).withValues(alpha: alpha),
    );

    // 尾巴上的一点碎屑：骑在尾巴 62% 处，跟着尾长一起烧短
    canvas.drawCircle(
      head - unit * (maxTrail * tailPart * 0.62),
      0.6,
      Paint()..color = const Color(0xFFFFF8E6).withValues(alpha: 0.3 * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _MeteorPainter oldDelegate) =>
      oldDelegate.desktop != desktop || oldDelegate.arc != arc;
}

/// 主角播放圆钮：月金实底 + 墨色图标。加载时只转一圈细环。
class _SleepPlayButton extends StatelessWidget {
  const _SleepPlayButton({
    required this.playing,
    required this.loading,
    required this.size,
    required this.onTap,
  });

  final bool playing;
  final bool loading;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? '暂停助眠声景' : '播放助眠声景',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: SleepPalette.playBg,
        shape: const CircleBorder(),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: size * 0.35,
                      height: size * 0.35,
                      child: const CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          SleepPalette.playInk,
                        ),
                      ),
                    )
                  : CustomPaint(
                      size: Size.square(size * 0.38),
                      painter: _PlayGlyphPainter(
                        playing: playing,
                        color: SleepPalette.playInk,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayGlyphPainter extends CustomPainter {
  const _PlayGlyphPainter({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (playing) {
      final barWidth = size.width * 0.16;
      final barHeight = size.height * 0.62;
      final top = (size.height - barHeight) / 2;
      for (final left in [size.width * 0.30, size.width * 0.54]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, top, barWidth, barHeight),
            Radius.circular(barWidth / 2),
          ),
          paint,
        );
      }
      return;
    }
    final path = Path()
      ..moveTo(size.width * 0.36, size.height * 0.20)
      ..lineTo(size.width * 0.36, size.height * 0.80)
      ..lineTo(size.width * 0.78, size.height * 0.50)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PlayGlyphPainter oldDelegate) =>
      oldDelegate.playing != playing || oldDelegate.color != color;
}
