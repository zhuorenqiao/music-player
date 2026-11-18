// lib/ui/volume_slider.dart
//
// 音量块：对译 `src/App.tsx:1018-1034` 与 `src/styles/app.css` 的 `.volume*`
// （:1271-1369）。静音按钮（40×40 圆钮，图标随电平换档）+ 0~1 滑轨。
//
//   - 电平档位与原版 `VolumeIcon level` 同一套分界（0 / <0.4 / <0.75 / 其余），
//     静音时读作 0，图标必是「关闭」那一档；
//   - **拖动过程中只改本地值，松手才交给状态层**：原版 `onChange` 只在释放时
//     `setVolume`，而 `PlayerState.setVolume` 每次都要落盘（音量与静音两个键），
//     逐帧调用等于拖一次写几十次 prefs；
//   - 读屏：按钮 `静音` / `取消静音` 两个名字换着用，滑轨一条 `音量` + `NN%`。
//
// **滑轨自绘而不用 Material 的 [Slider]**：原版是
//   * 轨道 4px 高、圆角 2，两段配色 —— 已填充段 `var(--accent)`、未填充段
//     `var(--tint-3)`（`:1333-1341` 的 `linear-gradient(90deg, …)`）；
//   * 滑块 13px 白底 + 2px `var(--accent)` 描边的圆（`:1343-1350`）。
// Material 的 Slider 默认是「粗轨道 + 纯色圆点」，只能改颜色、形状对不上，
// 与 React 端并排看就是两个东西。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 音量块整体最大宽度：`.volume { width: min(200px, 100%) }`。
const double kVolumeMaxWidth = 200;

/// 滑轨基准宽度：`.volume__input { flex: 0 1 130px }`。
const double kVolumeSliderWidth = 130;

/// 滑轨可点区域高度（`.volume__input { height: 24px }`）。
const double _kTrackHeight = 24;

/// 可见轨道条高度（`::-webkit-slider-runnable-track { height: 4px }`）。
const double _kRailHeight = 4;

/// 滑块直径（`::-webkit-slider-thumb { width/height: 13px }`）。
const double _kThumbSize = 13;

/// 滑块描边宽度（`border: 2px solid var(--accent)`）。
const double _kThumbBorder = 2;

