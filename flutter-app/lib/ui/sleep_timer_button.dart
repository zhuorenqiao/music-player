// lib/ui/sleep_timer_button.dart
//
// 睡眠定时器的入口：对译 React `src/components/SleepTimerButton.tsx`（工作区
// 里那一版，面板已从「5 档预设」改成滑杆）。
//
//   ┌────────────────────────────────┐
//   │ 剩余 09:32            [取消定时] │  ← 只有倒计时跑着时才有这一行
//   │ 30 分钟            1 分钟 – 4 小时 │
//   │ ▁▁▁▁▁▁▁▁●▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁       │  ← 滑杆走对数量级，短时长行程更宽
//   │ 自定义  [ 30 ]  分钟             │
//   │ [            开始            ]   │  ← 运行中变「重新计时」
//   └────────────────────────────────┘
//
// 闹钟小按钮（T 与水滴右侧 26×26 那一排，只留图标、不带按钮壳）；倒计时跑着时
// 把剩余 mm:ss 跟在图标后面 —— 不用再点开面板看。面板用 Overlay 挂：点面板以外
// 收起（与 GlassControl 同一套做法）。
//
// 滑杆映射照 React 原样：**指数**（1~240 分钟，低端 1、2、3… 分辨得很清，
// 高端自然变粗到 240），所以位置↔分钟数是 [minutesForPosition] /
// [positionForMinutes] 这一对反函数，面板里不另存刻度表。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/sleep_timer_state.dart';
import '../theme/app_tokens.dart';
import 'tool_panel.dart';

/// 面板宽度（React `.sleep-timer__panel` 的 `width: 244px`）。
const double kSleepTimerPanelWidth = 244;

/// 滑杆位置（0~100）→ 分钟数。
int minutesForPosition(double position) {
  final t = (position / 100).clamp(0.0, 1.0);
  final value = kSleepTimerMinMinutes *
      math.pow(kSleepTimerMaxMinutes / kSleepTimerMinMinutes, t);
  return value.round().clamp(kSleepTimerMinMinutes, kSleepTimerMaxMinutes);
}

/// 分钟数 → 滑杆位置（上面的反函数）。
double positionForMinutes(int minutes) {
  final clamped = minutes
      .clamp(kSleepTimerMinMinutes, kSleepTimerMaxMinutes)
      .toDouble();
  return math.log(clamped / kSleepTimerMinMinutes) /
      math.log(kSleepTimerMaxMinutes / kSleepTimerMinMinutes) * 100;
}

/// 时长读数：不足 1 小时报「X 分钟」，否则「X 小时 Y 分钟」。
String sleepTimerReadout(int minutes) {
  if (minutes < 60) return '$minutes 分钟';
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} 小时' : '${minutes ~/ 60} 小时 $rest 分钟';
}

