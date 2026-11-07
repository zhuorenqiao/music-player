// lib/ui/autoplay_gate.dart
//
// 「被自动播放策略拦住之后，任意一次真实手势都重试一次」的宿主层（终审 I5，
// 覆盖面按终审 R7 补齐）。
//
// 原版有两条 document 级监听（`src/App.tsx:1557-1579`，**捕获阶段**）：一次
// `pointerdown`、或一次不是空格回车的 `keydown`，都会调 `resumeAutoplay()`。
// 浏览器只要检测到一次真实用户激活就肯再放行播放，所以用户点空白处、点菜单、
// 按任意键都能把被拦的播放拉起来；重试次数由状态层自己夹在
// `kMaxAutoplayRetries` 之内，绝不无限打转。
//
// R7 补的是第 1 轮移植丢掉的两条覆盖面：
//
//   1. **按键不能被下层「吃掉」就作废**。Flutter 的按键是从焦点节点
//      **自下而上**传的：网关哪怕挂在 `AppShortcuts` 外层，被输入框（方向键、
//      光标移动）或被快捷键表（`M` / `N` / `P` / 上下左右）消费掉的按键一次也
//      传不到这里。现在按键入口换成 `HardwareKeyboard.addHandler` —— 这是
//      Flutter 里「document 级监听」的等价位置：所有注册者都会收到每一次按键，
//      与下游是否消费无关（见 `services/hardware_keyboard.dart` 里
//      KeyEventManager 那段「All destinations will always receive the event
//      regardless of the handlers' results」）。唯一与原版的差别是顺序：这条
//      回调排在焦点树派发之后，所以「先记一次手势再让下层处理」在这里落地成
//      「无论下层处没处理，这一次都算数」；对额度与结果都没有影响，因为
//      `TransportController.userGesture` 成功出声即收横幅（终审 R3），下层已经
//      把播放拉起来的那一次回来时前置条件早就不成立了。
//
//   2. **被播放按钮 / 列表自己吃掉的点击不重复计额度**（原版
//      `closest('.btn--play, .panel__list')` 的排除意图，`src/App.tsx:1560-1564`
//      「交给它们，别互相打断」）。第 1 轮的注释写着「不必按区域排除，因为原地
//      续播不会打断」—— 不重复打断是对的，但**额度**照样被花掉一格：pointer-down
//      一次重试、pointer-up 之后按钮自己再一次。现在那两块区域自己认领指针
//      （[GestureOwnedRegion]），网关在整轮命中测试走完之后再决定这一次算不算
//      「任意手势」，被认领的就跳过。
//
// 三条与原版对齐的取舍：
//   - **挂在路由与提示条之上**（`app.dart` 的 `MaterialApp.builder`）：
//     document 级监听的等价位置，弹层 / 抽屉 / 提示条里的一次交互同样算数；
//   - **空格与回车让位**：原版的 `onKey` 里 `if (code === 'Space' || 'Enter') return;`
//     —— 这两下会触发聚焦控件自己的 click（也就是真的发起播放），不该在这里
//     再补一次；
//   - **从不消费事件**：`Listener` 只旁听指针，按键回调一律返回 false，
//     打字、光标、快捷键一个都不受影响。不再有 `Focus` 包裹层：
//     `canRequestFocus: false` + `skipTraversal` 那套「不进 Tab 序列」的做法
//     在换成全局按键入口之后整块消失，读屏用户更不可能 Tab 到一个隐形节点。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/player_state.dart';

/// 被拦状态下的手势重试宿主：包住应用内容即可，不需要任何参数。
class AutoplayGestureGate extends StatefulWidget {
  const AutoplayGestureGate({required this.child, super.key});

  final Widget child;

  @override
  State<AutoplayGestureGate> createState() => _AutoplayGestureGateState();
}

class _AutoplayGestureGateState extends State<AutoplayGestureGate> {
  /// 本轮 pointer-down 里被 [GestureOwnedRegion] 认领掉的指针 id。
  ///
  /// 用 id 而不是布尔标记：多点触控 / 快速连点时同一时刻可能有多个 down，
  /// 认领与查询都按 id 对齐，不会互相顶掉。
  final Set<int> _claimedPointers = <int>{};

