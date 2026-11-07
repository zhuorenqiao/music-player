// lib/ui/header.dart
//
// 顶栏：左侧品牌区，右侧唯一的「菜单」按钮。
//
//   - 宽 <480（`isUltraCompact`）：隐藏副标题，按钮收成 36×36 图标钮；
//   - 其余：图标 + 「菜单」文字胶囊（36px 高、999 圆角）。
//
// 按钮的读屏名固定是「更多」（原版 `aria-label="更多"`），与视觉文案无关 ——
// 语义里只留这一套名字，否则读屏会念两遍。
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
    super.key,
  });

  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onClearPlaylist;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final compact = isUltraCompact(MediaQuery.sizeOf(context).width);
    return Row(
      children: [
        Expanded(child: _Brand(compact: compact)),
        const SizedBox(width: 8),
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

/// 菜单按钮：窄屏只剩一个 36×36 的图标位，其余时候是图标 + 文案的胶囊。
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
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.border),
      ),
      alignment: Alignment.center,
      child: compact
          ? Icon(Icons.menu, size: 16, color: tokens.text)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.menu, size: 16, color: tokens.text),
                const SizedBox(width: 6),
                Text(
                  '菜单',
                  style: TextStyle(fontSize: 12.5, color: tokens.text),
                ),
              ],
            ),
    );
  }
}
