// lib/ui/header.dart
//
// 顶栏：左侧品牌区，右侧「模式切换」+「电台」+「更多」。
//
//   - 宽 <900（`!isDesktop`，与 `@media (max-width: 899px)` 同档）：
//     品牌整块不渲染（页面已铺满，品牌让位给卡片），按钮只留图标、
//     并且**不再有按钮的「地」**（无底色 / 无描边 / 无圆角），看上去就是一枚
//     浮在卡片右上角的 ⋯；「模式切换」整个不渲染 —— 点封面板 / 曲目区就能进歌词页，
//     歌词页点空白处就能退回来，这颗按钮在小屏是重复的。顶栏只剩「电台」与「更多」。
//     这一组按钮由 [HomeLayout] 浮到播放卡右上角，简约 / 沉浸两种模式同一个位置。
//   - 宽 ≥900：品牌 40×40 logo + 中文标题 + 英文副标题；按钮是
//     三点图标 + 文字胶囊（36px 高、999 圆角）。
//
// 按钮的视觉文案与读屏名都是「更多」（React `LibraryMenu.tsx:65` 的
// `btn__text` 与 `aria-label="更多"` 同名）—— 从前 Flutter 侧写的是「菜单」
// 而读屏叫「更多」，与原版差一截，一并对齐。语义里只留这一套名字，
// 否则读屏会念两遍。
//
// 「更多」按钮与抽屉住在 `more_menu.dart`（电台页页头也用它，两处同一颗）。
// 三个动作回调由调用方注入，`HomePage` 接 `core/file_picking.dart`。
//
// T31 起「更多」左侧多一颗「电台」：进电台页的入口。它是顶栏里**唯一**带主题色
// 的一颗（accent 描边 + accent 图标 + accent 微光），因为它是「另一个页面」的
// 入口而不是又一个工具按钮；窄屏与其它按钮一样收成 32×32 图标，但保留 accent
// 着色，仍能一眼认出来。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'more_menu.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClearPlaylist,
    this.onOpenRadio,
    this.onSwitchView,
    this.immersive = false,
    super.key,
  });

  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onClearPlaylist;

  /// 「电台」入口：切到电台页。null 时不渲染（纯展示 / 旧调用点保持原样）。
  final VoidCallback? onOpenRadio;

  /// 顶部「模式切换」按钮（React `App.tsx:220-229` 的 `.app__mode`）：
  /// 在封面页 / 完整歌词页之间切。null 时不渲染（纯展示 / 旧调用点保持原样）。
  final VoidCallback? onSwitchView;

  /// 当前是否处于沉浸（歌词页）模式，决定按钮图标与读屏名。
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final width = MediaQuery.sizeOf(context).width;
    // 窄屏：没有品牌、按钮只留图标并收到 32px（app.css 的 `@media (max-width: 899px)`
    // 里那三条 `.brand { display: none }` / `.btn__text { display: none }` /
    // `.app__actions .btn { width: 32px; min-height: 32px }`）。
    final narrow = !isDesktop(width);
    // 极窄（<480）才隐藏副标题 —— 品牌现在只在桌面出现，这条留给未来复用。
    final compact = isUltraCompact(width);
    // 模式切换：窄屏整个不渲染（简约模式点曲目区进歌词页、歌词页点空白处退出，
    // 这颗按钮在小屏是重复的；app.css 的 `@media (max-width: 899px)` 里
    // `.app__mode { display: none }`）。
    final showMode = onSwitchView != null && !narrow;
    // 电台入口：桌面与「更多」并排；窄屏仍是图标一枚（见 [_RadioChip]）。
    final openRadio = onOpenRadio;

    final children = <Widget>[];
    if (!narrow) {
      children
        ..add(Expanded(child: _Brand(compact: compact)))
        ..add(const SizedBox(width: 8));
    }
    if (showMode) {
      final switchView = onSwitchView!;
      children
        ..add(
          Semantics(
            key: const Key('view-mode-button'),
            button: true,
            label: immersive ? '切换到简约模式（封面页）' : '切换到沉浸模式（歌词页）',
            excludeSemantics: true,
            onTap: switchView,
            child: InkWell(
              onTap: switchView,
              borderRadius: BorderRadius.circular(999),
              overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
              child: _ViewModeChip(iconOnly: narrow, immersive: immersive),
            ),
          ),
        )
        ..add(const SizedBox(width: 8));
    }
    if (openRadio != null) {
      children
        ..add(
          Semantics(
            button: true,
            label: '电台',
            excludeSemantics: true,
            onTap: openRadio,
            child: InkWell(
              key: const Key('radio-button'),
              onTap: openRadio,
              borderRadius: BorderRadius.circular(999),
              overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
              child: _RadioChip(iconOnly: narrow),
            ),
          ),
        )
        ..add(const SizedBox(width: 8));
    }
    children.add(
      MoreMenu(
        onAddFiles: onAddFiles,
        onAddFolder: onAddFolder,
        onClearPlaylist: onClearPlaylist,
        iconOnly: narrow,
      ),
    );

    return Row(
      mainAxisAlignment: narrow
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: children,
    );
  }
}

