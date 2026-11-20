// lib/ui/drawer_shell.dart
//
// 右侧抽屉的外壳（抬头 + 面板），与 Web 端 `src/components/Drawer.tsx` 逐条对齐。
// 一级「更多」菜单（drawer_menu.dart）与二级「换肤」（theme_drawer.dart）共用。
//
// ---- 对译的 CSS 事实（app.css:3204-3337）----
//   · `.drawer__panel`：`width: min(<档位>px, 88vw)`、`max-width: calc(100% - 24px)`、
//     `max-height: calc(100% - 24px)`、`margin: 12px 12px 12px 0`、1px `--border-strong`、
//     `--radius-xl`、`--shadow-pop`；
//     背景两层（后写的在下）：
//       `radial-gradient(120% 58% at 100% 0%, rgb(var(--accent-rgb) / .1), transparent 62%)`
//       叠在 `linear-gradient(180deg, var(--panel-a), var(--panel-b))` 之上。
//   · `.drawer__head`：`padding: 20px 16px 12px`、`gap: 12px`、垂直居中；
//     标题 16px / 650 / `--text`，前面一颗 6px `--accent` 圆点（`0 0 10px` 光晕）；
//     说明 12px `--text-faint`，`margin: 4px 0 0 14px`（14 = 圆点 6 + gap 8）；
//     关闭钮 32×32 正圆：1px `--border` + `--tint-1` 底，图标 16px `--text-dim`。
//   · `.drawer__body`：`padding: 4px 12px 16px`、`gap: 8px`。
//
// 之前 Flutter 端自己拼了一套：抬头是小号浅字（13px `--text-faint`）、没有点题圆点
// 也没有说明行、关闭钮是 36/28px 的裸图标、面板底色用 `--sheet-a/b` 且没有主题色晕、
// 投影用了 `--shadow-card` —— 与 Web 一眼就能看出不是同一张卡。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 面板外边距：CSS `margin: 12px` / `max-width: calc(100% - 24px)`。
const double kDrawerMargin = 12;

/// 抽屉外壳：底色 + 主题色晕 + 1px 强描边 + `--shadow-pop` 投影，内含抬头与内容。
///
/// 尺寸规则与 CSS 同一套：宽度 `min([baseWidth], [viewportFraction] * 视口宽, 视口宽 - 24)`，
/// 高度上限 `视口高 - 24`（内容超出时正文自己滚，面板不撑破屏幕）。
class DrawerPanel extends StatelessWidget {
  const DrawerPanel({
    required this.baseWidth,
    required this.title,
    required this.closeLabel,
    required this.onClose,
    required this.children,
    this.hint,
    this.gap = 0,
    this.viewportFraction = 0.88,
    super.key,
  });

  /// 该档位的基准宽度：换肤 `min(340, 88vw)`，一级菜单 `min(288, 82vw)`。
  final double baseWidth;

  /// 面板宽度占视口的比例（`88vw` / `82vw`）。
  final double viewportFraction;

  /// 抬头标题（`更多` / `换肤`），前面自动加一颗点题圆点。
  final String title;

  /// 标题下的小字说明；null 时不占位（一级菜单就没有）。
  final String? hint;

  /// 关闭钮的读屏名（`关闭菜单` / `关闭换肤`）。
  final String closeLabel;

  final VoidCallback onClose;

  /// 正文（`.drawer__body` 那一块），调用方自己摆行间距。
  final List<Widget> children;

  /// 相邻正文块之间的固定间距（一级菜单对译 `.menu-list { gap: 8px }` 传 8；
  /// 换肤抽屉自己在 children 里夹 SizedBox，保持 0，免得叠成双倍间距）。
  final double gap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final screen = MediaQuery.sizeOf(context);
    final radius = BorderRadius.circular(kRadiusXl);
    final available = math.max(0.0, screen.width - kDrawerMargin * 2);
    final width = math.min(
      baseWidth,
      math.min(screen.width * viewportFraction, available),
    );
    final maxHeight = math.max(0.0, screen.height - kDrawerMargin * 2);

