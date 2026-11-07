// lib/ui/vinyl_deck.dart
//
// 圆碟封面：把封面裁成正圆，垫一圈暗色「盘面」。
//
// 对译 `src/styles/app.css` 的 `.stage__cover-wrap` / `.stage__vinyl` /
// `.stage__cover`（README「黑胶」段落）：M1 只做静态碟 —— 转录纹路、斜向反光
// 与唱臂在 M3 一起做，旋转角度也由 M3 的动画驱动，所以 [CoverDisc.spinning]
// 现在恒为 false，字段先留着，M3 换实现不改签名。
//
// 封面一律走 `Image.file`：指向缓存目录里的封面文件（见 metadata 层的
// `cover_image.dart`）。文件不存在 / 读不出来都退回占位碟，**绝不空着**，
// 测试也因此不需要任何真实图片。
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class CoverDisc extends StatelessWidget {
  const CoverDisc({
    required this.coverPath,
    required this.size,
    required this.spinning,
    super.key,
  });

  /// 封面文件的绝对路径；空串表示没有封面。
  final String coverPath;

  /// 圆碟直径（`kCoverSize` 的三档结果）。
  final double size;

  /// 是否在转。M1 恒 false（M3 接旋转动画）。
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 先同步看一眼文件在不在：封面在缓存目录里，可能被清掉。走 `Image.errorBuilder`
    // 也能兜住，但要多等一帧 IO，首帧会闪一下加载态；同步判定让占位碟立刻到位。
    final hasFile = coverPath.isNotEmpty && File(coverPath).existsSync();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 盘面：外圈压暗、中心略亮，封面盖上去之后只在边缘露一细圈
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [tokens.panelA, tokens.bg],
                stops: const [0.55, 1],
              ),
              boxShadow: tokens.shadowCard,
            ),
            child: SizedBox(width: size, height: size),
          ),
          ClipOval(
            child: SizedBox(
              width: size,
              height: size,
              child: hasFile
                  ? Image.file(
                      File(coverPath),
                      fit: BoxFit.cover,
                      // 切歌时保留上一帧，避免封面闪成白块
                      gaplessPlayback: true,
                      errorBuilder: (imageContext, error, stack) =>
                          const _DiscPlaceholder(),
                    )
                  : const _DiscPlaceholder(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 没有封面时的占位碟：与盘面同形的暗底 + 一个音符。
///
/// key 给测试与 M3 的骨架微光用：封面就绪与否是可见的状态差异，不该静默。
class _DiscPlaceholder extends StatelessWidget {
  const _DiscPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ColoredBox(
      key: const Key('cover-placeholder'),
      color: tokens.progressTrack,
      child: Center(
        child: Icon(Icons.music_note, size: 28, color: tokens.textFaint),
      ),
    );
  }
}
