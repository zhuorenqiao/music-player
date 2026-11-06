// lib/ui/autoplay_gate.dart
//
// 「被自动播放策略拦住之后，任意一次真实手势都重试一次」的宿主层（终审 I5）。
//
// 原版有两条 document 级监听（`src/App.tsx:1557-1579`，**捕获阶段**）：一次
// `pointerdown`、或一次不是空格/回车的 `keydown`，都会调 `resumeAutoplay()`。
// 浏览器只要检测到一次真实用户激活就肯再放行播放，所以用户点空白处、点菜单、
// 按任意键都能把被拦的播放拉起来；播放重试次数由状态层自己夹在
// `MAX_AUTOPLAY_RETRIES`（我们的 `kMaxAutoplayRetries`）之内，绝不无限打转。
//
// 我们此前只在那条「继续播放」提示的按钮上接了 `userGesture()`
// （`lib/ui/panel.dart`），其余手势一概不理 —— 用户点了半天空白，界面还是不动。
// 这一层补的就是那一条总闸。
//
// 三条与原版对齐的取舍：
//   - **挂在路由与提示条之上**（`app.dart` 的 `MaterialApp.builder`）：
//     document 级监听的等价位置，弹层 / 抽屉 / 提示条上的点击同样算数；
//   - **空格与回车让位**：原版的 `onKey` 里 `if (code === 'Space' || 'Enter') return;`
//     —— 这两下会触发聚焦控件自己的 click（也就是真的发起播放），不该在这里
//     再补一次；Flutter 里同理，`Shortcuts` 层已经把空格接走了；
//   - **播放按钮 / 列表行不额外排除**：原版靠 `closest('.btn--play, .panel__list')`
//     跳过这两块，是为了「别互相打断」。这里不必再按区域排除，因为
//     `TransportController.userGesture()` 已经改成**原地续播**（等价原版的
//     `player.play()`，不重新换源、不清进度），即使先跑一次也不会把用户的
//     点击打断 —— 代价只是重试预算可能被这些本来就会自己播放的控件用掉一格。
//
// 本层**从不消费事件**：`Listener` 只旁听指针，`Focus.onKeyEvent` 一律返回
// `ignored`，`canRequestFocus: false` + `skipTraversal` 让它不进 Tab 序列，
// 读屏用户不会 Tab 到一个看不见的节点（与快捷键宿主同一套做法）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/player_state.dart';

/// 被拦状态下的手势重试宿主：包住应用内容即可，不需要任何参数。
class AutoplayGestureGate extends StatelessWidget {
  const AutoplayGestureGate({required this.child, super.key});

  final Widget child;

  /// 空格与回车：留给聚焦控件自己的激活（原版同一条件）。
  static bool _isActivationKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter;

  @override
  Widget build(BuildContext context) {
    // 只在手势发生时取值：这一层不认识播放编排，也不订阅它的任何通知。
    final player = context.read<PlayerState>();
    return Listener(
      // `translucent`：空白处（没有任何可命中子节点）的点击也要算一次手势，
      // 这正是原版 `document` 上那条 pointerdown 的覆盖面。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => unawaited(player.userGesture()),
      child: Focus(
        debugLabel: 'autoplay-gesture-gate',
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && !_isActivationKey(event.logicalKey)) {
            unawaited(player.userGesture());
          }
          // 永远让位：这一层只旁听，不许把按键吃掉。
          return KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }
}
