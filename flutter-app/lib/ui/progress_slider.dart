// lib/ui/progress_slider.dart
//
// 进度条：对译 `src/App.tsx:978-1005` 与 `src/styles/app.css` 的 `.progress*`
// 一族（:1116-1226）。
//
//   00:12 ├───────────────●────────────────┤ 03:46
//         rail（整条）→ buffer（已缓冲）→ fill（已播放）+ 圆点
//
// 三层一律 5px 高、3 圆角，从左端同一点起画：`rail` 铺满（`progressTrack`）、
// `buffer` 按已缓冲比例（`borderStrong`）、`fill` 按播放比例（`accent`）；圆点
// 14×14 白底 2px 强调色描边。缓冲层必须在填充层之下、轨道之上，否则缓冲条会
// 盖住进度（原版 `.progress__buffer` 就在 `.progress__fill` 前面一个兄弟）。
//
// 拖拽语义照抄原版的 `scrub`：
//   - 手指按下就进入拖拽态（`onSeekStart`），**期间不跟随播放器进度** ——
//     少了这一步，进度 tick 每秒会把滑块拽回播放位置，跟手指打架；
//   - 拖动按「相对位移」换算：`input[type=range]` 是捏住圆点挪，挪半条就是
//     +50%（原版如此，绝不是「点哪儿就跳哪儿」）；
//   - 松手（`onSeekEnd`）才真正 seek；点击轨道（`onTapUp`）才是按绝对位置跳。
//
// 时长未知（null / NaN / 0）：比例按 0、时间显示 `--:--`、拖与点一律不响应
// （原版给 range 的 `max` 兜了个 0.1，但 `disabled={!current}` 让它点不动）。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/format_time.dart';
import '../theme/app_tokens.dart';

/// 三层轨道的高度：`.progress__rail/buffer/fill { height: 5px }`。
const double _trackHeight = 5;

/// 三层圆角：`border-radius: 3px`。
const double _trackRadius = 3;

/// 拖拽热区高度：`.progress__slider { height: 24px }`（比 5px 的轨道好点中）。
const double _sliderHeight = 24;

/// 圆点直径：`::-webkit-slider-thumb { width/height: 14px }`。
const double _thumbSize = 14;

/// 圆点描边宽度：`border: 2px solid var(--accent)`。
const double _thumbBorder = 2;

/// 两端时间标签宽度：`.progress__time { min-width: 36px }`。
const double _timeLabelWidth = 36;

/// `.progress { gap: 8px }`。
const double _timeGap = 8;

/// 播放进度条：三层轨道 + 圆点 + 两端时间。
class ProgressSlider extends StatefulWidget {
  const ProgressSlider({
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    super.key,
  });

  /// 当前播放位置（秒）。拖拽期间不使用（见 [_ProgressSliderState._shown]）。
  final double position;

  /// 已缓冲到的秒数；内核没报过时为 null（缓冲层按 0 画）。
  final double? buffered;

  /// 总时长（秒）；未知时为 null 或 0。
  final double? duration;

  /// 手指按下 / 拖拽开始：界面据此挂起「跟随播放器进度」。
  final VoidCallback onSeekStart;

  /// 拖拽过程中的目标秒数（只用于画填充，不 seek）。
  final ValueChanged<double> onSeekUpdate;

  /// 松手（或点轨道）时的最终秒数：真正 seek 的时机。
  final ValueChanged<double> onSeekEnd;

  @override
  State<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<ProgressSlider> {
  /// 是否处于拖拽态（原版 `scrub !== null`）。
  bool _dragging = false;

  /// 拖拽起点：按下那一刻的播放位置（秒），整个拖拽期间不变。
  double _dragBase = 0;

  /// 手指累计横向位移（逻辑像素）：拖拽值 = 起点 + 位移换算的秒数。
  double _dragDelta = 0;

  /// 拖拽期间的绘制值。
  double _dragValue = 0;

  /// 总时长；未知 / 非正数一律按 0（不可拖）。
  double get _total {
    final duration = widget.duration;
    if (duration == null || !duration.isFinite || duration <= 0) return 0;
    return duration;
  }

  /// 画出来的位置：拖拽期间用拖拽值，绝不跟播放器抢。
  double get _shown => _dragging ? _dragValue : widget.position;

  double get _ratio => _total <= 0 ? 0 : (_shown / _total).clamp(0.0, 1.0);

  double get _bufferedRatio {
    final buffered = widget.buffered;
    if (_total <= 0 || buffered == null || !buffered.isFinite) return 0;
    return (buffered / _total).clamp(0.0, 1.0);
  }

  /// 拖一点位移对应的秒数增量：按滑轨宽度线性换算。
  double _secondsPerPixel(double trackWidth) =>
      trackWidth <= 0 ? 0 : _total / trackWidth;

  void _beginDrag() {
    if (_total <= 0 || _dragging) return;
    setState(() {
      _dragging = true;
      _dragBase = widget.position;
      _dragDelta = 0;
      _dragValue = widget.position;
    });
    widget.onSeekStart();
  }

  void _updateDrag(double dx, double trackWidth) {
    if (!_dragging || _total <= 0) return;
    _dragDelta += dx;
    final next =
        (_dragBase + _dragDelta * _secondsPerPixel(trackWidth)).clamp(
          0.0,
          _total,
        );
    if (next == _dragValue) return;
    setState(() => _dragValue = next);
    widget.onSeekUpdate(next);
  }

  void _endDrag() {
    if (!_dragging) return;
    final target = _dragValue;
    setState(() => _dragging = false);
    widget.onSeekEnd(target);
  }

  /// 拖拽被别的手势抢走（列表滚动、系统手势）：复位但不 seek，
  /// 与原版 `onBlur={() => setScrub(null)}` 的兜底同一意思。
  void _cancelDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
  }

