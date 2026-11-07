// lib/ui/recent_row.dart
//
// 最近播放行：对译 `src/App.tsx:786-824` 与 `src/styles/app.css` 的 `.recent`
// 一族（:3312-3461）。
//
//   ┌───────────────────────────────────────────────┐
//   │ [40 封面] 曲名                04:12           │
//   │           歌手  3 分钟前  已不在列表           │
//   └───────────────────────────────────────────────┘
//
// 两条硬约束：
//   1. 曲目被删掉之后条目仍在：整行降到 0.55 不透明度，meta 行给「已不在列表」
//      的显式提示，语义标签也改写成 `标题（已不在播放列表中）`，
//      点下去由面板负责提示 —— 不许静默失败；
//   2. 颜色只取 token 表；当前行与非当前行都占住 1px 描边，切换时不横移。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'cover_thumb.dart';

/// 一行最近播放。纯 props：相对时间由调用方用 `formatRelativeTime` 算好再传，
/// 行内不取时钟（也就不用定时重建）。
class RecentRow extends StatelessWidget {
  const RecentRow({
    required this.title,
    required this.artist,
    required this.relativeTime,
    required this.duration,
    required this.inPlaylist,
    required this.active,
    required this.onTap,
    this.coverPath = '',
    super.key,
  });

  /// 曲名（一行省略号）。
  final String title;

  /// 歌手（一行省略号，可空）。
  final String artist;

  /// 相对播放时间，如 `3 分钟前`。
  final String relativeTime;

  /// 时长文案，已格式化（未知时 `--:--`）。
  final String duration;

  /// 是否还在播放列表里；false 时整行变暗并提示。
  final bool inPlaylist;

  /// 是否是当前曲目。
  final bool active;

  final VoidCallback onTap;

  /// 封面文件绝对路径；空串表示没有封面。
  final String coverPath;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: inPlaylist ? title : '$title（已不在播放列表中）',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusLg),
        child: AnimatedOpacity(
          opacity: inPlaylist ? 1 : 0.55,
          duration: const Duration(milliseconds: 180),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusLg),
              // 非当前行用零透明度的 accentLine 占位：宽度恒为 1px
              border: Border.all(
                color: active
                    ? tokens.accentLine
                    : tokens.accentLine.withValues(alpha: 0),
              ),
              gradient: active
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: <Color>[
                        tokens.accentSoft,
                        tokens.accentSoft.withValues(alpha: 0.02),
                      ],
                    )
                  : null,
            ),
            child: Row(
              children: [
                CoverThumb(path: coverPath, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: active ? tokens.accentLight : tokens.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: tokens.textFaint,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            relativeTime,
                            style: TextStyle(
                              fontSize: 11,
                              color: tokens.textFaint,
                            ),
                          ),
                          if (!inPlaylist) ...[
                            const SizedBox(width: 6),
                            Text(
                              '已不在列表',
                              style: TextStyle(
                                fontSize: 11,
                                color: tokens.dangerInk,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  duration,
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.textFaint,
                    // 等宽数字：时长列不抖
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
