// lib/ui/empty_state.dart
//
// 页面级空态：对译 `src/styles/app.css` 的 `.panel__empty` 一族（:1623-1650）。
//
// 两条硬约束：
//   1. 只用两行文字（标题 13.5/w600 + 说明 12），不加虚线框、不加图标 ——
//      原版注释写明「它只是说明不是可投放区域」，虚线框会把它画成拖放目标；
//   2. 在内容区正中：由父级给满整块空间，这里只负责居中，不自己量高度。
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 空态提示。[title] 是主句，[hint] 是次要说明。
class EmptyState extends StatelessWidget {
  const EmptyState({required this.title, required this.hint, super.key});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: tokens.textDim,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: tokens.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}
