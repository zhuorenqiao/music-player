// lib/ui/shell.dart
//
// 应用骨架：对译 `src/styles/app.css` 的两档结构（`.app` + `.app__main`）。
//
//   - 宽 ≥900：外层 padding 24/28/28、gap 18，左列 `minmax(0, 1.02fr)` 放
//     曲目区与控制区（控制条贴在这一列的底边），右列 `minmax(0, 1fr)` 是面板，
//     两列同顶同底 —— 也就是原版「控制区底边与右栏面板底边对齐」那条视觉验收；
//   - 宽 <900：单列 `stage → panel → transport`，padding 16/14/14、gap 14，
//     控制条吸在视口最底（原版里它是 `position: sticky; bottom: 0`）。
//
// 两档共用一条宽度上限：`.app { max-width: 1180px; margin: 0 auto }`。封顶加在
// padding **里面**，边距量的是窗口而不是内容框 —— 1920 的窗口里内容 1180 居中，
// 1200 的窗口里内容仍占满 1200-56 且 24/28/28 的边距不变。
//
// **只管摆放，不碰业务**：四个区域由调用方传入，后续任务只换子 widget，
// 这个文件的结构不再改。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';

/// 内容最大宽度：`.app { max-width: 1180px }`（配合 `margin: 0 auto` 居中）。
const double kMaxContentWidth = 1180;

/// 桌面外层边距：`padding: 24px 28px 28px`。
const EdgeInsets kDesktopPadding = EdgeInsets.fromLTRB(28, 24, 28, 28);

/// 窄屏外层边距：`padding: 16px 14px 14px`。
///
/// 底边是 0 而不是 14：原版控制条 `position: sticky; bottom: 0`，它自己带
/// `padding: 14px 16px calc(12px + env(safe-area-inset-bottom))`，外层再留
/// 14px 会把吸底的那条顶离视口底边 14px（test/ui/shell_test.dart 量得到）。
const EdgeInsets kNarrowPadding = EdgeInsets.fromLTRB(14, 16, 14, 0);

/// 桌面：左列（曲目区 + 控制区）、右列（面板），两列同高。
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    super.key,
  });

  final Widget header;
  final Widget stage;
  final Widget panel;
  final Widget transport;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = isDesktop(constraints.maxWidth);
        return SafeArea(
          child: Padding(
            padding: desktop ? kDesktopPadding : kNarrowPadding,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: desktop ? 18 : 14),
                    if (desktop)
                      Expanded(
                        child: Row(
                          key: const Key('desktop-grid'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              // minmax(0, 1.02fr) / minmax(0, 1fr) 按 102 : 100 取整
                              flex: 102,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: stage),
                                  const SizedBox(height: 18),
                                  transport,
                                ],
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(flex: 100, child: panel),
                          ],
                        ),
                      )
                    else ...[
                      stage,
                      const SizedBox(height: 14),
                      Expanded(child: panel),
                      const SizedBox(height: 14),
                      transport,
                    ],
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