  @override
  void initState() {
    super.initState();
    // 与 `document.addEventListener('keydown', onKey, true)` 同一位置：
    // 每一次硬件按键都先到这里，不管下面谁把它消费掉。
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  /// 空格与回车：留给聚焦控件自己的激活（原版同一条件）。
  static bool _isActivationKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter;

  bool _onHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent && !_isActivationKey(event.logicalKey)) {
      _gesture();
    }
    // 永远 false：这一层只旁听，绝不替事件「收尾」，
    // 否则输入框打字与系统媒体键都会被它挡掉。
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    final pointer = event.pointer;
    // 整轮命中测试走完（区域认领与顺序无关）之后才决定。
    scheduleMicrotask(() {
      if (_claimedPointers.remove(pointer)) return;
      _gesture();
    });
  }

  /// 收摊：pointer-up / cancel 把这个 id 从认领表里划掉（第 3 轮 M5）。
  ///
  /// 正常路径用不到它 —— 网关自己看到过的那次 down，其微任务已经把 id 处理掉了
  /// （认领就 remove、没认领就根本不在表里）。它清的是**网关没观察到的 claim**：
  /// 上面还有 Overlay / 对话框之类吃掉了 down，而子树里的 [GestureOwnedRegion]
  /// 仍然登记了一次认领。这样的 id 会永远留在表里，而 Flutter 是**回收** pointer
  /// id 的（4 个一套），于是下一次同样 id 的空白点击会被当成「控件自己的」而
  /// 白白吞掉一次手势 —— 少一格重试额度，还是那种复现不出来的少。
  ///
  /// 同样排一条微任务：微任务是 FIFO，down 那条先排先跑，所以这里绝不会抢在
  /// 「这一次算不算空白手势」的决定之前把认领记录抹掉（那样点播放按钮就会
  /// 被算成两次手势，正是 R7 要挡的）。
  void _releasePointer(PointerEvent event) {
    final pointer = event.pointer;
    scheduleMicrotask(() => _claimedPointers.remove(pointer));
  }

  void _gesture() {
    if (!mounted) return;
    unawaited(context.read<PlayerState>().userGesture());
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // `translucent`：空白处（没有任何可命中子节点）的点击也要算一次手势，
      // 这正是原版 `document` 上那条 pointerdown 的覆盖面。
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      // 认领表只在网关自己那条微任务里出栈，漏进去的 id 由这两条收摊（M5）。
      onPointerUp: _releasePointer,
      onPointerCancel: _releasePointer,
      child: _GestureClaimScope(claim: _claimedPointers.add, child: widget.child),
    );
  }
}

/// 「这一块的下一次点击属于控件自己」的标记（终审 R7）。
///
/// 原版靠 `target.closest('.btn--play, .panel__list')` 跳过这两块 —— 它们自己的
/// click 就会发起播放（`togglePlay` / `playAt`），网关再补一次重试就是把同一个
/// 意图算两遍：额度少一格，还多一次没人要求过的 `play()`。
///
/// Flutter 里没有 DOM 祖先可问，改由区域自己认领指针：[AutoplayGestureGate] 在
/// 整轮 pointer-down 派发结束后（微任务）才决定这次算不算「空白处的手势」，
/// 于是命中测试的顺序（子先还是父先）都不影响结论。
class GestureOwnedRegion extends StatelessWidget {
  const GestureOwnedRegion({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final claim = _GestureClaimScope.controllerOf(context);
    // 网关不在上面（单独摆一颗播放按钮的测试、或界面片段被复用）：
    // 什么都不登记，渲染原样。
    if (claim == null) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => claim(event.pointer),
      child: child,
    );
  }
}

/// 把「认领指针」递给子树里那些 [GestureOwnedRegion]。
class _GestureClaimScope extends InheritedWidget {
  const _GestureClaimScope({required this.claim, required super.child});

  final void Function(int pointer) claim;

  static void Function(int pointer)? controllerOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_GestureClaimScope>()
          ?.claim;

  @override
  bool updateShouldNotify(_GestureClaimScope oldWidget) =>
      claim != oldWidget.claim;
}
