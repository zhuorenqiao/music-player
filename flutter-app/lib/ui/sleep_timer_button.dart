// lib/ui/sleep_timer_button.dart
//
// 睡眠定时器的入口：对译 React `src/components/SleepTimerButton.tsx`。
//
//   ┌──────────────────────────────┐
//   │ 10 分钟 15 分钟 20 分钟 …    │  ← 预设 5 档（10 分钟默认选中）
//   │ 自定义  [ 10 ] 分钟          │  ← 1~999 分钟
//   │            [ 开始 ]          │
//   └──────────────────────────────┘
//
// 闹钟小按钮（T 与水滴右侧 26×26 那一排）；倒计时跑着时按钮撑成一枚药丸，直接
// 显示剩余 mm:ss —— 不用再点开面板看。面板用 Overlay 挂：点面板以外收起
// （与 GlassControl 同一套做法）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../state/sleep_timer_state.dart';
import '../theme/app_tokens.dart';
import 'tool_panel.dart';

/// 面板宽度（`_SleepTimerPanel` 的 `width: 224`）。
const double kSleepTimerPanelWidth = 224;

/// 睡眠定时器按钮 + 弹出面板。
class SleepTimerButton extends StatefulWidget {
  const SleepTimerButton({super.key, this.side = ToolPanelSide.above});

  /// 面板往哪边弹：控制条上那排向上，歌词页右上角向下。
  final ToolPanelSide side;

  @override
  State<SleepTimerButton> createState() => _SleepTimerButtonState();
}

