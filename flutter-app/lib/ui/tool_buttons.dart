// lib/ui/tool_buttons.dart
//
// 三颗工具按钮成组：对译 React `src/App.tsx:997-1005` 的 `ToolButtons`。
//
//   ┌──────────────────────────────┐
//   │ T │ 💧 │ ⏰                  │  ← 26px 小按钮，间隔 8px
//   └──────────────────────────────┘
//
// 简约与沉浸模式都排在控制条里、音谱条上方，弹层统一**向上**弹。
// [ToolPanelSide] 仍供电台 / 休眠页复用，页面可以按需指定方向。
import 'package:flutter/material.dart';

import 'glass_control.dart';
import 'lyric_color_button.dart';
import 'sleep_timer_button.dart';
import 'tool_panel.dart';

/// 三颗工具按钮成组。
class ToolButtons extends StatelessWidget {
  const ToolButtons({super.key, this.side = ToolPanelSide.above});

  /// 弹层展开方向。
  final ToolPanelSide side;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LyricColorButton(side: side),
        const SizedBox(width: 8),
        GlassControl(side: side),
        const SizedBox(width: 8),
        SleepTimerButton(side: side),
      ],
    );
  }
}
