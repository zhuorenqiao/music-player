// lib/ui/lyric_color_button.dart
//
// 歌词高亮色（M3 T12）：频谱条左端的「T」小按钮，点开 8 预设色板
//（LyricColorButton.tsx:14-23 逐字）。选中的颜色作用于当前行歌词、
// 辉光与单色频谱的色相；第一颗「薄荷」是主题默认（空 = 跟随 accentLight）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/app_tokens.dart';
import '../theme/color_utils.dart';
import '../theme/theme_state.dart';

/// 色板顺序按色相排，默认那颗放最前面（LyricColorButton.tsx:14-23 逐字）。
const List<({String name, String color})> kLyricColorPresets = <({
  String name,
  String color
})>[
  (name: '薄荷（默认）', color: ''),
  (name: '青', color: '#7de3ff'),
  (name: '蓝', color: '#8aa9ff'),
  (name: '紫', color: '#b98cff'),
  (name: '玫红', color: '#ff8fc7'),
  (name: '橙', color: '#ffb066'),
  (name: '金', color: '#ffe066'),
  (name: '白', color: '#f2f7fb'),
];

/// 歌词高亮色的「T」按钮与色板弹层。
class LyricColorButton extends StatefulWidget {
  const LyricColorButton({super.key});

  @override
  State<LyricColorButton> createState() => _LyricColorButtonState();
}

class _LyricColorButtonState extends State<LyricColorButton> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  void _toggle() {
    if (_entry != null) {
      _removeOverlay();
    } else {
      _showPanel();
    }
  }

  void _showPanel() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点面板以外收起（GlassControl.tsx:44-48 同构）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeOverlay,
            ),
          ),
          Positioned(
            left: pos.dx,
            bottom: MediaQuery.sizeOf(context).height - pos.dy + 8,
            child: Material(
              color: Colors.transparent,
              child: _ColorPanel(onClose: _removeOverlay),
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
    return Semantics(
      button: true,
      label: '歌词高亮颜色',
      child: GestureDetector(
        key: _anchorKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tokens.border),
          ),
          child: Text(
            'T',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: tokens.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// 8 预设色板（浅色主题下预览压暗——所见即所得）。
class _ColorPanel extends StatelessWidget {
  const _ColorPanel({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    final resolvedMode = state.resolvedMode;
    return Container(
      width: 176,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.borderStrong),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.sheetA, tokens.sheetB],
        ),
        boxShadow: tokens.shadowCard,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final preset in kLyricColorPresets)
            _Swatch(
              preset: preset,
              selected: state.lyricColor == preset.color,
              onTap: () {
                state.setLyricColor(preset.color);
                onClose();
              },
              resolvedMode: resolvedMode,
            ),
        ],
      ),
    );
  }
}

/// 一颗色板（GlassControl 的按钮语义 + aria-pressed）。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.preset,
    required this.selected,
    required this.onTap,
    required this.resolvedMode,
  });

  final ({String name, String color}) preset;
  final bool selected;
  final VoidCallback onTap;
  final String resolvedMode;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 白色主题下预览跟实际效果一致：浅色自动压暗到白底读得清（所见即所得）。
    final base = preset.color.isEmpty
        ? tokens.accentLight
        : parseHexColor(preset.color)!;
    final display = resolvedMode == 'light' && preset.color.isNotEmpty
        ? highlightOnLight(base)
        : base;
    return Semantics(
      button: true,
      selected: selected,
      label: preset.name,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: preset.name,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: display,
              border: Border.all(
                color: selected ? tokens.accentLight : tokens.borderStrong,
                width: selected ? 2 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
