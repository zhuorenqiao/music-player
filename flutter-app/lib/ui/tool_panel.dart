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
