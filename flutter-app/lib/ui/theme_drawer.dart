// lib/ui/theme_drawer.dart
//
// 换肤二级抽屉（M3 T6）：逐条对译 Web 端 `src/components/ThemeDrawer.tsx`
// + `app.css:3339-3498`（`.theme-group` / `.theme-seg` / `.theme-swatch`）。
//
//   ┌──────────────────────────┐
//   │ ● 换肤             (×)   │  ← `.drawer__head`
//   │   明暗和主题色分开设置…   │  ← `.drawer__hint`（一级菜单那档没有）
//   │ 明暗模式                 │  ← `.theme-group__title`（11.5 / 600 / 0.08em）
//   │ (系统)(浅色)(深色)       │  ← `.theme-seg`：一整颗药丸，选中项铺强调色渐变
//   │ 当前跟随系统：深色        │  ← 仅 mode==system
//   │ 主题色                   │
//   │ ●薄荷   ●粉色   ●蓝色     │  ← `.theme-swatch`：竖排色卡，22px 双圈色点
//   └──────────────────────────┘
//
// 之前 Flutter 端自己拼的版本与 Web 差在三处（一眼就能看出不是同一张卡）：
//   1. 三段选择画成三个独立圆角方块（选中=淡底 + 描边），Web 是一颗药丸容器里
//      浮着一颗**强调色渐变**的选中块、字用 `--accent-ink`（浅色模式换白底 + 亮字）；
//   2. 色卡是横排（12px 圆点 + 右侧文字、40px 高），Web 是竖排（22px 双圈圆点在上、
//      文字在下、padding 12/8/10）；
//   3. 抬头没有说明行、标题是小号浅字（见 drawer_shell.dart 的注释）。
//
// 宿主复用 header.dart 的 showGeneralDialog（右缘滑入 + 遮罩 + Esc），由
// DrawerMenu 的一级入口「换肤」打开。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';
import 'drawer_menu.dart' show menuCardBorder, scrimColor;
import 'drawer_shell.dart';
import 'glass_frost.dart' show cssGradientAxis;

/// 三颗色点的**固定原色**（app.css:3464-3474）：
///
///   ```css
///   .theme-swatch--mint .theme-swatch__dot { background: #2ee6a8; }
///   .theme-swatch--pink .theme-swatch__dot { background: #ff6aa8; }
///   .theme-swatch--blue .theme-swatch__dot { background: #4d8dff; }
///   ```
///
/// CSS 注释写得很直白：**色点固定是该颜色的原色，不跟随当前主题变**。
/// 之前「薄荷」那一颗误用了 `tokens.accent`（= 当前主题的强调色），于是
/// 一切到粉色 / 蓝色，薄荷的圆点也跟着变粉 / 变蓝 —— 用户看到的就是
/// 「薄荷前面的圆点颜色一直在变、颜色不对」。
const Color kSwatchDotMint = Color(0xFF2EE6A8);
const Color kSwatchDotPink = Color(0xFFFF6AA8);
const Color kSwatchDotBlue = Color(0xFF4D8DFF);

/// 换肤抽屉本体。宽度取 `min(340, 88vw)`（Web `.drawer__panel` 内容型那一档）。
class ThemeDrawer extends StatelessWidget {
  const ThemeDrawer({super.key});

  static const double width = 340;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ThemeState>();
    return DrawerPanel(
      baseWidth: width,
      title: '换肤',
      hint: '明暗和主题色分开设置，选择会记住',
      closeLabel: '关闭换肤',
      onClose: () => Navigator.of(context).maybePop(),
      children: [
        const _GroupTitle('明暗模式'),
        const SizedBox(height: 8),
        _ModeSegment(state: state),
        if (state.mode == ThemeModeSetting.system) ...[
          // `.theme-group__hint { margin-top: -2px }` 抵消组内那 8px 的一半
          const SizedBox(height: 6),
          // role=status 的提示行（ThemeDrawer.tsx:35 逐字）。
          _Hint('当前跟随系统：${state.resolvedMode == 'dark' ? '深色' : '浅色'}'),
        ],
        // `.theme-group + .theme-group { margin-top: 6px }` + body 的 8px
        const SizedBox(height: 14),
        const _GroupTitle('主题色'),
        const SizedBox(height: 8),
        const _ColorSwatches(),
      ],
    );
  }
}

/// `.theme-group__title`：11.5px / 600 / `letter-spacing: 0.08em` / `--text-faint`。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.92, // 0.08em × 11.5px
        color: tokens.textFaint,
      ),
    );
  }
}

/// `.theme-group__hint`：11.5px `--text-faint`。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Text(text, style: TextStyle(fontSize: 11.5, color: tokens.textFaint));
  }
}

