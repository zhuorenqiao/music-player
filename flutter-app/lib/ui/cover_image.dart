// lib/ui/cover_image.dart
//
// 统一封面显示件（M2b T10）：对译 React `useCover` 的显示侧 —— resolver
// 给出「当前该显示的封面」，本件负责把它画出来：
//
//   * path 非空 → `Image.file`（缓存目录里的落盘文件，可能是内嵌封面也可能
//     是在线匹配结果）；
//   * path 为空 **或文件已不在**（缓存目录可能被清）→ 生成卡
//     [GeneratedCoverView]（离线、确定性、同歌手恒同图）。
//
// 契约：路径失效不抛、退生成卡 —— vinyl_deck.dart:41 的同步判存先例
//（`existsSync` 让占位首帧就位、不闪加载态）在这里同样适用。
//
// 方图；圆裁由调用方决定（[CoverDisc] 内裁，行内缩略图自带 ClipOval）。
import 'dart:io';

import 'package:flutter/material.dart';

import '../cover/generated_cover.dart';
import 'generated_cover_view.dart';

class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.path,
    required this.artist,
    required this.title,
    required this.size,
    super.key,
  });

  /// 内嵌 / 在线匹配的落盘路径；'' = 生成卡。
  final String path;
  final String artist;
  final String title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasFile = path.isNotEmpty && File(path).existsSync();
    if (hasFile) {
      return Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 切图时保留上一帧，避免封面闪成白块。
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => GeneratedCoverView(
          spec: generatedCoverSpec(artist, title),
          size: size,
        ),
      );
    }
    return GeneratedCoverView(
      spec: generatedCoverSpec(artist, title),
      size: size,
    );
  }
}
