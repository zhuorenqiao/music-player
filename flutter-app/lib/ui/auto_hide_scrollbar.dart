// lib/ui/auto_hide_scrollbar.dart
//
// 滚动条「滚动时才出现」（M3 T14）：对译 React `src/state/useAutoHideScroll.ts`。
//
//   * 停止滚动 900ms 后收回（HIDE_DELAY）；
//   * 只认**用户滚动**：滚轮 / 触摸 / 滚动键打点（700ms 窗口内算用户驱动），
//     程序化滚动（歌词自动居中、跟随播放）不点亮；
//   * 已亮起后跟着滚完再收（拖滚动条 / 惯性）；
//   * thumb 色 scrollThumb，宽 8。
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';

/// 停止滚动多久后收回滚动条（毫秒，useAutoHideScroll.ts:19）。
const int kScrollHideDelayMs = 900;

/// 用户输入之后多久内的滚动算「用户滚动」（毫秒，:22）。
const int kUserInputWindowMs = 700;

/// 真正会把容器滚起来的按键；点歌词行是定位播放，不能算（:25）。
final Set<LogicalKeyboardKey> kScrollKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.space,
};

/// auto-hide 滚动条宿主：包住任意可滚 child（播放列表 / 最近两个 ListView）。
class AutoHideScrollbar extends StatefulWidget {
  const AutoHideScrollbar({required this.child, super.key});

  final Widget child;

  @override
  State<AutoHideScrollbar> createState() => _AutoHideScrollbarState();
}

class _AutoHideScrollbarState extends State<AutoHideScrollbar> {
  bool _visible = false;
  Timer? _hideTimer;
  DateTime _lastInputAt = DateTime.fromMillisecondsSinceEpoch(0);
  final GlobalKey _scrollableKey = GlobalKey();

  void _markInput() {
    _lastInputAt = DateTime.now();
  }

  void _onScroll() {
    final userDriven =
        DateTime.now().difference(_lastInputAt).inMilliseconds <=
            kUserInputWindowMs;
    if (!userDriven && !_visible) {
      // 没有用户输入的滚动（歌词自动居中）= 不显示滚动条。
      return;
    }
    if (!_visible) {
      setState(() => _visible = true);
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(
      const Duration(milliseconds: kScrollHideDelayMs),
      () {
        if (mounted) setState(() => _visible = false);
      },
    );
  }

  void _onPointerDown(PointerDownEvent event) => _markInput();

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Listener(
      // 打点：滚轮 / 按下（触摸拖动在 Listener 的 down 里已覆盖；
      // 滚轮走 onPointerSignal）。
      onPointerDown: _onPointerDown,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _markInput();
      },
      onPointerMove: (event) {
        if (event.buttons != 0) _markInput();
      },
      child: KeyboardListener(
        focusNode: FocusNode(skipTraversal: true),
        onKeyEvent: (event) {
          if (event is KeyDownEvent && kScrollKeys.contains(event.logicalKey)) {
            _markInput();
          }
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            _onScroll();
            return false;
          },
          child: RawScrollbar(
            controller: PrimaryScrollController.maybeOf(context),
            thumbColor:
                tokens.scrollThumb.withValues(alpha: _visible ? 1 : 0),
            thickness: _visible ? 8 : 0,
            radius: const Radius.circular(4),
            thumbVisibility: false,
            child: KeyedSubtree(key: _scrollableKey, child: widget.child),
          ),
        ),
      ),
    );
  }
}