/// 明暗三段选择（`.theme-seg`）：一整颗药丸容器，里面浮着一颗选中块。
class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.state});

  final ThemeState state;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final light = tokens.brightness == Brightness.light;

    Widget item(ThemeModeSetting mode, String label, String hint) {
      final selected = state.mode == mode;
      // `.theme-seg__item[aria-pressed="true"]`：强调色渐变 + `--accent-ink` 字。
      // 浅色模式覆写成 `--surface-2` 底 + `--accent-light` 字（app.css:3830-3837）。
      final decoration = selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: light
                  ? null
                  : LinearGradient(
                      begin: cssGradientAxis(160).begin,
                      end: cssGradientAxis(160).end,
                      colors: [
                        Color.lerp(Colors.white, tokens.accent, 0.4)!,
                        tokens.accent,
                        Color.lerp(Colors.black, tokens.accent, 0.76)!,
                      ],
                      stops: const [0, 0.6, 1],
                    ),
              color: light ? tokens.surface2 : null,
              boxShadow: [
                light
                    // 0 8px 18px -14px rgba(24, 42, 60, 0.45)
                    ? BoxShadow(
                        color: tokens.shadowPop.first.color.withValues(alpha: 0.45),
                        offset: const Offset(0, 8),
                        blurRadius: 18,
                        spreadRadius: -14,
                      )
                    // 0 8px 18px -12px rgb(var(--accent-rgb) / 0.9)
                    : BoxShadow(
                        color: tokens.accent.withValues(alpha: 0.9),
                        offset: const Offset(0, 8),
                        blurRadius: 18,
                        spreadRadius: -12,
                      ),
              ],
            )
          : const BoxDecoration(borderRadius: BorderRadius.all(Radius.circular(999)));
      final color = selected
          ? (light ? tokens.accentLight : tokens.accentInk)
          : tokens.textDim;

      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: '$label（$hint）',
          child: GestureDetector(
            onTap: () => state.setMode(mode),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              // `min-height: 32px; padding: 0 10px`
              constraints: const BoxConstraints(minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: decoration,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      // `.theme-seg { gap: 2px; padding: 3px; border: 1px solid --border;
      //             border-radius: --radius-pill; background: --tint-1 }`
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tokens.tint1,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: menuCardBorder(tokens)),
      ),
      child: Row(
        children: [
          item(ThemeModeSetting.system, '系统', '跟随系统的浅色 / 深色'),
          const SizedBox(width: 2),
          item(ThemeModeSetting.light, '浅色', '浅色纸面 + 柔和阴影分层'),
          const SizedBox(width: 2),
          item(ThemeModeSetting.dark, '深色', '深色底 + 高光'),
        ],
      ),
    );
  }
}

/// 主题色三 swatch（`.theme-swatch`）：竖排色卡，点一下即时生效，抽屉不关可来回比对。
class _ColorSwatches extends StatelessWidget {
  const _ColorSwatches();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    final light = tokens.brightness == Brightness.light;

    Widget swatch(ThemeColorSetting color, String label, Color dot) {
      final selected = state.color == color;
      // `.theme-swatch[aria-pressed="true"] { color: --text; border-color:
      // --accent-line; background: --accent-soft }`；浅色覆写成
      // `--surface-2` 底 + `--accent-light` 字（app.css:3836-3842）。
      final background = selected
          ? (light ? tokens.surface2 : tokens.accentSoft)
          : tokens.surface;
      final textColor = selected
          ? (light ? tokens.accentLight : tokens.text)
          : tokens.textDim;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            onTap: () => state.setColor(color),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              // `.theme-swatch { gap: 9px; padding: 12px 8px 10px; border-radius: 12px }`
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? tokens.accentLine : menuCardBorder(tokens),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    key: Key('swatch-dot-${color.name}'),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      // `box-shadow: 0 0 0 3px var(--surface), 0 0 0 4px var(--border)`：
                      // 双圈描边，深浅底上都不糊；选中换 accent-soft / accent-line。
                      boxShadow: [
                        BoxShadow(
                          color: selected ? tokens.accentSoft : tokens.surface,
                          spreadRadius: 3,
                        ),
                        BoxShadow(
                          color: selected ? tokens.accentLine : menuCardBorder(tokens),
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: textColor,
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
        // 三颗点都是写死原色，不取 `tokens.accent`（那是「当前」主题色）。
        swatch(ThemeColorSetting.mint, '薄荷', kSwatchDotMint),
        const SizedBox(width: 8),
        swatch(ThemeColorSetting.pink, '粉色', kSwatchDotPink),
        const SizedBox(width: 8),
        swatch(ThemeColorSetting.blue, '蓝色', kSwatchDotBlue),
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
    pageBuilder: (context, animation, secondaryAnimation) => const SafeArea(
      minimum: EdgeInsets.all(kDrawerMargin),
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
