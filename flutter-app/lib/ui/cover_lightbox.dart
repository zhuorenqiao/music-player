// lib/ui/cover_lightbox.dart
//
// 封面放大层（M2b T11）：对译 React `src/App.tsx:1155-1447` 的 Lightbox。
//
//   ┌────────────────────────────────────┐
// │ [×]                                 │  ← 右上 40×40 关闭按钮（18,18）
// │        ┌──────────────┐             │
// │        │              │             │  ← 完整方图（曲目区裁成圆的四角
// │        │   封面大图    │             │     在这里补回来），滚轮/双击/
// │        │              │             │     捏合三种锚点缩放 + 拖拽平移
// │        └──────────────┘             │
// │      曲名 · 歌手 · 专辑（caption）    │
// └────────────────────────────────────┘
//
// 关闭三路：点图以外的遮罩 / 关闭按钮 / Esc（closeOverlay 分支，灯箱叠在
// 歌词页之上 —— App.tsx:1581-1591）。点在图上不关闭。
//
// 手势与视图状态逐字对译（常量 App.tsx:1156/1159/1162）：
//   * 缩放 [1, 4]；滚轮一格 `exp(-deltaY * 0.0016)`、光标锚点；
//   * 双击逐级 1× → 2× → 4× → 1×、点击处锚点；
//   * 捏合以「两指中点对应的图片内容保持不动」为锚，中点移动同时当平移；
//   * 位移夹取 = `尺寸 × (scale − 1) / 2`（图居中 + 以自身中心缩放，
//     App.tsx:1240-1255）—— 图片边缘不许离开视口。
//
// 视图状态以 notifier 为准（App.tsx:1172-1176 的 ref 理由逐字成立）：滚轮
// 一帧连发时若从渲染态读 scale，后面的几次都基于旧值 —— 八次缩放只生效
// 一次。所以每次变换都在同一同步帧内「读 value → 算 → 写 value」。
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../playback/track.dart';
import '../state/cover_state.dart';
import '../state/lightbox_controller.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'cover_image.dart';

/// 缩放上限（App.tsx:1156；「再大就是马赛克了」）。
const double kLightboxMaxScale = 4;

/// 滚轮指数缩放速率（App.tsx:1159；手感均匀）。
const double kLightboxZoomRate = 0.0016;

/// 双击一次放大的倍数（App.tsx:1162）。
const double kLightboxDoubleScale = 2;

/// 图片的布局上限（app.css:3678-3679：`max-width: min(78vw, 620px)`、
/// `max-height: min(72vh, 620px)`）。
const double kLightboxImgMax = 620;

/// 视图状态（scale + offset，不可变值类型 —— 一个 notifier 装两者，
/// 「缩放和位移同帧生效」不因两次 setState 而撕裂）。
@immutable
class LightboxView {
  const LightboxView({this.scale = 1, this.offsetX = 0, this.offsetY = 0});

  final double scale;
  final double offsetX;
  final double offsetY;

  LightboxView copyWith({double? scale, double? offsetX, double? offsetY}) =>
      LightboxView(
        scale: scale ?? this.scale,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
      );
}

/// 灯箱本体。开合由 [LightboxController]（provider）决定；挂载点在
/// home_page.dart 的全屏 Stack 顶层（歌词页保持其下渲染）。
class CoverLightbox extends StatefulWidget {
  const CoverLightbox({required this.onClose, super.key});

  /// 关闭动作。装配层传 `LightboxController.close`（要触发焦点归还）。
  final VoidCallback onClose;

  @override
  State<CoverLightbox> createState() => _CoverLightboxState();
}

class _CoverLightboxState extends State<CoverLightbox> {
  /// 视图状态：ref + 渲染合一（App.tsx:1170-1184）。滚轮一帧连发时
  /// 「读 → 算 → 写」在同一同步段内完成，不会基于旧值叠加。
  final ValueNotifier<LightboxView> _view =
      ValueNotifier(const LightboxView());

  /// 图片的实际布局尺寸（clampOffset 与 zoomAt 都要它）。
  Size _imgSize = Size.zero;

  /// 活跃指针表（App.tsx:1187 的 pointers Map 对译）。
  final Map<int, Offset> _pointers = <int, Offset>{};

  /// 单指拖拽基准（App.tsx:1185 的 dragging 对译）。
  int? _dragPointerId;
  Offset _dragStart = Offset.zero;
  Offset _dragBase = Offset.zero;