/// 品牌区：40×40 圆角 logo + 中文标题（窄屏时不带英文副标题）。
class _Brand extends StatelessWidget {
  const _Brand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tokens.accentLine),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [tokens.accentSoft, tokens.cardB],
            ),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.graphic_eq, size: 18, color: tokens.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '流光音乐',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: tokens.text,
                ),
              ),
              if (!compact)
                Text(
                  'LIGHT MUSIC PLAYER',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.7,
                    color: tokens.textFaint,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 模式切换按钮：桌面与菜单同档（36px 高、12.5px 字、16px 图标、999 圆角）；
/// 窄屏 `.btn__text` 隐藏、按钮收成 32×32、图标 15px
/// （app.css 的 `@media (max-width: 899px)`：`.app__actions .btn { width:32px;
/// min-height:32px }` + `.app__actions .btn .icon { width:15px }`）。
///
/// 图标是**描边**风格的两颗自定义图标（React `DiscIcon` / `LyricsIcon`），
/// 不是 Material 的 `Icons.album` / `Icons.queue_music` —— 后者是实心的，
/// 与原版的 1.7~1.8 描边观感差得很远。
class _ViewModeChip extends StatelessWidget {
  const _ViewModeChip({required this.iconOnly, required this.immersive});

  /// 窄屏档：只留图标、32px 方块；桌面档：图标 + 文字胶囊。
  final bool iconOnly;
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final iconSize = iconOnly ? 15.0 : 16.0;
    return Container(
      height: iconOnly ? 32 : 36,
      width: iconOnly ? 32 : null,
      padding: iconOnly
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
        color: tokens.surface,
      ),
      alignment: Alignment.center,
      child: iconOnly
          ? _ModeIcon(immersive: immersive, size: iconSize, color: tokens.text)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ModeIcon(
                  immersive: immersive,
                  size: iconSize,
                  color: tokens.text,
                ),
                const SizedBox(width: 6),
                Text(
                  immersive ? '简约模式' : '沉浸模式',
                  style: TextStyle(fontSize: 12.5, color: tokens.text),
                ),
              ],
            ),
    );
  }
}

/// 模式切换图标：沉浸态是歌词行+音符（`LyricsIcon`），简约态是唱片（`DiscIcon`）。
///
/// 两颗都按 React 的 SVG 规格用 CustomPaint 画：
///   * DiscIcon：circle(12,12,r=8.5) 描边 1.7 + 中心实心点 r=2.4；
///   * LyricsIcon：三条歌词横线 + 一个双音符（stem + 两个 r=2 的圆），
///     描边 1.8、圆端。
class _ModeIcon extends StatelessWidget {
  const _ModeIcon({
    required this.immersive,
    required this.size,
    required this.color,
  });

