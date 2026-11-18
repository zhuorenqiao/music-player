// lib/ui/drawer_menu.dart
//
// 一级抽屉菜单：添加音乐 / 添加整个文件夹 / 清空播放列表 / 换肤 四个一级入口。
// 平铺 44px 行、16px 图标 + 13px 文案，不带任何说明文字。
//
// 只画内容，不负责打开：遮罩、滑入动画与「先收抽屉再执行」的时序在
// `header.dart` 的 `AppHeader` 里。三个回调都由调用方注入，测试不碰 file_picker。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'theme_drawer.dart' show showThemeDrawer;

/// 抽屉里的一个入口动作。
typedef MenuAction = Future<void> Function();

/// 遮罩色：直接取 `--scrim`（[AppTokens.scrim]）—— 与 React
/// `.drawer__scrim { background: var(--scrim) }`（app.css:3207）同源。
///
/// 深色三套 `rgba(4, 8, 12, 0.66)`（粉/蓝是 0.68）、浅色三套
/// `rgba(28, 42, 56, 0.3)`（app.css:82/:190/:294/:336），都是**压暗**背景。
///
/// 不要再用 `tokens.bg.withValues(alpha: .66)` 派生：浅色主题的 `--bg` 是近白色，
/// 派生出来是一层 66% 的「白纱」—— 背景被提亮、正文几乎糊掉，和原版把页面
/// 推远的观感正好相反（弹层一开，整页像被漂白过）。
Color scrimColor(AppTokens tokens) => tokens.scrim;

/// 右侧一级抽屉。宽度固定 [width]，屏幕更窄时按可用宽度收。
class DrawerMenu extends StatelessWidget {
  const DrawerMenu({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClear,
    super.key,
  });

  final MenuAction onAddFiles;
  final MenuAction onAddFolder;
  final MenuAction onClear;

  /// 收窄后的抽屉宽度；原版一级菜单是 `min(288px, 82vw)`，这里取 300。
  static const double width = 300;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = BorderRadius.circular(kRadiusXl);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 小屏（如 320）上固定 300 会把外面的 12px 边距挤爆，按可用宽度收
        final panelWidth = constraints.hasBoundedWidth
            ? math.min(width, constraints.maxWidth)
            : width;
        return SizedBox(
          width: panelWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tokens.borderStrong),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tokens.sheetA, tokens.sheetB],
              ),
              boxShadow: tokens.shadowCard,
            ),
            child: ClipRRect(
              borderRadius: radius,
              // 透明 Material 只为给 InkWell 一块画布，底色已经在外面画好了
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Head(onClose: () => _close(context)),
                    _MenuRow(
                      icon: Icons.add,
                      label: '添加音乐',
                      onTap: () => _closeAnd(context, onAddFiles),
                    ),
                    _MenuRow(
                      icon: Icons.folder_open,
                      label: '添加整个文件夹',
                      onTap: () => _closeAnd(context, onAddFolder),
                    ),
                    _MenuRow(
                      icon: Icons.delete_outline,
                      label: '清空播放列表',
                      danger: true,
                      onTap: () => _confirmClear(context),
                    ),
                    _MenuRow(
                      icon: Icons.colorize_outlined,
                      label: '换肤',
                      // 换肤是二级抽屉：先收一级再弹二级（与 LibraryMenu 的
                      // 二级入口同序）—— 两层叠着会让 Esc/遮罩语义变糊。
                      onTap: () => _closeAnd(context, () => _openTheme(context)),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 先收抽屉再执行：选择器弹在抽屉之上、回来时抽屉已经不在，避免叠两层。
  Future<void> _closeAnd(BuildContext context, MenuAction action) {
    _close(context);
    return action();
  }

  /// 打开换肤二级抽屉（M3 T6）：等一级抽屉**真的收完**再弹二级 —— 两级遮罩
  /// 叠着会互相吞 Esc / 遮罩点击。
  ///
  /// 这里不能用固定延时去猜。抽屉收起动画 240ms，`pop` 一结束它的 Element 就
  /// 被拆掉；以前写的是「等 260ms 再用一级抽屉的 context 弹」，只要路由先拆完
  /// （真机稳定帧率下就是这样），计时器回来时 `context.mounted == false`，直接
  /// return —— 用户看到的就是「抽屉收起来了，换肤弹窗没出来」。
  ///
  /// 现在改成两件确定性的事：
  /// 1. 等 `ModalRoute.completed`，也就是这条抽屉路由自己播完收起动画；
  /// 2. 用 `NavigatorState` 的 context 去弹（路由层，抽屉收起后依然在树上，
  ///    且仍在 MultiProvider / Theme 之下，`context.tokens` 与
  ///    `context.watch<ThemeState>()` 都照常可用）。
  Future<void> _openTheme(BuildContext context) async {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route != null) {
      await route.completed;
    }
    final host = navigator.context;
    if (!host.mounted) return;
    showThemeDrawer(host);
  }

  void _close(BuildContext context) {
    Navigator.of(context).maybePop();
  }

  /// 清空是破坏性操作：先问一句，确认了才交给状态层。
  Future<void> _confirmClear(BuildContext context) async {
    final tokens = context.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: scrimColor(tokens),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.sheetA,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusLg),
          side: BorderSide(color: tokens.borderStrong),
        ),
        title: Text(
          '确定清空播放列表吗？',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: tokens.textDim,
              minimumSize: const Size(0, 36),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: tokens.danger,
              foregroundColor: tokens.dangerInk,
              minimumSize: const Size(0, 36),
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    _close(context);
    await onClear();
  }
}

/// 抽屉抬头：只有一个小标题与关闭按钮，不放说明文字。
class _Head extends StatelessWidget {
  const _Head({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '菜单',
              style: TextStyle(fontSize: 13, color: tokens.textFaint),
            ),
          ),
          Semantics(
            button: true,
            label: '关闭菜单',
            excludeSemantics: true,
            onTap: onClose,
            child: InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(999),
              overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.close, size: 14, color: tokens.textDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一级入口行：44px 高、16px 图标、13px 文案，没有副标题。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final MenuAction onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = danger ? tokens.danger : tokens.text;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        overlayColor: WidgetStatePropertyAll<Color>(
          danger ? tokens.dangerSoft : tokens.accentSoft,
        ),
        child: SizedBox(
          height: kTouchTarget,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 13, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