  void _seekToTapPosition(double localX, double trackWidth) {
    if (_total <= 0 || trackWidth <= 0) return;
    _cancelDrag();
    widget.onSeekEnd((localX / trackWidth).clamp(0.0, 1.0) * _total);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final shown = formatTime(_shown);
    final total = formatTime(widget.duration);
    return Semantics(
      label: '播放进度',
      value: '$shown / $total',
      child: Row(
        children: [
          _TimeLabel(text: shown, tokens: tokens),
          const SizedBox(width: _timeGap),
          Expanded(
            // LayoutBuilder 拿到滑轨宽度：拖拽位移与点击位置都按它换算，
            // 不依赖 context.findRenderObject()（那是整行，不是滑轨）。
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = constraints.maxWidth;
                return GestureDetector(
                  key: const Key('progress-slider'),
                  behavior: HitTestBehavior.opaque,
                  // .down：跨过 touch slop 的那一段位移也要交出来，
                  // 否则「一出手就拖半条」会丢掉这半条的进度。
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: (detail) =>
                      _seekToTapPosition(detail.localPosition.dx, trackWidth),
                  onHorizontalDragDown: (_) => _beginDrag(),
                  onHorizontalDragStart: (_) => _beginDrag(),
                  onHorizontalDragUpdate: (detail) =>
                      _updateDrag(detail.delta.dx, trackWidth),
                  onHorizontalDragEnd: (_) => _endDrag(),
                  onHorizontalDragCancel: _cancelDrag,
                  child: SizedBox(
                    height: _sliderHeight,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        // rail → buffer → fill：后画的在上面
                        _Layer(
                          color: tokens.progressTrack,
                          width: trackWidth,
                        ),
                        _Layer(
                          color: tokens.borderStrong,
                          width: trackWidth * _bufferedRatio,
                          keyName: 'progress-buffer',
                        ),
                        _Layer(
                          color: tokens.accent,
                          width: trackWidth * _ratio,
                          keyName: 'progress-fill',
                        ),
                        if (_total > 0)
                          Positioned(
                            left:
                                (trackWidth * _ratio - _thumbSize / 2).clamp(
                                  0.0,
                                  (trackWidth - _thumbSize).clamp(0.0, double.infinity),
                                ),
                            top: (_sliderHeight - _thumbSize) / 2,
                            child: _Thumb(tokens: tokens),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: _timeGap),
          _TimeLabel(text: total, tokens: tokens, alignEnd: true),
        ],
      ),
    );
  }
}

/// 一层轨道：左端对齐，宽度由调用方按秒数比例算好。
class _Layer extends StatelessWidget {
  const _Layer({required this.color, required this.width, this.keyName});

  final Color color;
  final double width;
  final String? keyName;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: keyName == null ? null : Key(keyName!),
        height: _trackHeight,
        width: width,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(_trackRadius),
        ),
      ),
    );
  }
}

/// 拖拽圆点：14×14 白底、2px 强调色描边（`::-webkit-slider-thumb`）。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('progress-thumb'),
      width: _thumbSize,
      height: _thumbSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 圆点底是 token（app.css 的 `background: #ffffff`），ui/ 内不写颜色字面量
        color: tokens.sliderThumb,
        border: Border.all(color: tokens.accent, width: _thumbBorder),
      ),
    );
  }
}

/// 端点时间：11.5 号等宽数字、`textDim`，固定 36 宽（跳动时行宽不抖）。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({
    required this.text,
    required this.tokens,
    this.alignEnd = false,
  });

  final String text;
  final AppTokens tokens;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _timeLabelWidth,
      child: Text(
        text,
        maxLines: 1,
        textAlign: alignEnd ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 11.5,
          color: tokens.textDim,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
