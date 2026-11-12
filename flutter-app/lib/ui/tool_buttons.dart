// lib/ui/tool_buttons.dart
//
// 三颗工具按钮成组：对译 React `src/App.tsx:997-1005` 的 `ToolButtons`。
//
//   ┌──────────────────────────────┐
//   │ T │ 💧 │ ⏰                  │  ← 26px 小按钮，间隔 8px
//   └──────────────────────────────┘
//
// 简约模式（封面页）：排在控制条上方那排的左端，弹层**向上**弹。
// 沉浸模式（完整歌词页）：整组挪到歌词页右上角 —— 歌名右边、波形样式下拉
// 左边那一格，弹层改**向下**弹。
//
// 两处的差别只有弹层方向，由 [ToolPanelSide] 传下去；按钮本身长得一样。
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
