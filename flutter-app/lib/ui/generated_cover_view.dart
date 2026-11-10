// lib/ui/generated_cover_view.dart
//
// 生成卡的 widget 壳（M2b T1）：把 [GeneratedCoverPainter] 装进 CustomPaint。
//
// 尺寸由父级给（正方形）；颜色与几何全部来自 spec（确定性派生），本壳
// 不持任何状态，也不读 token —— 生成卡的颜色从歌手名派生，不是主题色。
import 'package:flutter/material.dart';

import '../cover/generated_cover.dart';

/// 生成卡视图：`SizedBox` + `CustomPaint`，画 600×600 设计坐标的方图。
class GeneratedCoverView extends StatelessWidget {
  const GeneratedCoverView({required this.spec, required this.size, super.key});

  final GeneratedCoverSpec spec;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: GeneratedCoverPainter(spec),
        size: Size.square(size),
      ),
    );
  }
}
