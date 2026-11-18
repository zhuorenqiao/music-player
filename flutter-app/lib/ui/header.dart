// lib/ui/header.dart
//
// 顶栏：左侧品牌区，右侧唯一的「更多」按钮。
//
//   - 宽 <480（`isUltraCompact`）：隐藏副标题，按钮收成 36×36 图标钮；
//   - 其余：三点图标 + 「更多」文字胶囊（36px 高、999 圆角）。
//
// 按钮的视觉文案与读屏名都是「更多」（React `LibraryMenu.tsx:65` 的
// `btn__text` 与 `aria-label="更多"` 同名）—— 从前 Flutter 侧写的是「菜单」
// 而读屏叫「更多」，与原版差一截，一并对齐。语义里只留这一套名字，
// 否则读屏会念两遍。
//
// 抽屉用 `showGeneralDialog` 从右侧滑入（不是底部弹层）：原版是右边缘的窄面板。
// 三个动作回调由调用方注入，`HomePage` 接 `core/file_picking.dart`。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'drawer_menu.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClearPlaylist,
    this.onSwitchView,
    this.immersive = false,
    super.key,
  });

  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onClearPlaylist;

  /// 顶部「模式切换」按钮（React `App.tsx:220-229` 的 `.app__mode`）：
  /// 在封面页 / 完整歌词页之间切。null 时不渲染（纯展示 / 旧调用点保持原样）。
  final VoidCallback? onSwitchView;

  /// 当前是否处于沉浸（歌词页）模式，决定按钮图标与读屏名。
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final compact = isUltraCompact(MediaQuery.sizeOf(context).width);
    return Row(
      children: [
        Expanded(child: _Brand(compact: compact)),
        const SizedBox(width: 8),
        // `.app__actions`：模式切换在菜单左侧，gap 8（app.css:580-599）。
        if (onSwitchView != null) ...[
          Semantics(
            key: const Key('view-mode-button'),
            button: true,
            label: immersive ? '切换到简约模式（封面页）' : '切换到沉浸模式（歌词页）',
            excludeSemantics: true,
            onTap: onSwitchView,
            child: InkWell(
              onTap: onSwitchView,
              borderRadius: BorderRadius.circular(999),
              overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
              child: _ViewModeChip(compact: compact, immersive: immersive),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Semantics(
          button: true,
          label: '更多',
          excludeSemantics: true,
          onTap: () => _openMenu(context),
          child: InkWell(
            key: const Key('menu-button'),
            onTap: () => _openMenu(context),
            borderRadius: BorderRadius.circular(999),
            overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
            child: _MenuChip(compact: compact),
          ),
        ),
      ],
    );
  }

  /// 右侧抽屉：遮罩可点、Esc 可关（`barrierDismissible`），滑入 240ms。
  void _openMenu(BuildContext context) {
    final tokens = context.tokens;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭菜单',
      barrierColor: scrimColor(tokens),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        minimum: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.topRight,
          child: DrawerMenu(
            onAddFiles: onAddFiles,
            onAddFolder: onAddFolder,
            onClear: onClearPlaylist,
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
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

/// 模式切换按钮：与菜单同档（36px 高、12.5px 字、16px 图标、999 圆角）。
/// 宽 <480 时 `.btn__text` 隐藏、按钮收成 36×36（app.css:4022-4045）。
///
/// 图标是**描边**风格的两颗自定义图标（React `DiscIcon` / `LyricsIcon`），
/// 不是 Material 的 `Icons.album` / `Icons.queue_music` —— 后者是实心的，
/// 与原版的 1.7~1.8 描边观感差得很远。
class _ViewModeChip extends StatelessWidget {
  const _ViewModeChip({required this.compact, required this.immersive});

  final bool compact;
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      height: 36,
      width: compact ? 36 : null,
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
        color: tokens.surface,
      ),
      alignment: Alignment.center,
      child: compact
          ? _ModeIcon(immersive: immersive, size: 16, color: tokens.text)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ModeIcon(immersive: immersive, size: 16, color: tokens.text),
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

/// 菜单按钮：窄屏只剩一个 36×36 的图标位，其余时候是图标 + 文案的胶囊。
///
/// 图标是**三个竖排圆点**（React `MoreIcon`：cx=12、cy=5.5/12/18.5、r=1.7，
/// `fill=currentColor`），不是三条横线 —— 后者是 Material 的 `Icons.menu`，
/// 与原版的「更多」语义对不上。窄屏（<.btn__text 隐藏>）时仍保留这三颗点。
class _MenuChip extends StatelessWidget {
  const _MenuChip({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      height: 36,
      width: compact ? 36 : null,
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        // 白底：与顶栏旁边那颗排序圆钮、卡片里 T/水滴/闹钟同一档（--surface，
        // React `.btn` 的 `background: var(--surface)`）。从前这里只描边不填色，
        // 透明底会透出背景渐变，跟旁边几颗白钮不成一套。
        color: tokens.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
      ),
      alignment: Alignment.center,
      child: compact
          ? const _MoreIcon(size: 16)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _MoreIcon(size: 16),
                const SizedBox(width: 6),
                Text(
                  '更多',
                  style: TextStyle(fontSize: 12.5, color: tokens.text),
                ),
              ],
            ),
    );
  }
}

/// React `MoreIcon` 的等价物：三个竖排圆点（filled）。
///
/// 规格逐字：viewBox 24×24、circle cx=12、cy=5.5/12/18.5、r=1.7、fill=currentColor。
/// 用 CustomPaint 画而不是拼三个 `Icon`（Material 里没有对应的三点图标），
/// 这样尺寸与圆点半径都由这份规格说了算。
class _MoreIcon extends StatelessWidget {
  const _MoreIcon({required this.size});

  /// 图标边长（`.app__actions .btn .icon { width:16px; height:16px }`）。
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MoreIconPainter(tokens.text),
        size: Size.square(size),
      ),
    );
  }
}

class _MoreIconPainter extends CustomPainter {
  const _MoreIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 24×24 视口 → 按实际尺寸缩放（描边宽度不缩放，圆点半径按比例）。
    final s = size.width / 24;
    final paint = Paint()..color = color;
    final r = 1.7 * s;
    for (final cy in const [5.5, 12.0, 18.5]) {
      canvas.drawCircle(Offset(12 * s, cy * s), r, paint);
    }
  }

  @override
  bool shouldRepaint(_MoreIconPainter oldDelegate) => oldDelegate.color != color;
}
