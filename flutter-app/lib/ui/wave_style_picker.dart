// lib/ui/wave_style_picker.dart
//
// 歌词页右上角的波形样式下拉（M3 D.4）：对译 React
// `src/components/WaveStylePicker.tsx` 与 `app.css:2101-2317`。
//
// 结构逐块对齐：
//   * 触发按钮：波形图标 + 当前样式名 + 下拉箭头，读屏名「波形样式：X」；
//   * 面板常驻 Overlay、靠显示/隐藏切换 —— 与原版「面板常驻 DOM、用 hidden
//     收起」的理由相同（省掉每次展开重画 17 张缩略图的开销）；
//   * 固定头部：「彩色」+ 34×20 胶囊开关（role=switch）；
//   * 可滚动列表：17 个选项，每个「76×28 静态缩略图 + 样式名 + 选中勾」，
//     缩略图走 `renderWaveThumb`（与 WaveStrip 同一套渲染器，图不对不了版）；
//   * 键盘：↑↓/Home/End 移动高亮、Enter/空格选中、Esc 退回触发按钮。
//     **这几个键必须被本层消费掉**，否则会顺手把音量改了、甚至把歌词页
//     一起关掉（App.tsx 的 Esc 是「退出歌词页」，上下键是「调音量」）。
//
// 一个有意差异：原版用 `aria-activedescendant` + 焦点留在 listbox 上；Flutter
// 没有等价的语义挂法，改为给列表挂一个 `Focus` + `onKeyEvent`，把按键在
// 本层截断（回调返回 KeyEventResult.handled），焦点仍在触发按钮上。可观察
// 行为一致：高亮随方向键走、Enter 选中、Esc 收起且不冒泡到全局快捷键层。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';
import '../wave/wave_styles.dart';
import '../wave/wave_thumb.dart';

/// 面板宽度（`.wave-style__panel { width: 219px }`，app.css:2160）。
const double kWaveStylePanelWidth = 219;

/// 面板最大高度（`max-height: min(360px, 58vh)`，app.css:2162）。
const double kWaveStylePanelMaxHeight = 360;

/// 缩略图尺寸（`wave-thumb.ts:16-17`，与 `kThumbWidth/Height` 同源）。
const double _kThumbW = kThumbWidth;
const double _kThumbH = kThumbHeight;

/// 歌词页右上角的波形样式下拉入口。
class WaveStylePicker extends StatefulWidget {
  const WaveStylePicker({super.key});

  @override
  State<WaveStylePicker> createState() => _WaveStylePickerState();
}