  /// 捏合基准（App.tsx:1192-1197）：起始指距、起始 scale、图自身中心
  ///（未缩放坐标系）、起始中点在图片本地坐标系里的位置。
  double? _pinchDistance;
  double? _pinchScale;
  Offset? _pinchCenter;
  Offset? _pinchLocal;

  /// 关闭按钮的焦点（打开时 autofocus，App.tsx:1225-1229）。
  final FocusNode _closeFocus = FocusNode();

  /// 图片节点的 key：锚点换算要它的**实际全局中心**（Stack 里图片居中，
  /// 但灯箱根是全屏 —— 用 `imgSize / 2` 会偏出「(视口中心 − 图半边)」的差）。
  final GlobalKey _imgKey = GlobalKey();

  Track? _lastTrack;

  /// 图片中心的视口坐标（含当前位移 —— Transform 加过的那份）。
  ///
  /// `RenderBox.localToGlobal` 会把祖先与自身的 transform（translate ×
  /// scale）一并算上，所以返回的就是「变换后的图中心」，与 React 的
  /// `getBoundingClientRect()` 中心同义。
  Offset _imgGlobalCenter() {
    final box = _imgKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || box.hasSize == false) {
      // 布局还没走完：退回「视口中心」近似（1× 居中时两者重合）。
      final root = context.findRenderObject()! as RenderBox;
      return root.localToGlobal(root.size.center(Offset.zero));
    }
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resetIfTrackChanged();
  }

  /// 每次打开 / 换图都回到 1× 居中（App.tsx:1231-1238 逐字）——
  /// **不把上一首的缩放状态带过去**。
  void _resetIfTrackChanged() {
    final track = context.read<PlayerState>().current;
    if (identical(track, _lastTrack)) return;
    _lastTrack = track;
    _view.value = const LightboxView();
    _pointers.clear();
    _pinchDistance = null;
    _pinchScale = null;
    _pinchCenter = null;
    _pinchLocal = null;
    _dragPointerId = null;
  }

  @override
  void dispose() {
    _closeFocus.dispose();
    _view.dispose();
    super.dispose();
  }

  /// 位移夹取（App.tsx:1240-1255 逐字公式）：图片居中 + 以自身中心缩放，
  /// 单边最大位移 = 尺寸 × (scale − 1) / 2 —— 图片边缘不离开视口。
  Offset _clampOffset(Offset next, double nextScale) {
    if (_imgSize.isEmpty) return next;
    final maxX = _imgSize.width * (nextScale - 1) / 2;
    final maxY = _imgSize.height * (nextScale - 1) / 2;
    return Offset(
      next.dx.clamp(-maxX, maxX),
      next.dy.clamp(-maxY, maxY),
    );
  }

  /// 以视口坐标 (globalX, globalY) 为锚点缩放到 [nextScale]：
  /// 锚点底下那片像素保持不动（滚轮与双击共用，App.tsx:1261-1282 逐字）。
  void _zoomAt(double nextScale, double globalX, double globalY) {
    final current = _view.value;
    if (nextScale == current.scale || _imgSize.isEmpty) return;
    // 图片中心的视口坐标（含位移，getBoundingClientRect 的等价物）。
    final origin = _imgGlobalCenter();
    final cx = globalX - origin.dx;
    final cy = globalY - origin.dy;
    final localX = (cx - current.offsetX) / current.scale;
    final localY = (cy - current.offsetY) / current.scale;
    final next = Offset(cx - localX * nextScale, cy - localY * nextScale);
    final clamped = _clampOffset(next, nextScale);
    _view.value = _view.value.copyWith(
      scale: nextScale,
      offsetX: clamped.dx,
      offsetY: clamped.dy,
    );
  }

  /// 双击分级（App.tsx:1434-1442 逐字）：1× → 2× → 4× → 1×，点击处锚点。
  void _onDoubleTap(TapDownDetails details) {
    final current = _view.value.scale;
    final next = current >= kLightboxMaxScale
        ? 1.0
        : math.min(kLightboxMaxScale, current * kLightboxDoubleScale);
    // TapDownDetails.localPosition 相对图手势区（SizedBox），它的全局
    // 坐标用 _imgGlobalCenter() 的同一 RenderBox（_imgKey 的 SizedBox，
    // 尺寸就是 _imgSize）换算 —— 与 React 的 event.clientX（视口坐标）
    // 等价。
    final box = _imgKey.currentContext?.findRenderObject();
    final global = box is RenderBox && box.attached
        ? box.localToGlobal(details.localPosition)
        : details.globalPosition;
    _zoomAt(next, global.dx, global.dy);
  }

  /// 滚轮缩放（App.tsx:1290-1305 对译）：`exp(-deltaY * 0.0016)`、光标锚点。
  void _onWheel(PointerScrollEvent event) {
    final next = math
        .min(
          kLightboxMaxScale,
          math.max(
            1.0,
            _view.value.scale * math.exp(-event.scrollDelta.dy * kLightboxZoomRate),
          ),
        )
        .toDouble();
    _zoomAt(next, event.position.dx, event.position.dy);
  }

  /// 第二指落下（或三指变两指）时建捏合基准（App.tsx:1200-1223 逐字）。
  void _beginPinch() {
    final fingers = _pointers.values.toList();
    if (fingers.length < 2 || _imgSize.isEmpty) {
      _pinchDistance = null;
      return;
    }
    final a = fingers[0];
    final b = fingers[1];
    final current = _view.value;
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    // 含当前位移的图中心（getBoundingClientRect 等价）。
    final globalCenter = _imgGlobalCenter();
    _pinchDistance = (a - b).distance.abs() < 1 ? 1 : (a - b).distance;
    _pinchScale = current.scale;
    // 图自身中心（未缩放坐标系）：把位移扣掉（App.tsx:1217-1219 注释逐字）。
    _pinchCenter = Offset(
      globalCenter.dx - current.offsetX,
      globalCenter.dy - current.offsetY,
    );
    _pinchLocal = Offset(
      (mid.dx - globalCenter.dx) / current.scale,
      (mid.dy - globalCenter.dy) / current.scale,
    );
    // 捏合开始同时结束单指拖拽（App.tsx:1221-1222）。
    _dragPointerId = null;
  }

  /// 捏合移动（App.tsx:1341-1356 逐字）：指距比 × 基准 scale = 新 scale，
  /// 中点既当缩放锚又当平移 —— 指间内容不漂移。
  void _applyPinch() {
    final fingers = _pointers.values.toList();
    if (_pinchDistance == null || fingers.length < 2) return;
    final a = fingers[0];
    final b = fingers[1];
    final distance = (a - b).distance.abs() < 1 ? 1 : (a - b).distance;
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final nextScale = math
        .min(
          kLightboxMaxScale,
          math.max(1.0, _pinchScale! * distance / _pinchDistance!),
        )
        .toDouble();
    final next = Offset(
      mid.dx - _pinchCenter!.dx - _pinchLocal!.dx * nextScale,
      mid.dy - _pinchCenter!.dy - _pinchLocal!.dy * nextScale,
    );
    final clamped = _clampOffset(next, nextScale);
    _view.value = _view.value.copyWith(
      scale: nextScale,
      offsetX: clamped.dx,
      offsetY: clamped.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final player = context.watch<PlayerState>();
    final cover = context.watch<CoverState>();
    final track = player.current;
    final displayPath = track == null
        ? ''
        : cover.coverForDisplay(
            cover: track.cover,
            artist: track.artist,
            title: track.title,
            trackId: track.id,
          );
    // caption 逐字（App.tsx:1444）：[title, artist, album].filter(Boolean).join(' · ')。
    final caption = [
      if (track != null && track.title.isNotEmpty) track.title,
      if (track != null && track.artist.isNotEmpty) track.artist,
      if (track != null && track.album.isNotEmpty) track.album,
    ].join(' · ');

    return Semantics(
      label: '封面大图',
      child: Listener(
        onPointerSignal: _onPointerSignal,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: GestureDetector(
          // 点图以外的遮罩关闭（App.tsx:1413-1415 的 target === currentTarget）：
          // 行为 translucent 让「点在图上」的事件先被图的手势吃掉。
          behavior: HitTestBehavior.translucent,
          onTap: widget.onClose,
          child: Container(
            color: tokens.lightboxScrim,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 图片 + 手势区（图上的点击不关闭 —— 图区自己吞掉 tap）。
                LayoutBuilder(
                  builder: (context, constraints) {
                    // max-width: min(78vw, 620px) / max-height: min(72vh, 620px)。
                    final side = math.min(
                      math.min(
                        constraints.maxWidth * 0.78,
                        MediaQuery.sizeOf(context).height * 0.72,
                      ),
                      kLightboxImgMax,
                    );
                    _imgSize = Size(side, side);
                    return GestureDetector(
                      // opaque：图区必须参与命中（SizedBox 里的 CoverImage
                      // 若落生成卡 Painter 分支，deferToChild 也能命中，但
                      // 显式 opaque 不依赖这一点 —— 与 React 的 img 元素
                      // 自带命中同义）。
                      behavior: HitTestBehavior.opaque,
                      onTap: () {}, // 点在图上不关闭（App.tsx:1321-1324）
                      onDoubleTapDown: _onDoubleTap,
                      onDoubleTap: () {},
                      child: ValueListenableBuilder<LightboxView>(
                        valueListenable: _view,
                        builder: (context, view, child) => Transform.translate(
                          offset: Offset(view.offsetX, view.offsetY),
                          child: Transform.scale(
                            scale: view.scale,
                            child: SizedBox(
                              width: side,
                              height: side,
                              child: child,
                            ),
                          ),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(kRadiusXl),
                            border: Border.all(color: tokens.borderStrong),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0xF2000000),
                                offset: Offset(0, 40),
                                blurRadius: 90,
                                spreadRadius: -40,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(kRadiusXl),
                            child: SizedBox(
                              key: _imgKey,
                              child: CoverImage(
                                key: const Key('lightbox-cover'),
                                path: displayPath,
                                artist: track?.artist ?? '',
                                title: track?.title ?? '',
                                size: side,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 关闭按钮：右上 (18,18)，40×40 圆形（app.css:3716-3733）。
                Positioned(
                  top: 18,
                  right: 18,
                  child: Semantics(
                    button: true,
                    label: '关闭大图（Esc）',
                    child: _CloseButton(
                      key: const Key('lightbox-close'),
                      focusNode: _closeFocus,
                      autofocus: true,
                      onTap: widget.onClose,
                    ),
                  ),
                ),
                // caption：13px textDim 居中单行省略（app.css:3706-3714）。
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 32,
                  child: Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: tokens.textDim),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) _onWheel(event);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length >= 2) {
      // 第二根手指落下：从单指拖拽切到双指缩放（App.tsx:1316-1320）。
      _beginPinch();
      return;
    }
    // 1× 时没有可拖的内容，把点击让给「点空白关闭」（App.tsx:1321-1324）。
    if (_view.value.scale <= 1) return;
    _dragPointerId = event.pointer;
    _dragStart = event.position;
    _dragBase = Offset(_view.value.offsetX, _view.value.offsetY);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;

    if (_pinchDistance != null && _pointers.length >= 2) {
      _applyPinch();
      return;
    }
    if (_dragPointerId != event.pointer) return;
    final next = _clampOffset(
      Offset(
        _dragBase.dx + event.position.dx - _dragStart.dx,
        _dragBase.dy + event.position.dy - _dragStart.dy,
      ),
      _view.value.scale,
    );
    _view.value = _view.value.copyWith(
      offsetX: next.dx,
      offsetY: next.dy,
    );
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length >= 2) {
      // 三指变两指等场景：按剩下的两指重新定基准（App.tsx:1376-1380）。
      _beginPinch();
      return;
    }
    _pinchDistance = null;
    _pinchScale = null;
    _pinchCenter = null;
    _pinchLocal = null;

    if (_pointers.length == 1 && _view.value.scale > 1) {
      // 双指松开一根：剩下那根继续平移，不跳回（App.tsx:1383-1395）。
      final entry = _pointers.entries.first;
      _dragPointerId = entry.key;
      _dragStart = entry.value;
      _dragBase = Offset(_view.value.offsetX, _view.value.offsetY);
      return;
    }
    if (_dragPointerId == event.pointer) _dragPointerId = null;
  }
}

/// 关闭按钮：40×40 圆形、`tint2` 底、`borderStrong` 描边（app.css:3716-3733），
/// 按下缩到 0.94（:3739-3741）。tint2 在 token 表里是 `border` 的别名族 ——
/// M2b 用 [AppTokens.progressTrack]（--tint-3）对齐 `--tint-2` 的视觉档
///（三档白里居中的一档，M3 翻表时一起核）。
class _CloseButton extends StatefulWidget {
  const _CloseButton({
    required this.focusNode,
    required this.autofocus,
    required this.onTap,
    super.key,
  });

  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: (node, event) {
            // 空格 / 回车激活（按钮语义；Esc 走 closeOverlay 全局分支）。
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.enter)) {
              widget.onTap();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 40,
            height: 40,
            transformAlignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              _pressed ? 0.94 : 1,
              _pressed ? 0.94 : 1,
              1,
            ),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? tokens.border : tokens.progressTrack,
              border: Border.all(color: tokens.borderStrong),
            ),
            child: Icon(Icons.close, size: 18, color: tokens.text),
          ),
        ),
      ),
    );
  }
}