/// 滑杆右端的上限读数（240 分钟 = 4 小时）。
final String kSleepTimerMaxReadout = sleepTimerReadout(kSleepTimerMaxMinutes);

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

  /// 已进 dispose：展开态要 setState，而 dispose 里也会走 `_removeOverlay`。
  bool _disposed = false;

  /// 面板里即将设定的分钟数（滑杆与自定义输入共用这一个值）。
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
    // 向下弹且**贴按钮右缘向左展开** —— 面板 244px 宽，居中会掉出屏幕右缘。
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
                onSlide: (position) {
                  final next = minutesForPosition(position);
                  _updatePanel(() {
                    _minutes = next;
                    _custom = '$next';
                  });
                },
                onCustomChanged: (text) => _updatePanel(() {
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
    // 展开态要换描边与底色（CSS 的 `[aria-expanded="true"]`）。
    setState(() {});
  }

  void _removeOverlay() {
    final had = _entry != null;
    _entry?.remove();
    _entry = null;
    if (had && !_disposed && mounted) setState(() {});
  }

  /// 改面板里的「即将设定的时长」，并让**已经挂出去的那份 Overlay** 重画。
  ///
  /// 面板挂在 OverlayEntry 上，是独立的一棵子树：`setState` 只重建按钮自己的
  /// 子树，不会顺手把 Overlay 里的内容重建一遍（这正是 React 版用 createPortal
  /// 挂 body 之后仍然能跟着 state 更新的差别所在）。不显式 markNeedsBuild 的话，
  /// 拖滑杆时读数会一直停在旧值 —— 值其实是改了的，只是画面不动。
  void _updatePanel(void Function() mutate) {
    setState(mutate);
    _entry?.markNeedsBuild();
  }

  @override
  void dispose() {
    _disposed = true;
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
        // 同一套 26×26 命中区、**不带按钮壳**（无描边 / 无底色 / 无圆角）。
        // 运行中不再撑成药丸、也不上底色：宽度跟着「图标 + 剩余时间」走，
        // 左右各留 6px，让图标跟另外两颗 26px 盒子里的图标对齐；最后一分钟
        // 图标与时间一起换成 danger（CSS 的 `is-ending`）。
        child: ToolTriggerChrome(
          key: const Key('sleep-timer-trigger'),
          width: running ? null : kToolTriggerSize,
          padding: running
              ? const EdgeInsets.symmetric(horizontal: 6)
              : EdgeInsets.zero,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标 17×17（`.sleep-timer__icon:2934-2938`），颜色 `--accent-light`。
              Icon(
                Icons.alarm_outlined,
                size: 17,
                color: ending ? tokens.dangerInk : tokens.accentLight,
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

/// 面板：滑杆选时长（1~240 分钟）+ 自定义分钟数 + 开始 / 重新计时。
class _SleepTimerPanel extends StatelessWidget {
  const _SleepTimerPanel({
    required this.minutes,
    required this.custom,
    required this.onSlide,
    required this.onCustomChanged,
    required this.onStart,
    required this.onCancel,
  });

  final int minutes;
  final String custom;

  /// 滑杆位置（0~100）变化。
  final ValueChanged<double> onSlide;
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
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tokens.borderStrong),
          // 底色先铺一层实色再叠渐变：面板底下可能正好压着歌词与卡片边框，
          // 不能透出任何一条（CSS 那边同样先 background-color 再渐变）。
          color: tokens.panelA,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.panelA, tokens.panelB],
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
                      fontSize: 11,
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
            // 滑杆：上面一行读当前时长，下面一根滑轨（刻度只在读数里体现）。
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  sleepTimerReadout(minutes),
                  key: const Key('sleep-timer-readout'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                // 上限读数是右对齐的「次要信息」：面板窄（244）或系统字号调大时
                // 先让它省略号收尾，绝不把读数挤出去（CSS 那边是 white-space: nowrap
                // 让它顶出去，Flutter 的 Flex 溢出会直接报错）。
                Expanded(
                  child: Text(
                    '$kSleepTimerMinMinutes 分钟 – $kSleepTimerMaxReadout',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 10, color: tokens.textFaint),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 18,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: tokens.accent,
                  inactiveTrackColor: tokens.progressTrack,
                  thumbColor: tokens.sliderThumb,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6.5,
                    disabledThumbRadius: 6.5,
                  ),
                  trackShape: const RectangularSliderTrackShape(),
                  showValueIndicator: ShowValueIndicator.never,
                ),
                child: Slider(
                  key: const Key('sleep-timer-slider'),
                  value: positionForMinutes(minutes),
                  min: 0,
                  max: 100,
                  divisions: 1000,
                  label: sleepTimerReadout(minutes),
                  onChanged: onSlide,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '自定义',
                  style: TextStyle(fontSize: 11, color: tokens.textDim),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CustomMinutesField(
                    value: custom,
                    onChanged: onCustomChanged,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '分钟',
                  style: TextStyle(fontSize: 11, color: tokens.textDim),
                ),
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
/// 光标弹回末尾、还会漏掉 dispose）。外面改了值（拖了滑杆）时同步过来。
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
          filled: true,
          fillColor: tokens.surface,
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

/// 面板里的小按钮（取消 / 开始）。
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
          alignment: Alignment.center,
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