class _WaveStylePickerState extends State<WaveStylePicker> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  /// 键盘高亮的选项下标（打开时先对齐到当前选中项）。
  int _active = 0;

  bool get _open => _entry != null;

  void _toggle() {
    if (_open) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    // 打开时把高亮对齐到当前样式（React: setActive(currentIndex)）。
    // 可空 read：纯展示测试没注册 ThemeState 时按钮本身就不渲染，不会走到这。
    final theme = context.read<ThemeState?>();
    if (theme == null) return;
    _active = math.max(
      0,
      kWaveStyles.indexWhere((s) => s.id == theme.waveStyleId),
    );
    final pos = box.localToGlobal(Offset.zero);
    final anchorSize = box.size;
    // 面板右对齐触发按钮、贴在其下方 8px（app.css:2153-2155）。
    final screenW = MediaQuery.sizeOf(context).width;
    final left = math.max(
      8.0,
      math.min(screenW - kWaveStylePanelWidth - 8, pos.dx + anchorSize.width - kWaveStylePanelWidth),
    );
    final top = pos.dy + anchorSize.height + 8;
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点面板以外任何地方收起（React 的 document pointerdown 捕获监听
          // 对译）。全屏阻挡层，面板自身的事件不会冒到这里。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeOverlay,
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: _WaveStylePanel(
                active: _active,
                onActiveChanged: (i) {
                  if (!mounted) return;
                  setState(() => _active = i);
                  _entry?.markNeedsBuild();
                },
                onChoose: (i) {
                  // 与上面同一套空安全写法：纯展示测试没注册 ThemeState 时
                  // 这一层根本不会被点开。
                  context.read<ThemeState?>()?.setWaveStyle(kWaveStyles[i].id);
                  _removeOverlay();
                },
                onClose: _removeOverlay,
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {}); // 触发按钮的箭头要翻转
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // **可空 watch**：纯展示 / 旧用例没注册 ThemeState 时不画这颗按钮
    // （与歌词/封面/睡眠定时器那几处同一套容错模式），否则歌词页的既有
    // widget 测试会整屏红。生产里 app.dart 的 MultiProvider 一直挂着它。
    final theme = context.watch<ThemeState?>();
    if (theme == null) return const SizedBox.shrink();
    final current = findWaveStyle(theme.waveStyleId);
    return Semantics(
      button: true,
      label: '波形样式：${current.name}',
      child: GestureDetector(
        key: _anchorKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Container(
          key: const Key('wave-style-trigger'),
          height: 36,
          padding: const EdgeInsets.only(left: 8, right: 10),
          decoration: BoxDecoration(
            color: tokens.tint1,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tokens.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq, size: 16, color: tokens.textDim),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 8 * 12.5),
                child: Text(
                  current.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: tokens.textDim),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 13,
                color: tokens.textDim.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下拉面板：固定头部（彩色开关）+ 17 项可滚动列表。
class _WaveStylePanel extends StatelessWidget {
  const _WaveStylePanel({
    required this.active,
    required this.onActiveChanged,
    required this.onChoose,
    required this.onClose,
  });

  final int active;
  final ValueChanged<int> onActiveChanged;
  final ValueChanged<int> onChoose;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = context.watch<ThemeState>();
    final currentIndex = math.max(
      0,
      kWaveStyles.indexWhere((s) => s.id == theme.waveStyleId),
    );
    final maxHeight = math.min(
      kWaveStylePanelMaxHeight,
      MediaQuery.sizeOf(context).height * 0.58,
    );
    return GestureDetector(
      // 面板内的手势别冒泡到页面（歌词页的空白点击 = 关闭）。
      onTap: () {},
      child: Container(
        width: kWaveStylePanelWidth,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
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
            _Head(
              colored: theme.colored,
              onColoredChanged: theme.setColored,
              tokens: tokens,
              onClose: onClose,
            ),
            Flexible(
              child: _StyleList(
                active: active,
                currentIndex: currentIndex,
                colored: theme.colored,
                accent: tokens.accent,
                lyricColor: theme.lyricColor,
                tokens: tokens,
                onActiveChanged: onActiveChanged,
                onChoose: onChoose,
                onClose: onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 固定头部：`.wave-style__head` + 34×20 的彩色胶囊开关。
class _Head extends StatelessWidget {
  const _Head({
    required this.colored,
    required this.onColoredChanged,
    required this.tokens,
    required this.onClose,
  });

  final bool colored;
  final ValueChanged<bool> onColoredChanged;
  final AppTokens tokens;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        // CSS 是 `--tint-2`；Flutter token 表只留了 tint1 与 progressTrack
        // (`--tint-3`) 两档，用 tint1 的淡版等价替代。
        border: Border(
          bottom: BorderSide(color: tokens.tint1.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Text(
            '彩色',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              color: tokens.textDim,
            ),
          ),
          const Spacer(),
          Semantics(
            toggled: colored,
            label: '波形彩色',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onColoredChanged(!colored),
              child: Container(
                key: const Key('wave-color-switch'),
                width: 34,
                height: 20,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: colored ? tokens.accentSoft : tokens.progressTrack,
                  border: Border.all(
                    color: colored ? tokens.accentLine : tokens.borderStrong,
                  ),
                ),
                alignment:
                    colored ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colored ? tokens.accentLight : tokens.sliderThumb,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 17 项列表：键盘导航 + 缩略图。
class _StyleList extends StatefulWidget {
  const _StyleList({
    required this.active,
    required this.currentIndex,
    required this.colored,
    required this.accent,
    required this.lyricColor,
    required this.tokens,
    required this.onActiveChanged,
    required this.onChoose,
    required this.onClose,
  });

  final int active;
  final int currentIndex;
  final bool colored;
  final Color accent;
  final String lyricColor;
  final AppTokens tokens;
  final ValueChanged<int> onActiveChanged;
  final ValueChanged<int> onChoose;
  final VoidCallback onClose;

  @override
  State<_StyleList> createState() => _StyleListState();
}

class _StyleListState extends State<_StyleList> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 面板打开后把焦点挪到列表（React 的 rAF → listRef.focus() 对译）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _moveActive(int next) {
    final clamped = next.clamp(0, kWaveStyles.length - 1);
    widget.onActiveChanged(clamped);
    // 滚动到可见区（React itemRefs[clamped].scrollIntoView 的等价）。
    final itemH = _kThumbH + 10; // 行内 padding 5+5
    final offset = clamped * (itemH + 2) - 2;
    if (_scroll.hasClients) {
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveActive(widget.active + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveActive(widget.active - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _moveActive(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _moveActive(kWaveStyles.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onChoose(widget.active);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      widget.onClose();
      return KeyEventResult.ignored; // Tab 仍可正常移焦
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(5, 4, 5, 6),
        itemCount: kWaveStyles.length,
        itemExtent: _kThumbH + 10 + 2, // padding(5+5) + gap 2
        itemBuilder: (context, i) {
          final style = kWaveStyles[i];
          final selected = i == widget.currentIndex;
          final active = i == widget.active;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onChoose(i),
            child: MouseRegion(
              onHover: (_) => widget.onActiveChanged(i),
              child: Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: active ? tokens.progressTrack : null,
                  border: Border.all(
                    color: selected
                        ? tokens.accentLine
                        : (active
                            ? tokens.borderStrong
                            : Colors.transparent),
                  ),
                  gradient: selected
                      ? LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            tokens.accentSoft,
                            tokens.accentSoft.withValues(alpha: 0.02),
                          ],
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    RepaintBoundary(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CustomPaint(
                          size: const Size(_kThumbW, _kThumbH),
                          painter: _ThumbPainter(
                            style: style,
                            colored: widget.colored,
                            accent: widget.accent,
                            lyricColor: widget.lyricColor,
                            background: tokens.tint1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        style.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: selected || active
                              ? tokens.text
                              : tokens.textDim,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 16,
                      child: selected
                          ? Icon(Icons.check, size: 15, color: tokens.accent)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 静态缩略图 painter：把 `renderWaveThumb` 包进 CustomPaint。
///
/// 面板常驻、每次展开不重画 —— painter 是 const 参数化的，
/// `shouldRepaint` 只在 colored / accent / lyricColor 真的变了才返回 true。
class _ThumbPainter extends CustomPainter {
  const _ThumbPainter({
    required this.style,
    required this.colored,
    required this.accent,
    required this.lyricColor,
    required this.background,
  });

  final WaveStyle style;
  final bool colored;
  final Color accent;
  final String lyricColor;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background,
    );
    renderWaveThumb(
      canvas: canvas,
      size: size,
      style: style,
      colored: colored,
      accent: accent,
      lyricColor: lyricColor,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) =>
      old.style.id != style.id ||
      old.colored != colored ||
      old.accent != accent ||
      old.lyricColor != lyricColor ||
      old.background != background;
}
