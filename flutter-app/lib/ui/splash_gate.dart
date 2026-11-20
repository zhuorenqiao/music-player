import 'package:flutter/material.dart';

import 'splash_page.dart';

/// 启动闸门：先播放 2 秒开屏，再淡入真正的首页。
///
/// 只替换根路由里的首屏内容，首页仍然是同一个 [child]（在 provider / 快捷键
/// 层之下），因此开屏不会影响任何业务状态，也不会额外压一层 Navigator 路由。
///
/// 开屏固定使用暗色品牌版（墨黑 + 纸白 + 薄荷绿），不跟随 App 的明暗主题：
/// 这是与设计稿一致的品牌时刻；首页仍按用户当前主题渲染。
class SplashGate extends StatefulWidget {
  const SplashGate({
    required this.child,
    this.duration = const Duration(seconds: 2),
    super.key,
  });

  /// 开屏结束后要显示的页面（本项目是 `HomePage`）。
  final Widget child;

  /// 开屏动画时长，默认 2 秒。
  final Duration duration;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _showChild = false;

  void _reveal() {
    if (!mounted || _showChild) return;
    setState(() => _showChild = true);
  }

  @override
  Widget build(BuildContext context) {
    // 系统「减弱动态效果」开着时，开屏本身会直接到终态；这里连淡入也取消，
    // 避免无意义的 360ms 过渡。
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: _showChild
          ? KeyedSubtree(
              key: const ValueKey<String>('home'),
              child: widget.child,
            )
          : SplashPage(
              key: const ValueKey<String>('splash'),
              duration: widget.duration,
              title: '流光音乐',
              englishTitle: 'LIU GUANG',
              tagline: '把此刻，交给声音',
              onCompleted: _reveal,
            ),
    );
  }
}
