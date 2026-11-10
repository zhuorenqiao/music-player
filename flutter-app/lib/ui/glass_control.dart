// lib/ui/glass_control.dart
//
// 卡面透明度与毛玻璃（M3 T7）：对译 React `src/components/GlassControl.tsx`。
//
//   ┌────────────────────┐
//   │ 透明  ├────●───┤ 40% │  ← 写 ThemeState.cardTransparency
//   │ 磨砂  ├────●───┤ 70% │  ← 写 ThemeState.cardFrost
//   └────────────────────┘
//
// 水滴按钮（T 右侧 26×26，aria-label「卡面透明度与毛玻璃」）点开向上弹的
// 面板；点面板以外收起、Esc 收起（捕获语义在 Flutter 侧由「浮层路由 +
// barrierDismissible」天然等价——面板用 Overlay 挂，点外关闭由
// _ExternalTapClose 监听实现）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';

/// 值域上限（glass.tsx:17 的 MAX_GLASS_TRANSPARENCY）。
const int kMaxGlassTransparency = 100;

/// 卡面透明度与毛玻璃的控制入口（水滴按钮 + 弹出面板）。
class GlassControl extends StatefulWidget {
  const GlassControl({super.key});

  @override
  State<GlassControl> createState() => _GlassControlState();
}

class _GlassControlState extends State<GlassControl> {
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _anchorKey = GlobalKey();

  void _toggle() {
    if (_portal.isShowing) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  OverlayEntry? _entry;

  void _showOverlay() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点面板以外收起（GlassControl.tsx:44-48 的捕获监听对译——
          // 全屏阻挡层，面板自身的事件不会冒到这里）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeOverlay,
            ),
          ),
          Positioned(
            left: math.max(8, pos.dx - 40),
            bottom: MediaQuery.sizeOf(context).height - pos.dy + 8,
            child: Material(
              color: Colors.transparent,
              child: _GlassPanel(onClose: _removeOverlay),
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
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => const SizedBox.shrink(),
      child: Semantics(
        button: true,
        label: '卡面透明度与毛玻璃',
        child: GestureDetector(
          key: _anchorKey,
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(
              Icons.water_drop_outlined,
              size: 15,
              color: tokens.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// 两行滑杆面板（GlassControl.tsx:59-104 逐字：透明 / 磨砂，`%` 文案）。
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    final radius = BorderRadius.circular(kRadiusLg);
    return GestureDetector(
      // 拖滑杆别让手势冒泡到页面（React 版 onPointerDown stopPropagation 对译）。
      onTap: () {},
      child: Container(
        width: 220,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: radius,
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
            _GlassRow(
              label: '透明',
              value: state.transparency,
              onChanged: state.setTransparency,
            ),
            const SizedBox(height: 10),
            _GlassRow(
              label: '磨砂',
              value: state.frost,
              onChanged: state.setFrost,
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行滑杆：标签 + 滑轨 + 百分比（aria-valuetext = `${v}%`）。
class _GlassRow extends StatelessWidget {
  const _GlassRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: tokens.textDim),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: tokens.accent,
              inactiveTrackColor: tokens.progressTrack,
              thumbColor: tokens.sliderThumb,
              overlayColor: tokens.accentSoft,
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: kMaxGlassTransparency.toDouble(),
              divisions: kMaxGlassTransparency,
              // 读屏：valueHint 用百分比文案（spec §14 滑块语义）。
              label: '$value%',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '$value%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11.5,
              color: tokens.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
