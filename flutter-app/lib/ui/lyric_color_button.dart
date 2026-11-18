// lib/ui/lyric_color_button.dart
//
// 歌词外观（M3 T12 + 同步 React 新版「T」面板）：频谱条左端的「T」小按钮，
// 点开是三排 —— 色板 / 字号滑杆 / 字体。对译 React
// `src/components/LyricColorButton.tsx`（工作区里那一版）：
//
//   ┌────────────────────────────────────┐
//   │ ● ● ● ● ● ● ● ●                    │  ← 8 预设色（薄荷=默认）
//   │ A ▁▁▁▁▁▁▁●▁▁▁▁ A      100%         │  ← 字号滑杆 70%~150%，点百分比回 100%
//   │ ─────────────────────────────────  │
//   │ [默认]  [思源宋] [汉仪黑]            │  ← 3 列网格，每颗用它自己的字渲染
//   │ [Noto黑] [等线细] [楷体]             │
//   │ [等宽码] [得意黑] [霞鹜文楷]          │
//   └────────────────────────────────────┘
//
// 三项各自落进 ThemeState（色 / 缩放百分比 / 字体 id），都写进 prefs，下次进来
// 还是上次的设置。选完颜色**不**自动收起（React 版同一个裁定：用户常常接着调
// 字号与字体）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/app_tokens.dart';
import '../theme/color_utils.dart';
import '../theme/lyric_fonts.dart';
import '../theme/theme_state.dart';
import 'tool_panel.dart';

/// 面板宽度：一排 8 颗 18px 色点 + 7 个 8px 缝 + 左右各 10 内边距 = 220
///（React 版面板由内容撑开，宽度恰好落在这一点上）。
const double kLyricColorPanelWidth = 220;

/// 色板顺序按色相排，默认那颗放最前面（LyricColorButton.tsx 的 `PRESETS` 逐字）。
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

/// 歌词外观的「T」按钮与面板。
class LyricColorButton extends StatefulWidget {
  const LyricColorButton({super.key, this.side = ToolPanelSide.above});

  /// 面板往哪边弹：控制条上那排向上，歌词页右上角向下。
  final ToolPanelSide side;

  @override
  State<LyricColorButton> createState() => _LyricColorButtonState();
}

class _LyricColorButtonState extends State<LyricColorButton> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  /// 已进 dispose：展开态要 setState，而 dispose 里也会走 `_removeOverlay`。
  bool _disposed = false;

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
    // 落位交给 toolPanelPosition：控制条那排向上弹，歌词页右上角向下弹。
    final place = toolPanelPosition(
      anchor: pos,
      anchorWidth: box.size.width,
      anchorHeight: box.size.height,
      panelWidth: kLyricColorPanelWidth,
      viewport: MediaQuery.sizeOf(context),
      side: widget.side,
    );
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
            left: place.left,
            top: place.top,
            bottom: place.bottom,
            child: Material(
              color: Colors.transparent,
              child: const _AppearancePanel(),
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

  @override
  void dispose() {
    _disposed = true;
    _removeOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = context.watch<ThemeState?>();
    // 「T」这个字母本身就是**当前高亮色**（React `.lyric-color__trigger:2510-2517`：
    // `font-size: 13px; font-weight: 700; line-height: 1; color: var(--lyric-hl)`），
    // 与歌词当前行同一份算法 —— 改一次色，歌词与按钮一起变。
    final letter = lyricHighlightColor(
      picked: theme?.lyricColor ?? '',
      accentLight: tokens.accentLight,
      brightness: tokens.brightness,
    );
    return Semantics(
      button: true,
      label: '歌词高亮颜色、字号与字体',
      child: GestureDetector(
        key: _anchorKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        // 26×26 / 圆角 8 / 1px border-strong / surface 底：与水滴、闹钟同一套壳。
        child: ToolTriggerChrome(
          active: _entry != null,
          child: Text(
            'T',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1,
              color: letter,
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板本体：色板 / 字号滑杆 / 字体三排。
///
/// 面板里的手势不冒泡到页面（滑切歌 / 点空白返回）—— 外层一个空 onTap 吃掉。
class _AppearancePanel extends StatelessWidget {
  const _AppearancePanel();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final state = context.watch<ThemeState>();
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: kLyricColorPanelWidth,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 8 颗 18px 色点：留白均分（8*18=144，面板内容宽 198~200，缝约 7.7px）。
            // 不用固定 8px 缝：面板有 1px 描边，写死就是溢出。
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < kLyricColorPresets.length; i++)
                  _Swatch(
                    preset: kLyricColorPresets[i],
                    selected: state.lyricColor == kLyricColorPresets[i].color,
                    resolvedMode: state.resolvedMode,
                    // 选完颜色不自动收起（React 版同一句注释）。
                    onTap: () => state.setLyricColor(kLyricColorPresets[i].color),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _SizeRow(
              scale: state.lyricScale,
              onChanged: state.setLyricScale,
              onReset: () => state.setLyricScale(kLyricScaleDefault),
            ),
            const SizedBox(height: 8),
            _FontGrid(
              fontId: state.lyricFont.id,
              onSelect: state.setLyricFont,
            ),
          ],
        ),
      ),
    );
  }
}

/// 字号那一行：小 A — 滑杆 — 大 A — 百分比读数（读数本身就是「回默认」按钮）。
class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.scale,
    required this.onChanged,
    required this.onReset,
  });

  final int scale;
  final ValueChanged<int> onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDefault = scale == kLyricScaleDefault;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          // 两端的 A 大小不同，直观示意「往左缩小 / 往右放大」。
          Text(
            'A',
            style: TextStyle(
              fontSize: 10,
              height: 1,
              fontWeight: FontWeight.w700,
              color: tokens.textDim,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: SliderTheme(
              // 原生 range 的视觉参数：4px 轨、12px 白心强调描边拇指、无 overlay。
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: tokens.accent,
                inactiveTrackColor: tokens.progressTrack,
                thumbColor: tokens.sliderThumb,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 6,
                  disabledThumbRadius: 6,
                ),
                trackShape: const RectangularSliderTrackShape(),
                // 有 divisions 时默认会沿轨道画一排圆点刻度（像刻度尺）；
                // A—A 这根是连续可拖的字号条，不要刻度点，轨道保持一整条。
                tickMarkShape: SliderTickMarkShape.noTickMark,
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: const Key('lyric-scale-slider'),
                value: scale.toDouble(),
                min: kLyricScaleMin.toDouble(),
                max: kLyricScaleMax.toDouble(),
                divisions: (kLyricScaleMax - kLyricScaleMin) ~/ kLyricScaleStep,
                label: '$scale%',
                onChanged: (value) => onChanged(value.round()),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            'A',
            style: TextStyle(
              fontSize: 14,
              height: 1,
              fontWeight: FontWeight.w700,
              color: tokens.textDim,
            ),
          ),
          const SizedBox(width: 7),
          _ResetButton(scale: scale, isDefault: isDefault, onReset: onReset),
        ],
      ),
    );
  }
}