class _SleepTimerButtonState extends State<SleepTimerButton> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  /// 面板里即将设定的分钟数（预设与自定义输入共用这一个值）。
  int _minutes = kSleepTimerDefaultMinutes;

  /// 自定义输入框里的原始文本（可能为空或越界，所以和 [_minutes] 分开存）。
  String _custom = '$kSleepTimerDefaultMinutes';

  void _toggle() {
    if (_entry != null) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    // 落位交给 toolPanelPosition：控制条那排向上弹（偏左 40px），歌词页右上角
    // 向下弹且**贴按钮右缘向左展开** —— 面板 224px 宽，居中会掉出屏幕右缘。
    final place = toolPanelPosition(
      anchor: pos,
      anchorWidth: box.size.width,
      anchorHeight: box.size.height,
      panelWidth: kSleepTimerPanelWidth,
      viewport: MediaQuery.sizeOf(context),
      side: widget.side,
      leftBias: -40,
      alignRight: true,
    );
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点面板以外收起（全屏阻挡层，面板自身的事件不会冒到这里）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeOverlay,
            ),
          ),
          Positioned(
            left: place.left,
            top: place.top,
            bottom: place.bottom,
            child: Material(
              color: Colors.transparent,
              child: _SleepTimerPanel(
                minutes: _minutes,
                custom: _custom,
                onMinutesChanged: (value) => setState(() => _minutes = value),
                onCustomChanged: (text) => setState(() {
                  _custom = text;
                  final parsed = int.tryParse(text.trim());
                  if (parsed != null &&
                      parsed >= kSleepTimerMinMinutes &&
                      parsed <= kSleepTimerMaxMinutes) {
                    _minutes = parsed;
                  }
                }),
                onStart: () {
                  context.read<SleepTimerState>().start(_minutes);
                  _removeOverlay();
                },
                onCancel: () {
                  context.read<SleepTimerState>().cancel();
                  _removeOverlay();
                },
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // **可空 watch**：纯展示测试没注册这一份状态时不画按钮（与歌词/封面那几处
    // 同一套容错模式）。生产里 app.dart 的 MultiProvider 一直挂着它。
    final timer = context.watch<SleepTimerState?>();
    if (timer == null) {
      return const SizedBox.shrink();
    }
    final running = timer.running;
    final ending = timer.ending;
    final label = running ? '睡眠定时器，剩余 ${timer.remainingText}' : '睡眠定时器';
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        key: _anchorKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Container(
          key: const Key('sleep-timer-trigger'),
          height: 26,
          padding: running ? const EdgeInsets.symmetric(horizontal: 8) : EdgeInsets.zero,
          width: running ? null : 26,
          decoration: BoxDecoration(
            color: running
                ? (ending ? tokens.dangerSoft : tokens.accentSoft)
                : tokens.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: running
                  ? (ending ? tokens.dangerLine : tokens.accentLine)
                  : tokens.borderStrong,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.alarm_outlined,
                size: 15,
                color: running
                    ? (ending ? tokens.dangerInk : tokens.accentLight)
                    : tokens.textDim,
              ),
              if (running) ...[
                const SizedBox(width: 5),
                Text(
                  timer.remainingText,
                  style: TextStyle(
                    fontSize: 11,
                    color: ending ? tokens.dangerInk : tokens.accentLight,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板：预设 5 档 + 自定义分钟数 + 开始 / 取消。
class _SleepTimerPanel extends StatelessWidget {
  const _SleepTimerPanel({
    required this.minutes,
    required this.custom,
    required this.onMinutesChanged,
    required this.onCustomChanged,
    required this.onStart,
    required this.onCancel,
  });

  final int minutes;
  final String custom;
  final ValueChanged<int> onMinutesChanged;
  final ValueChanged<String> onCustomChanged;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final timer = context.watch<SleepTimerState>();
    return GestureDetector(
      // 面板里的手势别冒泡到页面（滑切歌 / 点空白返回）
      onTap: () {},
      child: Container(
        width: kSleepTimerPanelWidth,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
          border: Border.all(color: tokens.borderStrong),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.sheetA, tokens.sheetB],
          ),
          boxShadow: tokens.shadowCard,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (timer.running) ...[
              Row(
                children: [
                  Text(
                    '剩余 ${timer.remainingText}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: tokens.textDim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  _SmallButton(
                    label: '取消定时',
                    foreground: tokens.dangerInk,
                    background: tokens.dangerSoft,
                    border: tokens.dangerLine,
                    onPressed: onCancel,
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in kSleepTimerPresets)
                  _SmallButton(
                    label: '$preset 分钟',
                    foreground: minutes == preset ? tokens.accentLight : tokens.textDim,
                    background: minutes == preset ? tokens.accentSoft : tokens.surface,
                    border: minutes == preset ? tokens.accentLine : tokens.borderStrong,
                    onPressed: () {
                      onMinutesChanged(preset);
                      onCustomChanged('$preset');
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('自定义', style: TextStyle(fontSize: 11.5, color: tokens.textDim)),
                const SizedBox(width: 8),
                Expanded(
                  child: _CustomMinutesField(
                    value: custom,
                    onChanged: onCustomChanged,
                  ),
                ),
                const SizedBox(width: 8),
                Text('分钟', style: TextStyle(fontSize: 11.5, color: tokens.textDim)),
              ],
            ),
            const SizedBox(height: 10),
            _SmallButton(
              label: timer.running ? '重新计时' : '开始',
              foreground: tokens.accentInk,
              background: tokens.accent,
              border: tokens.accent,
              onPressed: onStart,
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义分钟数输入框。
///
/// 自己持有 [TextEditingController]：控制器不能在 build 里现造（每次重建都会把
/// 光标弹回末尾、还会漏掉 dispose）。外面改了值（点了预设档）时同步过来。
class _CustomMinutesField extends StatefulWidget {
  const _CustomMinutesField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_CustomMinutesField> createState() => _CustomMinutesFieldState();
}

class _CustomMinutesFieldState extends State<_CustomMinutesField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _CustomMinutesField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      height: 26,
      child: TextField(
        key: const Key('sleep-timer-custom'),
        controller: _controller,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 12, color: tokens.text),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: tokens.borderStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: tokens.borderStrong),
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// 面板里的小按钮（预设档 / 取消 / 开始）。
class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
    required this.onPressed,
  });

  final String label;
  final Color foreground;
  final Color background;
  final Color border;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: foreground),
          ),
        ),
      ),
    );
  }
}
