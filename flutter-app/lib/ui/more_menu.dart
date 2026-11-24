// lib/ui/more_menu.dart
//
// 「更多」按钮 + 从右侧滑出的一级抽屉。音乐页顶栏和电台页顶栏共用这一颗：
// 电台页是独立路由，换肤入口不能只在音乐页找得到（React `LibraryMenu.tsx`
// 在 `RadioPage.tsx` 里也是同一颗）。
//
// 外观对译 React `src/components/LibraryMenu.tsx` + app.css：
//   · 桌面：19px ⋯ + 「更多」文字的 36px 白底胶囊；
//   · 窄屏（<900）：文案隐藏、按钮的「地」（底色 / 描边 / 圆角）全去掉，
//     只剩 32×32 的透明点击区 —— 看上去是一枚浮在页头右侧的 ⋯。
//
// 抽屉用 `showGeneralDialog` 从右边缘滑入（不是底部弹层），240ms；
// 遮罩色取 `--scrim`（[scrimColor]），与 Web `.drawer__scrim` 同源。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'drawer_menu.dart';

/// 顶栏 / 页头的「更多」入口。
///
/// 音乐页传三个曲库动作（接 `core/file_picking.dart`）；电台页只传
/// `showLibraryActions: false`，抽屉里只留「换肤」。
class MoreMenu extends StatelessWidget {
  const MoreMenu({
    this.onAddFiles,
    this.onAddFolder,
    this.onClearPlaylist,
    this.showLibraryActions = true,
    this.iconOnly,
    super.key,
  });

  /// 曲库动作：只在 [showLibraryActions] 时用到（电台页只留换肤，不传）。
  final Future<void> Function()? onAddFiles;
  final Future<void> Function()? onAddFolder;
  final Future<void> Function()? onClearPlaylist;

  /// 是否展示「添加音乐 / 清空播放列表」。
  /// 电台页传 false：那页只留「换肤」。
  final bool showLibraryActions;

  /// 窄屏档：只留 ⋯（默认按窗口宽度自行判断，与 [isDesktop] 同档）。
  final bool? iconOnly;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final narrow = iconOnly ?? !isDesktop(MediaQuery.sizeOf(context).width);
    return Semantics(
      button: true,
      label: '更多',
      excludeSemantics: true,
      onTap: () => _open(context),
      child: InkWell(
        key: const Key('menu-button'),
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(999),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: _MenuChip(iconOnly: narrow),
      ),
    );
  }

  /// 右侧抽屉：遮罩可点、Esc 可关（`barrierDismissible`），滑入 240ms。
  void _open(BuildContext context) {
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
            onAddFiles: onAddFiles ?? () async {},
            onAddFolder: onAddFolder ?? () async {},
            onClear: onClearPlaylist ?? () async {},
            showLibraryActions: showLibraryActions,
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

/// 菜单按钮：窄屏只剩那颗 ⋯（连按钮的「地」都不要），
/// 桌面是图标 + 文案的 36px 胶囊。
///
/// 图标是**三个竖排圆点**（React `MoreIcon`：cx=12、cy=5.5/12/18.5、r=1.7，
/// `fill=currentColor`），不是三条横线 —— 后者是 Material 的 `Icons.menu`，
/// 与原版的「更多」语义对不上。
class _MenuChip extends StatelessWidget {
  const _MenuChip({required this.iconOnly});

  /// 窄屏档：只留图标、32×32 的透明点击区；桌面档：图标 + 「更多」文字胶囊。
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 窄屏：底色 / 描边 / 圆角全去掉，看上去就是一枚浮在卡片角上的 ⋯
    // （对译 app.css 小屏媒体块里 `.app__actions .btn { border: 0;
    // background: none; box-shadow: none; color: var(--text-dim) }`）。
    // 32×32 的点击区保留 —— 透明不等于点不到；图标 19px 居中。
    if (iconOnly) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Center(child: _MoreIcon(size: 19, color: tokens.textDim)),
      );
    }
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        // 白底：与顶栏旁边那颗排序圆钮、卡片里 T/水滴/闹钟同一档（--surface，
        // React `.btn` 的 `background: var(--surface)`）。从前这里只描边不填色，
        // 透明底会透出背景渐变，跟旁边几颗白钮不成一套。
        color: tokens.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MoreIcon(size: 19),
          const SizedBox(width: 6),
          Text('更多', style: TextStyle(fontSize: 12.5, color: tokens.text)),
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
  const _MoreIcon({required this.size, this.color});

  /// 图标边长（`.app__actions .btn .icon`：桌面与窄屏都是 19px）。
  final double size;

  /// 不传就用正文色；窄屏那颗要用 `--text-dim`（比正文浅一档）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MoreIconPainter(color ?? tokens.text),
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
  bool shouldRepaint(_MoreIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
