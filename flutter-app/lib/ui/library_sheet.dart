// lib/ui/library_sheet.dart
//
// 窄屏的播放列表弹层：对译 `src/App.tsx:843-933` 的 `PlaylistSheet`。
// 原版里它和桌面侧栏用的是**同一个** Panel（`className="panel panel--sheet"`、
// 同一份 tab / 搜索 / 列表状态），所以这里不复制任何列表代码，只把 [Panel]
// 摆进底部弹层，并递上 `onClose`（桌面侧栏里不需要收起按钮）。
//
// 三件事：
//   1. 高度上限 `0.72 * 视口`（原版 `max-height: min(78vh, 640px)`：卡片顶边
//      必须露出一截遮罩，用户才知道背后还有播放器）；
//   2. 两条出口：点遮罩关闭（`isDismissible`）+ 面板抬头那颗「收起播放列表」；
//   3. **弹层看不见时停掉音柱 ticker**（T28 预留的 `Panel.tickerEnabled`）：
//      被更上层路由挡住、或退场动画收完之后，看不见的面板不该继续按 60fps
//      走动画 —— 这正是任务里「sheet 要包一层」的那条。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'drawer_menu.dart' show scrimColor;
import 'panel.dart';

/// 弹层高度占视口的比例上限（原版 78vh，这里收一点好露出播放器）。
const double kSheetHeightFactor = 0.72;

/// 卡片宽度上限：`.sheet__card { max-width: 560px }`。
const double kSheetMaxWidth = 560;

/// 打开窄屏播放列表弹层（窄屏控制条最右侧那颗按钮的落点）。
Future<void> showLibrarySheet(BuildContext context) {
  final tokens = context.tokens;
  final viewport = MediaQuery.sizeOf(context);
  final sheetHeight = viewport.height * kSheetHeightFactor;
  return showModalBottomSheet<void>(
    context: context,
    // 内容自己撑高度：默认的 9/16 屏放不下面板的固定行 + 列表
    isScrollControlled: true,
    // 卡片自己画渐变与描边，Material 那层留空
    backgroundColor: Colors.transparent,
    barrierColor: scrimColor(tokens),
    elevation: 0,
    // 点遮罩关闭 + 面板里的「收起播放列表」，两条出口（原版同一套）
    isDismissible: true,
    enableDrag: true,
    builder: (sheetContext) {
      void close() => Navigator.of(sheetContext).maybePop();
      // 弹层自己会贴底并按内容高度入场：这里只给一个确定尺寸，
      // 再套 Align 会被算成「撑满整屏」，卡片反被顶出屏幕。
      return SizedBox(
        height: sheetHeight,
        // 平板 / 桌面窄档下不铺满整宽（原版 560 封顶）
        width: math.min(kSheetMaxWidth, viewport.width),
        child: _SheetCard(child: _SheetPanel(onClose: close)),
      );
    },
  );
}

/// 弹层卡片：`.sheet__card` 的 24 顶部圆角 + sheet-a→sheet-b 渐变 + 三边描边。
class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const radius = BorderRadius.vertical(
      top: Radius.circular(kRadiusXl),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border(
          top: BorderSide(color: tokens.borderStrong),
          left: BorderSide(color: tokens.borderStrong),
          right: BorderSide(color: tokens.borderStrong),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.sheetA, tokens.sheetB],
        ),
        boxShadow: tokens.shadowBar,
      ),
      child: ClipRRect(
        borderRadius: radius,
        // 透明 Material：InkWell 要有画布，底色已经在外面画好了
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

/// 弹层里的面板：把「看不见」翻译成 `Panel.tickerEnabled = false`。
class _SheetPanel extends StatefulWidget {
  const _SheetPanel({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_SheetPanel> createState() => _SheetPanelState();
}

class _SheetPanelState extends State<_SheetPanel> {
  Animation<double>? _routeAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context)?.animation;
    if (identical(next, _routeAnimation)) return;
    _routeAnimation?.removeListener(_onStatusChanged);
    _routeAnimation = next;
    next?.addListener(_onStatusChanged);
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _routeAnimation?.removeListener(_onStatusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 「被更上层路由挡住」Overlay 已经处理（entry 不可见时它自己关 TickerMode），
    // 这里补的是另一头：退场动画收完之后内容已经不在了，表就该停。
    final visible =
        _routeAnimation?.status != AnimationStatus.dismissed &&
        TickerMode.valuesOf(context).enabled;
    return Panel(
      onClose: widget.onClose,
      tickerEnabled: visible,
      // 弹层自己画了 sheet 卡面（`_SheetCard`），面板只摆内容 —— 对应
      // `.panel--sheet { border:none; background:transparent; box-shadow:none }`
      // （app.css:1673-1685）。不剥的话会叠出「卡里套卡」两道边。
      flush: true,
    );
  }
}