/// 百分比读数：非默认值时带强调色（点一下回到 100%）。
class _ResetButton extends StatelessWidget {
  const _ResetButton({
    required this.scale,
    required this.isDefault,
    required this.onReset,
  });

  final int scale;
  final bool isDefault;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: isDefault ? '歌词字号 $scale%，当前为默认' : '歌词字号 $scale%，点击恢复默认',
      child: GestureDetector(
        key: const Key('lyric-scale-reset'),
        behavior: HitTestBehavior.opaque,
        onTap: isDefault ? null : onReset,
        child: Container(
          constraints: const BoxConstraints(minWidth: 34),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: isDefault ? Colors.transparent : tokens.accentSoft,
            border: Border.all(
              color: isDefault ? Colors.transparent : tokens.accentLine,
            ),
          ),
          child: Text(
            '$scale%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 10.5,
              color: isDefault ? tokens.textDim : tokens.accentLight,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// 字体那一排：3 列等宽网格（9 款正好三行），上面一条极淡的分隔线。
class _FontGrid extends StatelessWidget {
  const _FontGrid({required this.fontId, required this.onSelect});

  final String fontId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 1, color: tokens.border),
        const SizedBox(height: 8),
        for (var row = 0; row < 3; row++) ...[
          if (row > 0) const SizedBox(height: 5),
          Row(
            children: [
              for (var col = 0; col < 3; col++) ...[
                if (col > 0) const SizedBox(width: 5),
                Expanded(
                  child: _FontButton(
                    font: kLyricFonts[row * 3 + col],
                    selected: fontId == kLyricFonts[row * 3 + col].id,
                    onTap: () => onSelect(kLyricFonts[row * 3 + col].id),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 一颗字体按钮：用它自己的字体渲染名字（选哪颗两处歌词都换成那颗字）。
class _FontButton extends StatelessWidget {
  const _FontButton({
    required this.font,
    required this.selected,
    required this.onTap,
  });

  final LyricFontOption font;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      selected: selected,
      label: '歌词字体：${font.name}（${font.hint}）',
      child: GestureDetector(
        key: Key('lyric-font-${font.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Tooltip(
          message: '${font.name} · ${font.hint}',
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 3, 4, 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: selected ? tokens.accentSoft : tokens.surface,
              border: Border.all(
                color: selected ? tokens.accentLine : tokens.border,
              ),
            ),
            child: Text(
              font.name,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              // 名字用这颗字自己的字体渲染（默认那款回落到界面字体）。
              style: applyLyricFont(
                TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: selected ? tokens.accentLight : tokens.textDim,
                ),
                font,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一颗色板（浅色主题下预览压暗，所见即所得）。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.preset,
    required this.selected,
    required this.resolvedMode,
    required this.onTap,
  });

  final ({String name, String color}) preset;
  final bool selected;
  final String resolvedMode;
  final VoidCallback onTap;

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
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: display,
              // 选中态：外描一圈强调色（CSS 的 box-shadow 环）。
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