    return Semantics(
      // Web 是 `role="dialog" aria-modal="true" aria-label={title}`。
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          // 外框必须画在内容**之上**：`DecoratedBox` 是「先画 decoration、再画
          // child」，而里面那层 `--panel-a → --panel-b` 渐变面是不透明的，写在
          // decoration 里的这圈 1px `--border-strong` 会被整块盖掉 —— 屏幕上看
          // 到的就是「抽屉面板没有边框」，和 Web 的卡片边差一眼。
          // 改用 `foregroundDecoration`（画在 child 之后）把描边补在最上层。
          child: Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tokens.borderStrong),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: tokens.shadowPop,
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: DecoratedBox(
                  // `linear-gradient(180deg, --panel-a, --panel-b)`
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [tokens.panelA, tokens.panelB],
                    ),
                  ),
                  child: Stack(
                    children: [
                      // 右上角那圈主题色晕（CSS 写在同一份 background 里，压在线性渐变之上）
                      Positioned.fill(
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _PanelGlowPainter(tokens: tokens),
                            ),
                          ),
                        ),
                      ),
                      // CSS 的 width 含描边（border-box）：1px 描边占掉的这一圈要从
                      // 内容里让出来，否则正文会比 Web 宽 2px、左右各少 1px。
                      Padding(
                        padding: const EdgeInsets.all(1),
                        child: Material(
                          type: MaterialType.transparency,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              DrawerHead(
                                title: title,
                                hint: hint,
                                closeLabel: closeLabel,
                                onClose: onClose,
                              ),
                              Flexible(
                                child: SingleChildScrollView(
                                  // `.drawer__body { padding: 4px 12px 16px }`
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    4,
                                    12,
                                    16,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (
                                        var i = 0;
                                        i < children.length;
                                        i++
                                      ) ...[
                                        if (i > 0 && gap > 0)
                                          SizedBox(height: gap),
                                        children[i],
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉抬头：圆点 + 标题 + 说明 + 正圆关闭钮（`.drawer__head`）。
class DrawerHead extends StatelessWidget {
  const DrawerHead({
    required this.title,
    required this.closeLabel,
    required this.onClose,
    this.hint,
    super.key,
  });

  final String title;
  final String? hint;
  final String closeLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // `.drawer__title::before`：6px 强调色圆点 + `0 0 10px` 光晕
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.accent,
                        boxShadow: [
                          BoxShadow(
                            color: tokens.accent.withValues(alpha: 0.85),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.16, // 0.01em × 16px
                          color: tokens.text,
                        ),
                      ),
                    ),
                  ],
                ),
                if (hint != null)
                  Padding(
                    // `margin: 4px 0 0 14px`
                    padding: const EdgeInsets.only(top: 4, left: 14),
                    child: Text(
                      hint!,
                      style: TextStyle(fontSize: 12, color: tokens.textFaint),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            button: true,
            label: closeLabel,
            excludeSemantics: true,
            onTap: onClose,
            child: InkWell(
              onTap: onClose,
              customBorder: const CircleBorder(),
              overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tokens.tint1,
                  border: Border.all(color: tokens.border),
                ),
                child: Icon(Icons.close, size: 16, color: tokens.textDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板右上角的主题色晕：
/// `radial-gradient(120% 58% at 100% 0%, rgb(var(--accent-rgb) / 0.1), transparent 62%)`。
///
/// CSS 的 `120% 58%` 是**椭圆**半径（rx = 1.2×宽、ry = 0.58×高），圆心贴右上角；
/// Flutter 的 radial 只有圆，所以先按 ry/rx 压扁画布再画圆。
class _PanelGlowPainter extends CustomPainter {
  const _PanelGlowPainter({required this.tokens});

  final AppTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rx = size.width * 1.2; // 120% 宽
    final ry = size.height * 0.58; // 58% 高
    if (rx <= 0 || ry <= 0) return;
    final color = tokens.accent.withValues(alpha: 0.1);
    canvas.save();
    canvas.translate(size.width, 0); // 圆心在 100% 0%
    canvas.scale(1, ry / rx);
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: rx * 2, height: rx * 2),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          rx,
          [color, color.withValues(alpha: 0)],
          [0, 0.62],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PanelGlowPainter oldDelegate) =>
      oldDelegate.tokens != tokens;
}