/// 静音按钮 + 滑轨。纯 props：值与回调由调用方（控制条 / 测试）给出。
class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    required this.value,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
    super.key,
  });

  /// 当前音量 0~1。
  final double value;

  /// 是否静音（静音时滑轨画 0，但 [value] 原样留着以便取消静音后恢复）。
  final bool muted;

  /// **松手后**的最终音量 —— 只有这一刻才写状态层。
  ///
  /// 拖动过程中的中间值不经过这里（那是本地 `_scrub`）：`PlayerState.setVolume`
  /// 每调一次都要落盘 prefs（音量与静音两个键），逐帧调用等于拖一次写几十次盘。
  final ValueChanged<double> onChanged;

  /// 静音开关。
  final VoidCallback onToggleMute;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  /// 拖拽中的本地值；null 表示没在拖，一切以状态层为准。
  double? _scrub;

  bool get _muted => widget.muted;

  /// 画出来的电平：拖拽中用本地值，静音读作 0。
  double get _shown => (_scrub ?? (_muted ? 0 : widget.value)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final shown = _shown;
    return Row(
      key: const Key('volume-slider'),
      children: [
        Semantics(
          button: true,
          label: _muted ? '取消静音' : '静音',
          excludeSemantics: true,
          onTap: widget.onToggleMute,
          child: SizedBox(
            key: const Key('volume-mute'),
            width: kButtonSize,
            height: kButtonSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tokens.border),
              ),
              child: InkWell(
                onTap: widget.onToggleMute,
                customBorder: const CircleBorder(),
                overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
                child: Icon(
                  _iconFor(shown),
                  size: 18,
                  color: _muted ? tokens.textFaint : tokens.textDim,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: kVolumeSliderWidth),
              // 读屏名挂在滑轨上（原版 aria-label="音量" + aria-valuetext="NN%"）；
              // 不套整块，否则那颗静音按钮会被并进同一个节点里，读屏念成两句。
              child: Semantics(
                label: '音量',
                value: '${(shown * 100).round()}%',
                child: _VolumeTrack(
                  value: shown,
                  // 拖动中：只更新本地 `_scrub`，**不写状态层**。
                  onChanged: (next) => setState(() => _scrub = next),
                  // 松手：这一刻才把最终音量交给调用方（落盘 prefs）。
                  onChangeEnd: (next) {
                    setState(() => _scrub = null);
                    widget.onChanged(next);
                  },
                  accent: tokens.accent,
                  inactive: tokens.progressTrack,
                  thumbFill: tokens.sliderThumb,
                ),              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 档位：关闭 / 低 / 中 / 高（分界与原版一致）。
  IconData _iconFor(double level) {
    if (level <= 0) return Icons.volume_off;
    if (level < 0.4) return Icons.volume_mute;
    if (level < 0.75) return Icons.volume_down;
    return Icons.volume_up;
  }
}

/// 自绘的音量滑轨（规格见文件头）。
///
/// **绝对定位**：值 = (指针 x - 滑块半径) / 可用宽度，与 CSS
/// `input[type=range]` 一致（指针落在哪就是哪）。Material 的 [Slider] 也是
/// 绝对定位 —— 用「相对位移」会让拖拽落点整体偏一截。
class _VolumeTrack extends StatefulWidget {
  const _VolumeTrack({
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.accent,
    required this.inactive,
    required this.thumbFill,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final Color accent;
  final Color inactive;
  final Color thumbFill;

  @override
  State<_VolumeTrack> createState() => _VolumeTrackState();
}

class _VolumeTrackState extends State<_VolumeTrack> {
  /// 拖拽中：记录起点（用来判断「确实在拖」）。
  double? _dragDx;

  /// 本次按下是否已经产生过位移（区分「点击」与「拖动」）。
  bool _dragMoved = false;

  /// 当前按下的指针 id（只跟一根手指）。
  int? _pointerId;

  /// 滑块中心可走区间是 `[r, width-r]`（两端各留半个滑块），
  /// 所以可用宽度 = `width - 2r`。
  double _usable(double width) =>
      (width - _kThumbSize).clamp(1.0, double.infinity);

  double _valueAt(double dx, double width) {
    final usable = _usable(width);
    return ((dx - _kThumbSize / 2) / usable).clamp(0.0, 1.0);
  }

  /// 指针按下：记录起点。**不立刻改值** —— 按下与拖动要能区分。
  void _onPointerDown(PointerDownEvent event, double width) {
    _dragDx = event.localPosition.dx;
    _dragMoved = false;
    _pointerId = event.pointer;
  }

  /// 指针移动：绝对定位算值。位移超过几像素就算「在拖」。
  void _onPointerMove(PointerMoveEvent event, double width) {
    if (_pointerId != null && event.pointer != _pointerId) return;
    final start = _dragDx;
    if (start == null) return;
    if ((event.localPosition.dx - start).abs() > 2) _dragMoved = true;
    if (!_dragMoved) return;
    final next = _valueAt(event.localPosition.dx, width);
    _lastValue = next;
    widget.onChanged(next);
  }

  /// 指针抬起：没拖过就是「点击定位」，拖过就是「松手提交」。
  ///
  /// 提交的是**松手那一刻的最终值**（不是 `widget.value` —— 拖动过程中的
  /// 值只存在本地 `_scrub`，widget 上还是旧值）。
  void _onPointerUp(PointerEvent event, double width) {
    if (_pointerId != null && event.pointer != _pointerId) return;
    final moved = _dragMoved;
    final start = _dragDx;
    _dragDx = null;
    _dragMoved = false;
    _pointerId = null;
    if (moved) {
      widget.onChangeEnd(_lastValue);
    } else if (start != null) {
      final next = _valueAt(start, width);
      widget.onChanged(next);
      widget.onChangeEnd(next);
    }
  }

  /// 拖动过程中最后一次算出的值（松手时提交它）。
  double _lastValue = 0;

  void _onPointerCancel() {
    _dragDx = null;
    _dragMoved = false;
    _pointerId = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : kVolumeSliderWidth;
        final inset = _kThumbSize / 2;
        final thumbX = inset + widget.value * _usable(width);
        return Listener(
          // **用原始指针事件而不是手势识别器**：手势竞技场里 tap 与 pan 会互相
          // 判负 —— 一次性的大幅位移（例如辅助技术的「跳到某处」，或测试里
          // `tester.drag` 的单步位移）可能被判成 tap，于是拖不动；反过来
          // 纯手势识别器在「按下即定位」上又比原始事件多一层延迟。
          // Listener 直接看 pointer 的移动量：语义最直白，也最接近 CSS
          // range 的行为（指针在哪就是哪）。
          key: const Key('volume-input'),
          onPointerDown: (event) => _onPointerDown(event, width),
          onPointerMove: (event) => _onPointerMove(event, width),
          onPointerUp: (event) => _onPointerUp(event, width),
          onPointerCancel: (_) => _onPointerCancel(),
          child: SizedBox(
            height: _kTrackHeight,
            width: width,
            child: CustomPaint(
              painter: _VolumeTrackPainter(
                value: widget.value,
                thumbX: thumbX,
                railHeight: _kRailHeight,
                thumbSize: _kThumbSize,
                thumbBorder: _kThumbBorder,
                accent: widget.accent,
                inactive: widget.inactive,
                thumbFill: widget.thumbFill,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VolumeTrackPainter extends CustomPainter {
  const _VolumeTrackPainter({
    required this.value,
    required this.thumbX,
    required this.railHeight,
    required this.thumbSize,
    required this.thumbBorder,
    required this.accent,
    required this.inactive,
    required this.thumbFill,
  });

  final double value;
  final double thumbX;
  final double railHeight;
  final double thumbSize;
  final double thumbBorder;
  final Color accent;
  final Color inactive;
  final Color thumbFill;

  @override
  void paint(Canvas canvas, Size size) {
    final railY = (size.height - railHeight) / 2;
    final railRect = Rect.fromLTWH(0, railY, size.width, railHeight);
    final radius = Radius.circular(railHeight / 2);

    // 未填充段（整条底色 = --tint-3）。
    canvas.drawRRect(
      RRect.fromRectAndRadius(railRect, radius),
      Paint()..color = inactive,
    );
    // 已填充段（--accent），裁到圆角轨道里。
    final filled = size.width * value.clamp(0.0, 1.0);
    if (filled > 0) {
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(railRect, radius));
      canvas.drawRect(
        Rect.fromLTWH(0, railY, filled, railHeight),
        Paint()..color = accent,
      );
      canvas.restore();
    }

    // 滑块：白底 + accent 描边（`:1343-1350`）。
    final r = thumbSize / 2;
    canvas.drawCircle(
      Offset(thumbX, size.height / 2),
      r - thumbBorder / 2,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = thumbBorder,
    );
    canvas.drawCircle(
      Offset(thumbX, size.height / 2),
      r - thumbBorder,
      Paint()..color = thumbFill,
    );
  }

  @override
  bool shouldRepaint(_VolumeTrackPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.thumbX != thumbX ||
      oldDelegate.accent != accent ||
      oldDelegate.inactive != inactive ||
      oldDelegate.thumbFill != thumbFill;
}
