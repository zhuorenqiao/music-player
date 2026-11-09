// lib/ui/swipe_to_switch.dart
//
// 手机左右滑切歌：对译 React 版 `src/App.tsx:324-378` 的 `useTrackSwipe`
// （`SWIPE_SWITCH_PX` 常量在 `:325`），播放卡与（T19 的）歌词页共用。
//
// 原版判定逐字（`:350-371`）：
//   * 单指（`touches.length === 1`），多指则整次作废；
//   * 从按钮 / 输入框 / 下拉上起手的不参与（避免误触）；
//   * `Date.now() - from.at > 700` → 不切（够快才算，慢拖是滚动或犹豫）；
//   * `|dx| < 56` 或 `|dx| < |dy| * 1.25` → 不切（位移够大且**横向为主**）；
//   * `dx < 0` → 下一首；`dx > 0` → 上一首（原版调用的是 `playPrevTrack`
//     —— 与「上一首」按钮的 `playPrev` 不是同一个牌，右滑不受三秒规则影响）。
//
// **`|dy|` 必须自己量**（这推翻了 brief 的一条推断，依据是 Flutter 源码）：
// brief 说「横向识别器在竞技场里只会赢过纵向手势，等价于横向为主那条判定，
// `|dy|` 不再单独量」。这不成立 —— `HorizontalDragGestureRecognizer` 的接受判据是
// `globalDistanceMoved.abs() > computeHitSlop(...)`（monodrag.dart:1028-1034），
// 而 `_getDeltaForDetails` 把每个 delta 都折成 `Offset(delta.dx, 0)`
// （monodrag.dart:1037），**dy 在整条链路上被丢掉、从不参与比较**。
// 于是 `dx=120 / dy=200` 的斜下大滑动照样赢得竞技场并触发结束回调；
// 只有 `|dx| < hitSlop(18)` 的纯纵向滑动才会被放弃。按 brief 那样不量 `|dy|`，
// 会把「竖着划一下列表」判成切歌，与 React 相反。
//
// 所以这里用**起止全局坐标**求真实 dx / dy：`DragEndDetails.globalPosition` 是
// 真实指针位置（`_lastPosition.global`），拿它与 `DragStartDetails.globalPosition`
// 相减就等价于原版的 `touch.clientX - from.x` / `clientY - from.y`。
// 不能用 `details.delta.dy` 累加 —— 横向识别器给出来的 dy 恒为 0。
//
// 其余机制差异（写清楚免得后来人以为是漏了）：
//   * **单指**：一次 `onHorizontalDragStart/End` 只对应一个指针序列
//     （`GestureDetector` 不会把第二根手指合成第二次结束回调）。原版是
//     `touches.length !== 1` 直接作废本次手势，这里不额外计数 —— 没有用例覆盖，
//     且实际观感一致，真正防误触的是下面那三道闸。
//   * 时长用 [Stopwatch]，不用 `DateTime.now()`（原版用 `Date.now()`）——
//     同一语义、可测，且不受系统时钟调整影响。
import 'package:flutter/material.dart';

/// 左右滑动切歌的最小横向位移（px），原版 `SWIPE_SWITCH_PX`（App.tsx:325）。
const double kSwipeSwitchPx = 56;

/// 一次滑动的时长上限（毫秒），原版 `Date.now() - from.at > 700`（App.tsx:359）。
const int kSwipeSwitchMaxMs = 700;

/// 横向位移必须是纵向的多少倍，原版 `Math.abs(dx) < Math.abs(dy) * 1.25`（App.tsx:362）。
const double kSwipeSwitchRatio = 1.25;

/// 把子树包成「左右滑切歌」热区。
///
/// [child] 里如果有可滚动视图（T19 的歌词页），横滑仍然归这里 —— 滚动视图只认
/// 纵向手势，两者在竞技场里不冲突。
class SwipeToSwitchTrack extends StatefulWidget {
  const SwipeToSwitchTrack({
    required this.child,
    required this.onPrev,
    required this.onNext,
    super.key,
  });

  final Widget child;

  /// 右滑（`dx > 0`）。
  final VoidCallback onPrev;

  /// 左滑（`dx < 0`）。
  final VoidCallback onNext;

  @override
  State<SwipeToSwitchTrack> createState() => _SwipeToSwitchTrackState();
}

class _SwipeToSwitchTrackState extends State<SwipeToSwitchTrack> {
  /// 起手计时；`onHorizontalDragStart` 置位、`onHorizontalDragEnd` 用掉即清。
  final Stopwatch _elapsed = Stopwatch();

  /// 起手的全局坐标（原版 `start.current = {x: touch.clientX, ...}`）。
  Offset _start = Offset.zero;

  void _onStart(DragStartDetails details) {
    _start = details.globalPosition;
    _elapsed
      ..reset()
      ..start();
  }

  void _onEnd(DragEndDetails details) {
    _elapsed.stop();
    // 起止坐标相减 = 原版量法（不能用 details.delta.dy 累加：横向识别器把它清零了）。
    final moved = details.globalPosition - _start;
    final dx = moved.dx;
    final dy = moved.dy;

    // 够快：原版是 `Date.now() - from.at > 700` 就放弃。
    if (_elapsed.elapsedMilliseconds > kSwipeSwitchMaxMs) return;
    // 位移够大且横向为主：原版 `|dx| < 56 || |dx| < |dy| * 1.25` 就放弃。
    if (dx.abs() < kSwipeSwitchPx) return;
    if (dx.abs() < dy.abs() * kSwipeSwitchRatio) return;
    // 左滑下一首、右滑上一首（原版 :366-370）。
    if (dx < 0) {
      widget.onNext();
    } else {
      widget.onPrev();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // opaque：播放卡本身有底，热区不该只在有子控件的像素上生效。
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onStart,
      // 横向识别器只把 dx 送进来（dy 恒 0），所以位移一律在 _onEnd 里按起止坐标算。
      onHorizontalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}
