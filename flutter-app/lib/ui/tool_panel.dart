// lib/ui/tool_panel.dart
//
// 三颗工具按钮（歌词高亮色 / 卡面毛玻璃 / 睡眠定时器）的弹层落位。
//
// 简约模式（封面页）：按钮在控制条上方那排的左端，弹层**向上**弹 ——
// 下面就是进度条，没有地方放。
// 沉浸模式（完整歌词页）：整组挪到歌词页右上角（歌名右边、波形样式下拉
// 左边那一格），弹层改为**向下**弹 —— 上面是屏幕顶，向上弹会出界。
//
// 横向：面板比按钮宽得多（176~224px），落位要夹在视口内，
// 否则窄屏上会有一半露在屏幕外。
//
// **本文件刻意不 import 任何按钮组件**：三颗按钮要 import 这里拿
// [ToolPanelSide] 与 [toolPanelPosition]，反过来再 import 就成环了。
// 成组的那颗 [ToolButtons] 在 `tool_buttons.dart`。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 触发按钮的正方形边长（三处 CSS 都是 `26px`）。
const double kToolTriggerSize = 26;

/// 三颗触发按钮的统一外观：`26×26`、圆角 8、1px 描边、居中。
///
/// 这套值在原版 CSS 里被**逐字写了三遍**（`src/styles/app.css` 的
/// `.lyric-color__trigger:2502-2522`、`.glass-control__trigger:2770-2785`、
/// `.sleep-timer__trigger:2919-2937`），内容完全一致：
/// `width/height: 26px; padding: 0; border: 1px solid var(--border-strong);
/// border-radius: 8px; background: var(--surface); display: inline-flex;
/// align-items: center; justify-content: center`。
/// 展开态（`[aria-expanded="true"]`）三处也都是
/// `border-color: var(--accent-line); background: var(--accent-soft)`。
///
/// 之前 Flutter 侧只有「T」和闹钟自己拼了这套壳、水滴是一颗裸图标，
/// 闹钟还把图标怼在左边缘 —— 三颗并排就一眼看出不齐。统一收到这里。
class ToolTriggerChrome extends StatelessWidget {
  const ToolTriggerChrome({
    required this.active,
    required this.child,
    this.width = kToolTriggerSize,
    this.padding = EdgeInsets.zero,
    this.danger = false,
    super.key,
  });

  /// 展开中（或睡眠定时器运行中）：accent 描边 + accent 软底。
  final bool active;

  /// 运行中的睡眠定时器进入最后一分钟（CSS 的 `is-ending`）：同一套壳换 danger 色。
  final bool danger;

  /// 图标 / 文字。
  final Widget child;

  /// 定宽；睡眠定时器运行中要撑成「药丸」（CSS 的 `width: auto`），此时传 null。
  final double? width;

  /// 药丸态的左右内边距（CSS 的 `padding: 0 8px`），默认 0。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: width,
      height: kToolTriggerSize,
      padding: padding,
      // 居中交给容器自己：三个按钮里的图标/文字都在这 26×26 的正中间。
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? (danger ? tokens.dangerSoft : tokens.accentSoft)
            : tokens.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? (danger ? tokens.dangerLine : tokens.accentLine)
              : tokens.borderStrong,
        ),
      ),
      child: child,
    );
  }
}

/// 弹层相对触发按钮的展开方向。
enum ToolPanelSide {
  /// 向上展开（控制条上那排）。
  above,

  /// 向下展开（歌词页右上角）。
  below,
}

/// 弹层的落位（交给 Overlay 里的 [Positioned]）。
class ToolPanelPosition {
  const ToolPanelPosition({required this.left, this.top, this.bottom});

  /// 左缘（视口坐标）。
  final double left;

  /// 上缘（视口坐标）；向下展开时有值。
  final double? top;

  /// 下缘（视口坐标）；向上展开时有值。
  final double? bottom;
}

/// 算弹层落位。
///
/// [anchor] 是触发按钮的视口左上角，[anchorWidth]/[anchorHeight] 是按钮尺寸。
///
/// - [above]：贴着按钮**上缘**往上 8px，水平沿用各按钮自己的偏置
///   （[leftBias]：色板 0、水滴与闹钟 -40）。
/// - [below]：贴着按钮**下缘**往下 8px。水平以按钮中心对齐（[alignRight] 则贴
///   按钮右缘），再夹进视口（左右各留 8px）。
///
/// 夹视口是 React 版没有的一步：CSS 里面板超出屏幕就是超出屏幕，而 Flutter
/// 的 Overlay 会直接画到屏幕外 —— 那边至少还有半张面板看得见。
ToolPanelPosition toolPanelPosition({
  required Offset anchor,
  required double anchorWidth,
  required double anchorHeight,
  required double panelWidth,
  required Size viewport,
  required ToolPanelSide side,
  double leftBias = 0,
  bool alignRight = false,
}) {
  if (side == ToolPanelSide.above) {
    return ToolPanelPosition(
      left: math.max(8, anchor.dx + leftBias),
      bottom: viewport.height - anchor.dy + 8,
    );
  }
  final double wanted = alignRight
      ? anchor.dx + anchorWidth - panelWidth
      : anchor.dx + anchorWidth / 2 - panelWidth / 2;
  // 夹进视口：太窄时优先保住左缘（面板右边超出屏幕也比左边超出好认）。
  final double maxLeft = math.max(8, viewport.width - panelWidth - 8);
  return ToolPanelPosition(
    left: wanted < 8 ? 8 : (wanted > maxLeft ? maxLeft : wanted),
    top: anchor.dy + anchorHeight + 8,
  );
}
