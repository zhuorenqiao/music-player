// lib/ui/theme_drawer.dart
//
// 换肤二级抽屉（M3 T6）：对译 React `src/components/ThemeDrawer.tsx`。
//
//   ┌──────────────────────┐
//   │ 换肤            [×]  │
//   │ 明暗模式             │
//   │ [系统][浅色][深色]   │  ← 三段选择（aria-pressed = 选中态描边）
//   │ 当前跟随系统：深色   │  ← 仅 mode==system 时出现（role=status）
//   │ 主题色               │
//   │ [●薄荷][●粉色][●蓝色]│  ← 三 swatch，选中即时生效、抽屉不关可来回比对
//   └──────────────────────┘
//
// 宿主复用 header.dart 的 showGeneralDialog（右缘滑入 + 遮罩 + Esc），由
// DrawerMenu 的一级入口「换肤」打开（LibraryMenu.tsx:104 的二级入口对译）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';
import 'drawer_menu.dart' show scrimColor;

/// 换肤抽屉本体。宽度取 `min(312, 可用宽)`（React 的 default 档 288 加一点
/// 给三段按钮的呼吸感）。
class ThemeDrawer extends StatelessWidget {
  const ThemeDrawer({super.key});

  static const double width = 312;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    final radius = BorderRadius.circular(kRadiusXl);
    return LayoutBuilder(
      builder: (context, constraints) {
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
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Head(onClose: () => Navigator.of(context).maybePop()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _GroupTitle('明暗模式'),
                          const SizedBox(height: 8),
                          _ModeSegment(state: state),
                          if (state.mode == ThemeModeSetting.system) ...[
                            const SizedBox(height: 8),
                            // role=status 的提示行（ThemeDrawer.tsx:35 逐字）。
                            Text(
                              '当前跟随系统：${state.resolvedMode == 'dark' ? '深色' : '浅色'}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: tokens.textFaint,
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          const _GroupTitle('主题色'),
                          const SizedBox(height: 8),
                          const _ColorSwatches(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 段落标题（`.theme-group__title`）。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: tokens.textFaint),
    );
  }
}

/// 明暗三段选择（`.theme-seg`）：系统 / 浅色 / 深色，选中即时生效。
class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.state});

  final ThemeState state;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    Widget item(ThemeModeSetting mode, String label, String hint) {
      final selected = state.mode == mode;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: '$label（$hint）',
          child: GestureDetector(
            onTap: () => state.setMode(mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kRadiusMd),
                border: Border.all(
                  color: selected ? tokens.accentLine : tokens.border,
                ),
                color: selected ? tokens.accentSoft : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? tokens.accentLight : tokens.textDim,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        item(ThemeModeSetting.system, '系统', '跟随系统的浅色 / 深色'),
        const SizedBox(width: 6),
        item(ThemeModeSetting.light, '浅色', '浅色纸面 + 柔和阴影分层'),
        const SizedBox(width: 6),
        item(ThemeModeSetting.dark, '深色', '深色底 + 高光'),
      ],
    );
  }
}

/// 主题色三 swatch（`.theme-swatch`）：点一下即时生效，抽屉不关可来回比对。
class _ColorSwatches extends StatelessWidget {
  const _ColorSwatches();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    Widget swatch(ThemeColorSetting color, String label, Color dot) {
      final selected = state.color == color;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            onTap: () => state.setColor(color),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kRadiusMd),
                border: Border.all(
                  color: selected ? tokens.accentLine : tokens.border,
                ),
                color: selected ? tokens.accentSoft : tokens.tint1,
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      border: Border.all(color: tokens.borderStrong),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? tokens.accentLight : tokens.textDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        swatch(ThemeColorSetting.mint, '薄荷', tokens.accent),
        const SizedBox(width: 6),
        swatch(ThemeColorSetting.pink, '粉色', const Color(0xFFFF6AA8)),
        const SizedBox(width: 6),
        swatch(ThemeColorSetting.blue, '蓝色', const Color(0xFF4D8DFF)),
      ],
    );
  }
}

/// 打开换肤抽屉（DrawerMenu 的「换肤」入口调）。宿主与一级抽屉同一套：
/// 右缘滑入 240ms、遮罩可点、Esc 可关。
void showThemeDrawer(BuildContext context) {
  final tokens = context.tokens;
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭换肤',
    barrierColor: scrimColor(tokens),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Align(
        alignment: Alignment.topRight,
        child: ThemeDrawer(),
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

/// 抽屉抬头：小标题 + 关闭按钮（drawer_menu 的 _Head 同构，标题换成「换肤」）。
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
              '换肤',
              style: TextStyle(fontSize: 13, color: tokens.textFaint),
            ),
          ),
          Semantics(
            button: true,
            label: '关闭换肤',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onClose,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.close, size: 16, color: tokens.textDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