  final bool immersive;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ModeIconPainter(immersive: immersive, color: color),
        size: Size.square(size),
      ),
    );
  }
}

class _ModeIconPainter extends CustomPainter {
  const _ModeIconPainter({required this.immersive, required this.color});

  final bool immersive;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = (immersive ? 1.8 : 1.7) * s;
    final fill = Paint()..color = color;

    if (!immersive) {
      // DiscIcon：外圈 r=8.5 + 中心实心点 r=2.4。
      canvas.drawCircle(Offset(12 * s, 12 * s), 8.5 * s, stroke);
      canvas.drawCircle(Offset(12 * s, 12 * s), 2.4 * s, fill);
      return;
    }

    // LyricsIcon：左侧三条歌词横线。
    for (final (dy, len) in const [(7.0, 7.0), (11.5, 7.0), (16.0, 4.5)]) {
      canvas.drawLine(
        Offset(3.5 * s, dy * s),
        Offset((3.5 + len) * s, dy * s),
        stroke,
      );
    }
    // 右侧双音符：两根竖杆 + 两个圆。
    final path = Path()
      ..moveTo(15 * s, 16.5 * s)
      ..lineTo(15 * s, 6.2 * s)
      ..lineTo(19.5 * s, 5.1 * s)
      ..lineTo(19.5 * s, 14.7 * s);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(Offset(13 * s, 16.8 * s), 2 * s, stroke);
    canvas.drawCircle(Offset(17.5 * s, 15.6 * s), 2 * s, stroke);
  }

  @override
  bool shouldRepaint(_ModeIconPainter oldDelegate) =>
      oldDelegate.immersive != immersive || oldDelegate.color != color;
}

/// 「电台」入口胶囊。
///
/// 顶栏里唯一带主题色的一颗：accent 描边 + accent 图标 + 一点点外发光，
/// 与旁边的「模式切换 / 更多」那两颗素色胶囊分得开，又不会抢走播放按钮的注意力。
/// 窄屏（<900）与其它顶栏按钮同一套规则：只剩 32×32 图标、去掉「地」，
/// 但图标保留 accent 色 —— 它是另一个页面的入口，颜色是它唯一的身份标记。
class _RadioChip extends StatelessWidget {
  const _RadioChip({required this.iconOnly});

  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (iconOnly) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Center(child: _RadioIcon(size: 18, color: tokens.accent)),
      );
    }
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.accentLine),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.accentSoft, tokens.surface],
        ),
        boxShadow: [
          BoxShadow(
            color: tokens.accent.withValues(alpha: 0.16),
            blurRadius: 18,
            spreadRadius: -8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RadioIcon(size: 16, color: tokens.accent),
          const SizedBox(width: 6),
          Text(
            '电台',
            style: TextStyle(
              fontSize: 12.5,
              letterSpacing: 0.6,
              color: tokens.text,
            ),
          ),
          const SizedBox(width: 6),
          // 一颗 4px 的「在播」点：让入口看起来像「开着的一台电台」，
          // 而不是又一个纯图标按钮（只有装饰作用，点整颗胶囊都能进页面）。
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.8),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 电台图标：下方一颗实心点 + 上方三道同心弧（广播波）。
///
/// 规格：viewBox 24×24，圆心 (12, 17.2)，点 r=1.9，弧半径 4.6 / 7.2 / 9.8，
/// 每道都从 180° 扫到 360°（正上方那半圈），描边 1.6、圆端。
class _RadioIcon extends StatelessWidget {
  const _RadioIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RadioIconPainter(color: color),
        size: Size.square(size),
      ),
    );
  }
}

class _RadioIconPainter extends CustomPainter {
  const _RadioIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final center = Offset(12 * s, 17.2 * s);
    canvas.drawCircle(center, 1.9 * s, Paint()..color = color);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6 * s;
    for (final radius in const [4.6, 7.2, 9.8]) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * s),
        math.pi,
        math.pi,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_RadioIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
