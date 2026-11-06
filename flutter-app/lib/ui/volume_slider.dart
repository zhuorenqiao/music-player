// lib/ui/volume_slider.dart
//
// 音量块：对译 `src/App.tsx:1018-1034` 与 `src/styles/app.css` 的 `.volume*`
// （:1271-1341）。静音按钮（40×40 圆钮，图标随电平换档）+ 0~1 滑轨。
//
//   - 电平档位与原版 `VolumeIcon level` 同一套分界（0 / <0.4 / <0.75 / 其余），
//     静音时读作 0，图标必是「关闭」那一档；
//   - **拖动过程中只改本地值，松手才交给状态层**：原版 `onChange` 只在释放时
//     `setVolume`，而 `PlayerState.setVolume` 每次都要落盘（音量与静音两个键），
//     逐帧调用等于拖一次写几十次 prefs；
//   - 读屏：按钮 `静音` / `取消静音` 两个名字换着用，滑轨一条 `音量` + `NN%`。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 音量块整体最大宽度：`.volume { width: min(200px, 100%) }`。
const double kVolumeMaxWidth = 200;

/// 滑轨基准宽度：`.volume__input { flex: 0 1 130px }`。
const double kVolumeSliderWidth = 130;

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

  /// 松手后的最终音量。
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
                child: Slider(
                  key: const Key('volume-input'),
                  value: shown,
                  onChanged: (next) => setState(() => _scrub = next),
                  onChangeEnd: (next) {
                    setState(() => _scrub = null);
                    widget.onChanged(next);
                  },
                  activeColor: tokens.accent,
                  inactiveColor: tokens.progressTrack,
                ),
              ),
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
