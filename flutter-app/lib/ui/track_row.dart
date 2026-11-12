// lib/ui/track_row.dart
//
// 播放列表行：对译 `src/App.tsx:726-770` 与 `src/styles/app.css` 的 `.track` 一族
// （:3463-3599）。
//
//   ┌───────────────────────────────────────────────┐
//   │ [44 封面] 曲名  损坏  ……  03:46  [×44/34]     │
//   │           歌手 · 专辑        ▮▮▮（当前项音柱） │
//   └───────────────────────────────────────────────┘
//
// 四条硬约束：
//   1. 整行就是播放热区，删除按钮却在它里面 —— 删除必须吃掉自己那一下点击，
//      不能冒泡成「播放」（用例 `删除按钮点击不冒泡到播放` 钉住）；
//   2. 删除按钮视觉 34×34、热区 44×44（桌面行窄，不缩小图标而是放大热区）；
//   3. 当前行：`accentLine` 1px 描边 + 左→右 `accentSoft` 渐变；非当前行也要
//      占住这 1px，否则切歌时行内容会横移；
//   4. 颜色只取 token 表；这里不出现任何表外色值。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'cover_thumb.dart';

/// 一行曲目。纯 props，不碰状态层 —— 播放列表面板（T28）负责把
/// `Track` / `index` 映射成这些字段。
class TrackRow extends StatelessWidget {
  const TrackRow({
    required this.title,
    required this.artistLine,
    required this.duration,
    required this.active,
    required this.playing,
    required this.broken,
    required this.onPlay,
    required this.onRemove,
    this.coverPath = '',
    this.coverArtist = '',
    this.coverTitle = '',
    super.key,
  });

  /// 曲名（一行省略号）。
  final String title;

  /// 副行文案，原版是 `歌手 · 专辑`（缺哪个就少哪段）；调用方拼好再传。
  final String artistLine;

  /// 时长文案，已格式化（未知时 `--:--`）。
  final String duration;

  /// 是否是当前曲目。
  final bool active;

  /// 当前曲目是否正在播放：只影响音柱动不动。
  final bool playing;

  /// 加载失败（`损坏` 角标）。
  final bool broken;

  final VoidCallback onPlay;
  final VoidCallback onRemove;

  /// 封面文件绝对路径；空串表示没有封面。
  final String coverPath;

  /// 生成卡派生字段（M2b T10）：无内嵌/在线封面时缩略图画生成卡。
  final String coverArtist;
  final String coverTitle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 语义结构照抄原版 DOM：`<li>` 里是「播放」主按钮 + 独立的「移除」按钮。
    // 所以播放的那块语义只包住主内容（封面 / 曲名 / 时长），移除按钮是它的
    // 兄弟 —— 两个标签各自成一个节点，互不吞并。
    return InkWell(
      onTap: onPlay,
      borderRadius: BorderRadius.circular(kRadiusLg),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
          // 非当前行用零透明度的 accentLine 占位：宽度恒为 1px，切歌不横移
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
            Expanded(
              child: Semantics(
                button: true,
                label: '播放《$title》',
                excludeSemantics: true,
                onTap: onPlay,
                child: Row(
                  children: [
                    CoverThumb(
                      key: const Key('track-thumb'),
                      path: coverPath,
                      size: kTrackThumb,
                      fallbackArtist: coverArtist,
                      fallbackTitle: coverTitle,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: active
                                        ? tokens.accentLight
                                        : tokens.text,
                                  ),
                                ),
                              ),
                              if (broken)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: _BrokenBadge(tokens: tokens),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  artistLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: tokens.textFaint,
                                  ),
                                ),
                              ),
                              if (active) ...[
                                const SizedBox(width: 6),
                                // 音柱是 1s 循环的常驻动画（60fps 重绘）。
                                // 不加隔离的话，它每帧都会把**整行**标脏，
                                // 而整行和兄弟行共处同一个列表图层 —— 结果是
                                // 为了 12×13px 的三根小条，把整屏列表跟着重
                                // 光栅化。隔离后只有这一小块自画。
                                RepaintBoundary(
                                  child: BarsIndicator(playing: playing),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      duration,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: tokens.textDim,
                        // 等宽数字：时长列不抖
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: '从播放列表移除《$title》',
              excludeSemantics: true,
              onTap: onRemove,
              child: _RemoveButton(onTap: onRemove),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「损坏」角标：10px 字，`dangerSoft` 底 + `dangerLine` 描边，6 圆角。
class _BrokenBadge extends StatelessWidget {
  const _BrokenBadge({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.dangerSoft,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tokens.dangerLine),
      ),
      child: Text(
        '损坏',
        style: TextStyle(fontSize: 10, color: tokens.dangerInk),
      ),
    );
  }
}

/// 删除按钮：视觉 34×34 圆角 10，热区 44×44。
///
/// 用 `GestureDetector(behavior: opaque)` 而不是再套一层 InkWell：热区要覆盖
/// 到 44，而视觉只有 34，中间那圈留白也得能点。
class _RemoveButton extends StatefulWidget {
  const _RemoveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Tooltip(
      message: '从播放列表中移除',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (event) => setState(() => _hovering = true),
        onExit: (event) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            key: const Key('track-remove'),
            width: kTouchTarget,
            height: kTouchTarget,
            child: Center(
              child: AnimatedContainer(
                key: const Key('track-remove-visual'),
                duration: const Duration(milliseconds: 140),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  // 未悬停时不着色（null 即不画），悬停才铺 dangerSoft
                  color: _hovering ? tokens.dangerSoft : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: _hovering ? tokens.danger : tokens.textFaint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
