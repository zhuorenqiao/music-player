// lib/ui/drawer_menu.dart
//
// 一级抽屉菜单：只有三个一级入口 —— 添加音乐 / 添加整个文件夹 / 清空播放列表。
// 平铺 44px 行、16px 图标 + 13px 文案，不带任何说明文字；换肤属 M3，这里不出现。
//
// 只画内容，不负责打开：遮罩、滑入动画与「先收抽屉再执行」的时序在
// `header.dart` 的 `AppHeader` 里。三个回调都由调用方注入，测试不碰 file_picker。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 抽屉里的一个入口动作。
typedef MenuAction = Future<void> Function();

/// 遮罩色：CSS `--scrim: rgba(4, 8, 12, 0.66)`。
///
/// 用页面底色加透明度派生，`ui/` 里不写颜色字面量；M3 换主题时跟着底色走。
Color scrimColor(AppTokens tokens) => tokens.bg.withValues(alpha: 0.66);

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
