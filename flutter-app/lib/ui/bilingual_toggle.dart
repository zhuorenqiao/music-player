// lib/ui/bilingual_toggle.dart
//
// 非中文歌词的「双语」胶囊开关：对译 `src/components/BilingualToggle.tsx` 整个组件
// 与 `src/styles/app.css` 的 `.lyrics-bilingual` 一族（:3094-3133，含 `:root[data-mode="light"]`
// 两档）。播放卡与歌词页两处共用一个规格（原版注释：两处都是 26px 高）。
//
// 规格逐字（spec §13）：高 26、字号 11.5、图标 12×12、左右内边距 9、图文间距 3、
// 圆角 999（`--radius-pill`）。
//   开 = accentLight 文字 + accentLine 描边 + accentSoft 底；
//   关 = textDim 文字 + progressTrack 描边 + tint1 底。
// 颜色一律走 `context.tokens`，本文件不出现颜色字面量（ui/ 内的规矩）。
//
// 本组件是**纯展示**的：不吃 `BilingualState`，只吃 [enabled] / [onChanged] / [tooltip]。
// 「只在非中文歌词时出现」由调用方判（原版组件里那句 `if (!translatable) return null`），
// 四档 tooltip 文案也在调用方组合 —— 这样 widget 能脱离状态层独立测（T16 的设计）。
//
// 图标是三条描边路径，原版是内联 SVG（viewBox 24、stroke 1.9、圆头圆角）。工程里没有
// flutter_svg，也不许为它加依赖，所以用 [CustomPainter] 按 0.5 倍缩放到 12×12 描边。
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 开关的固定外框高度（CSS `min-height: 26px`，:3097）。
const double _kToggleHeight = 26;

/// 左右内边距（CSS `padding: 0 9px`，:3098）。
const double _kToggleHorizontalPadding = 9;

/// 图文间距（CSS `gap: 3px`，:3096）。
const double _kToggleGap = 3;

/// 图标边长（CSS `.lyrics-bilingual .icon { width/height: 12px }`，:3112-3114）。
const double _kGlyphSize = 12;

/// 文字规格：`font-size: 11.5px`（:3099）与圆角 `--radius-pill: 999px`（:108）。
const double _kFontSize = 11.5;
const double _kPillRadius = 999;

/// 「双语」胶囊开关。[enabled] 为真时是强调色那一档。
///
/// [tooltip] 进无障碍 hint（不是 [Tooltip] 气泡）：原版把四档说明写在 `title`
/// 里当读屏提示，鼠标悬停的气泡反而不是重点。空串表示没有额外说明。
///
/// ⚠️ **调用方必须自己判 `translatable`**。本组件是纯展示的，**永远不会
/// return null**：给它一个位置就一定会画出来。原版组件里那句
/// `if (!translatable) return null`（`src/components/BilingualToggle.tsx`）
/// 在 Flutter 侧要由调用方写成
/// `bilingual.translatable ? BilingualToggle(...) : null`，否则中文歌也会
/// 常驻一个毫无用处的开关。T18 的 `Stage` 与 T19 的 `LyricsPage` 都要照此写
/// （`BilingualState.translatable` 是 `_lyrics.translatable` 的直接转发，
/// 不要在这里重算）。T16 的 brief 没有明确要求这条门禁，特此钉住。
class BilingualToggle extends StatelessWidget {
  const BilingualToggle({
    required this.enabled,
    required this.onChanged,
    this.tooltip = '',
    super.key,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// 读屏 hint；空串表示不给。
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = enabled ? tokens.accentLight : tokens.textDim;
    return Semantics(
      button: true,
      toggled: enabled,
      label: '双语',
      // 空 tooltip 不要给 hint: ''：读屏会把它念成一句空话，语义树里也多一条无意义属性。
      hint: tooltip.isEmpty ? null : tooltip,
      // 子树的语义已经全在上面这一层（文字「双语」不该再被单独念一遍）。
      excludeSemantics: true,
      onTap: () => onChanged(!enabled),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!enabled),
        child: Container(
          key: const Key('bilingual-toggle'),
          height: _kToggleHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: _kToggleHorizontalPadding,
          ),
          decoration: BoxDecoration(
            color: enabled ? tokens.accentSoft : tokens.tint1,
            borderRadius: BorderRadius.circular(_kPillRadius),
            border: Border.all(
              color: enabled ? tokens.accentLine : tokens.progressTrack,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const Key('bilingual-glyph'),
                width: _kGlyphSize,
                height: _kGlyphSize,
                child: CustomPaint(painter: _TranslateGlyph(color)),
              ),
              const SizedBox(width: _kToggleGap),
              Text(
                '双语',
                style: TextStyle(fontSize: _kFontSize, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「文 A」翻译图标：三条描边路径（逐字对译原版内联 SVG 的三段 `d`）。
///
/// 原点在 24×24 的 viewBox 里，按 `size.width / 24` 缩放到实际边长（12 → 0.5 倍），
/// 所以描边视觉粗细是 `1.9 × 0.5 = 0.95px`，与原版 CSS 缩放后的观感一致。
class _TranslateGlyph extends CustomPainter {
  const _TranslateGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(scale);
    final path = Path()
      // 中文「文」的示意：一横 + 一竖 + 一个撇捺合成的弧
      ..moveTo(3.5, 6.5)
      ..lineTo(10.5, 6.5)
      ..moveTo(6.8, 4.6)
      ..lineTo(6.8, 6.5)
      ..moveTo(8.6, 6.5)
      ..cubicTo(8.1, 9.9, 6.2, 12.5, 3.5, 13.9)
      // 下方交叉：两条斜线
      ..moveTo(6.2, 11.2)
      ..lineTo(8.5, 14.7)
      ..moveTo(10.2, 11.2)
      ..lineTo(7.9, 14.7)
      // 英文「A」：两条斜边 + 一横
      ..moveTo(13.4, 19.4)
      ..lineTo(16.7, 11.4)
      ..lineTo(20.0, 19.4)
      ..moveTo(14.6, 16.6)
      ..lineTo(18.8, 16.6);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TranslateGlyph oldDelegate) =>
      oldDelegate.color != color;
}
