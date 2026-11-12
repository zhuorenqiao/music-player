// lib/ui/lyrics_view.dart
//
// 歌词列表：对译 React 版 `src/App.tsx:241-318` 的 `LyricsView`（紧凑预览与完整
// 歌词页共用的那一个组件）与 `src/styles/app.css` 的歌词一族：
//   * `.lyrics` / `.lyrics--compact` / `.lyrics--full`：:1826-1838、:1903-1922，
//   * `.lyrics__line` 与 `is-past` / `is-active`：:1924-1946、:2011-2027，
//   * `.lyrics__text` / `.lyrics__trans`：:1949-1983，
//   * 歌词页那一档覆盖（past 0.5、译文 3px/14）：:3039-3063。
//
// 结构上分两层，这是本任务的红线：
//   * [LyricsLinesView] —— **纯展示**，只吃 lines / trans / variant / activeIndex /
//     onSeek / manualHold 这几个标量，不碰任何状态层。测试与预览都用它。
//   * [LyricsView] —— 真实入口，订阅 `LyricsState` / `BilingualState` /
//     `PlayerState.position`，算出 activeIndex 后把剩下的交给前者。
// T18/T19 只用后者；前者让「滚动 / 高亮 / 热区」这些纯 UI 行为能脱离状态层独立测。
//
// 移植时守住的非显而易见点（每条都有用例钉，见 test/ui/lyrics_view_test.dart）：
//
// * **行必须一次性全建出来**（用 `SingleChildScrollView` + `Column`，不是
//   `ListView.builder`）。React 那边是 `cues.map(...)` 把每个 `<li>` 都塞进 DOM
//   （App.tsx:294-315），居中靠 `list.children[activeIndex]` 拿到**任意**一行的
//   offsetTop（:256）。Flutter 的 `ListView.builder` 只构建视口附近的行，
//   远处的行没有 Element，`GlobalKey.currentContext` 是 null，`ensureVisible`
//   静默失效 —— 表现是「跳到后面几行时视图不动」。歌词行数有限（一首歌通常
//   < 200 行），全量构建与 DOM 版本同代价。
//
// * **手动暂停跟随只认用户滚动**（App.tsx:291-292 的 onWheel / onTouchMove）。
//   程序化居中会触发 ScrollStartNotification / ScrollUpdateNotification，若不加
//   区分就会「自己把跟随暂停掉」，当前行永远停在旧位置 —— 所以只认
//   `ScrollStartNotification.dragDetails != null`（触摸拖动）与
//   `PointerScrollEvent`（滚轮），两者之外一律当程序化。用例「程序化居中不算手动」
//   连续换两行，靠的就是这条。
//
// * **滚动条两处都完全不显示、且不占位**。CSS 是 `scrollbar-width: none` +
//   `::-webkit-scrollbar { width: 0 }`（:1893-1900，注释写明「手动滑动也不显示」），
//   连平时透明的槽位都不要。Flutter 的 `scrollbars: false` 只让 ScrollBehavior 不
//   包 `Scrollbar`（material/app.dart:857-876 在 Windows 桌面确实会包），所以还要
//   确认没别的地方塞 Scrollbar；本文件不出现任何 Scrollbar。
//
// * **当前行只换色 + 字重 650，无底色无辉光**（:1943-1946、:1963-1966 的注释
//   「发光会在字周围糊出一团颜色，看着像背景高亮」）。CSS 的 650 在 Flutter 没有
//   对应枚举：用 `FontWeight.w600`（Material 的 600），不用 `FontWeight.lerp` 造
//   非标权重 —— 字重值可以构造成 650，但字体不一定有那一档，渲染结果不可控。
//   译文行**保持 400**（:1980-1983「一行里也要分得出主次」）。
//
// * **不透明度挂在整行上**（CSS 的 `li { opacity: var(--past-opacity) }`），不是
//   乘进颜色。两者对原文等价，但译文自身还带 `.85`，乘进颜色会变成
//   `.62 × .85`，与 CSS 的两层独立合成不是一回事，断言也读不出来。
//
// * **热区只覆盖文字本身**（:1948-1957）。原文与译文都算（译文也 `onClick`，
//   App.tsx:312），行内左右留白不算 —— 所以 GestureDetector 包在文字上、
//   而不是整行；这不是为了省事，是为了留白的点击能冒泡给「进/出歌词页」。
//
// * **纯文本行静态展示**：不高亮、不响应点击（:2004-2008），但**仍然可滚动**
//   （`.lyrics { overflow-y: auto }` 对纯文本一样生效）；空行渲染成 `·`
//   （U+00B7，App.tsx:275 / :309）。纯文本行的 `time` 是 `double.nan`，判有无
//   时间轴只能用 `time.isNaN` / `time.isFinite`，绝不能拿来比较或排序。
//
// * **居中用 Scrollable.ensureVisible(alignment: 0.5)**（App.tsx:258 的
//   `line.offsetTop - (clientHeight - line.clientHeight) / 2`）：首尾会自动夹取，
//   与 React 的 scrollTo 夹取一致。动画 300ms / easeInOut 对应 CSS 的
//   `behavior: 'smooth'`；系统「减少动态效果」时退成零时长（项目既有约定，见
//   ui/lyrics_status.dart 与 ui/transport.dart 的 reduced-motion 一节）。
//
// * **歌词内容一换，滚动位置回到最上方**（换歌 / 同一首的纯文本升级成带时间轴）。
//   滚动视图带的是 const key，元素被复用、偏移留着 —— 不拨回去的话，新歌会停在
//   旧歌滚到的位置（多半是中间），看起来像「歌词没换」。`SingleChildScrollView`
//   自带的匿名控制器够不着位置，所以自己持有一个 `ScrollController`。
//   **瞬时跳、不做动画**：从旧歌中段一路滑到新歌顶部显得拖沓，直接跳更利落。
//   **这一次不做居中**：否则新歌的当前行会立刻把视图从顶部拉走，「回到最上方」
//   根本看不到 —— 下一行变化时照旧跟随。
//
// * **两档规格表逐字**（compact / full）：容器左右 padding 4 / 8，行内边距
//   `6 8` / `12 14`，字号 17 / 19，行高 1.55（继承）/ 1.5，圆角都是 10，译文
//   字号 13 / 14、上间距 1 / 3、行高都 1.45、不透明度 .85。唱过的行 `textDim` +
//   不透明度 compact .62（`--past-opacity`）/ full .5（`--past-opacity-page`）。
//   颜色一律 `context.tokens`，本文件不出现颜色字面量（ui/ 内的规矩）。
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../lyrics/lrc_parser.dart';
import '../state/bilingual_state.dart';
import '../state/lyrics_state.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import '../theme/color_utils.dart';
import '../theme/theme_state.dart';

/// 两档规格：播放卡内（compact）与歌词页（full）。
enum LyricsVariant { compact, full }

/// 当前行滚到中间的动画时长（CSS `behavior: 'smooth'` 的等价物）。
const Duration _kFollowDuration = Duration(milliseconds: 300);

/// 跟随动画的曲线（App.tsx:258 的 smooth 滚动是缓入缓出）。
const Curve _kFollowCurve = Curves.easeInOut;

/// 手动滚动后暂停跟随的默认时长（App.tsx:291-292 的 2600）。
const Duration kLyricsManualHold = Duration(milliseconds: 2600);

/// 空行占位符（App.tsx:275 / :309 的 `text || '·'`）。
const String _kGapGlyph = '·';

/// 一档的规格数值。两档的差异全在这张表里，渲染代码不写死任何一档。
///
/// 数值对表见文件头「两档规格表逐字」那一段（CSS :2011-2027 / :3039-3063）。
class _LyricsMetrics {
  const _LyricsMetrics({
    required this.horizontalPadding,
    required this.linePadding,
    required this.fontSize,
    required this.lineHeight,
    required this.transFontSize,
    required this.transTopGap,
    required this.pastOpacity,
  });

  /// 容器左右 padding（`.lyrics--compact` 4 / `.lyrics--full` 8）。
  final double horizontalPadding;

  /// 行内边距（`.lyrics--compact .lyrics__line` 是 `6 8`，full 是 `12 14`）。
  final EdgeInsets linePadding;

  final double fontSize;

  /// 行高倍数。compact 用 `.lyrics__line` 的 1.55，full 覆盖成 1.5。
  final double lineHeight;

  final double transFontSize;

  /// 译文与原文的间距（`.lyrics__trans` 的 margin-top）。
  final double transTopGap;

  /// 唱过的行的不透明度（compact 0.62 / full 0.5）。
  final double pastOpacity;

  static const _LyricsMetrics compact = _LyricsMetrics(
    horizontalPadding: 4,
    linePadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
    fontSize: 17,
    lineHeight: 1.55,
    transFontSize: 13,
    transTopGap: 1,
    pastOpacity: 0.62,
  );

  static const _LyricsMetrics full = _LyricsMetrics(
    horizontalPadding: 8,
    linePadding: EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    fontSize: 19,
    lineHeight: 1.5,
    transFontSize: 14,
    transTopGap: 3,
    pastOpacity: 0.5,
  );

  static _LyricsMetrics of(LyricsVariant variant) =>
      variant == LyricsVariant.compact ? compact : full;
}

/// 纯展示的歌词列表：测试与预览用，不依赖状态层。
///
/// [trans] 与 [lines] 等长（T14 保证）；不等长时不崩，多出来的忽略、缺的按没有
/// 译文渲染。纯文本行（`time` 为 NaN）静态展示、不高亮、不响应点击。
class LyricsLinesView extends StatefulWidget {
  const LyricsLinesView({
    required this.lines,
    required this.trans,
    required this.variant,
    required this.activeIndex,
    this.onSeek,
    this.manualHold = kLyricsManualHold,
    super.key,
  });

  final List<LyricLine> lines;

  /// 与 [lines] 等长的译文；空串表示这一行没有译文。
  final List<String> trans;

  final LyricsVariant variant;

  /// 当前应高亮的行；-1 表示还没唱到（不滚动、全不高亮）。
  final int activeIndex;

  /// 点文字的回调（秒）。null 表示不可 seek。
  final ValueChanged<double>? onSeek;

  /// 手动滚动后暂停跟随的时长。
  final Duration manualHold;

  @override
  State<LyricsLinesView> createState() => _LyricsLinesViewState();
}

class _LyricsLinesViewState extends State<LyricsLinesView> {
  /// 每行的 GlobalKey：`ensureVisible` 要靠它定位。
  List<GlobalKey> _itemKeys = const [];

  /// 滚动控制器：歌词内容一换要把位置拨回最上方，匿名控制器够不着。
  final ScrollController _scrollController = ScrollController();

  /// 是否处在「手动滚动后暂停跟随」的窗口里。
  ///
  /// React 那边是 `manualUntil` 时间戳 + 每次滚动直接比较 Date.now()（App.tsx:250-255）。
  /// Dart 侧**改用 Timer 置位 / 复位**，语义等价（窗口结束前不跟随；窗口结束后
  /// 下一次 activeIndex 变化照常跟随），但有个实际好处：`DateTime.now()` 不吃
  /// widget test 的假时钟，用时间戳的实现没法用 `tester.pump(Duration)` 拨快，
  /// 「2.6s 到点恢复跟随」那条用例就写不出来。Timer 在 fake async 下是被拨动的。
  Timer? _manualTimer;
  bool _manualHeld = false;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void dispose() {
    _manualTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LyricsLinesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
    // 歌词内容换了（换歌 / 同一首的纯文本升级成带时间轴）：旧歌的滚动位置不能
    // 留给新歌 —— 拨回最上方。判定用**列表身份**：LyricsState 每次重算都造新的
    // displayLines，同一首的行内容没变时身份也不变。
    if (!identical(oldWidget.lines, widget.lines)) {
      _resetToTop();
      // 这一次不做居中：新歌的当前行会立刻把视图从顶部拉走，「回到最上方」就
      // 看不见了。下一行变化时照旧跟随。
      return;
    }
    // 「当前行变了」才滚：构建期不能动滚动位置，排到这一帧之后。
    if (widget.activeIndex != oldWidget.activeIndex) {
      _followIfAllowed();
    }
  }

  /// 把滚动位置拨回最上方（瞬时，不做动画）。
  ///
  /// 排在下一帧：构建期滚动视图还没完成布局，位置还没有像素值。
  void _resetToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasPixels) return;
      position.jumpTo(0);
    });
  }

  /// key 数量跟着行数走（换歌 / 升级纯文本时行数会变）。
  void _syncKeys() {
    if (_itemKeys.length == widget.lines.length) return;
    _itemKeys = [
      for (var i = 0; i < widget.lines.length; i++)
        GlobalKey(debugLabel: 'lyric-$i'),
    ];
  }

  /// 记一次「手动滚动」：从现在起 manualHold 内不跟随。
  ///
  /// 连续的手势（拖动过程里一串 ScrollStartNotification）每次都会重置窗口，
  /// 与 React 每次触发都把 `manualUntil` 往后推一致。
  void _beginManual() {
    _manualHeld = true;
    _manualTimer?.cancel();
    _manualTimer = Timer(widget.manualHold, () {
      _manualHeld = false;
    });
  }

  /// 跟随当前行；手动暂停期内不动。
  ///
  /// 与 App.tsx:251-260 一致：`activeIndex < 0`、没有这一行、或还在手动暂停期内
  /// 都直接返回。真实滚动排在下一帧，避免在构建期改布局。
  void _followIfAllowed() {
    final index = widget.activeIndex;
    if (index < 0 || index >= _itemKeys.length) return;
    if (_manualHeld) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _itemKeys[index].currentContext;
      if (context == null) return;
      // 减少动态效果：不滚动动画，直接跳到位（项目既有约定）。
      final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: reduceMotion ? Duration.zero : _kFollowDuration,
        curve: _kFollowCurve,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _LyricsMetrics.of(widget.variant);
    if (widget.lines.isEmpty) {
      // 空列表什么都不画；状态行负责提示（与 App.tsx:282-284 的空 `<ul>` 等价）。
      return const SizedBox.shrink();
    }
    return ScrollConfiguration(
      // 歌词两处都不显示滚动条、也不占位（CSS :1893-1900）。
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(scrollbars: false, overscroll: false),
      child: Listener(
        // 滚轮：算手动（App.tsx:291 的 onWheel）。
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) _beginManual();
        },
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            // 触摸拖动：算手动（App.tsx:292 的 onTouchMove）。
            // `dragDetails == null` 是程序化滚动（含本文件的居中），绝不能算。
            if (notification.dragDetails != null) _beginManual();
            return false;
          },
          child: SingleChildScrollView(
            key: const Key('lyrics-scroll'),
            // 自己持控制器：换歌时要把位置拨回最上方（见 _resetToTop）。
            controller: _scrollController,
            child: Padding(
              key: const Key('lyrics-content-padding'),
              padding: EdgeInsets.symmetric(
                horizontal: metrics.horizontalPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < widget.lines.length; index++)
                    _buildLine(context, metrics, index),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLine(BuildContext context, _LyricsMetrics metrics, int index) {
    final tokens = context.tokens;
    final line = widget.lines[index];
    // 纯文本行的 time 是 NaN：只能用 isFinite / isNaN 判，不能比较。
    final seekable = line.time.isFinite && widget.onSeek != null;
    // 纯文本整屏都不高亮（:2004-2008）；有时间轴才谈 is-past / is-active。
    final hasTimeline = !line.time.isNaN;
    final isActive = hasTimeline && index == widget.activeIndex;
    final isPast =
        hasTimeline && widget.activeIndex >= 0 && index < widget.activeIndex;
    final trans = index < widget.trans.length ? widget.trans[index] : '';
    final isEmpty = line.text.isEmpty;
    // 空行（`lyrics__line--gap`）不可点（:1990-1997）。
    final canSeek = seekable && !isEmpty;

    // 颜色三档：普通行 textFaint；纯文本行 textDim（:2005-2007）；
    // 唱过的行 textDim + 整行压不透明度；当前行 `--lyric-hl` + 不透明度 1。
    // `--lyric-hl` 缺省跟随 `--accent-light`，用户在「T」色板里选过就换成
    // 那个色（React wave-style.tsx:66-70 / theme.tsx:160-219 的高亮压暗）。
    // 截图里 React 的粉紫高亮正是「玫红」预设；旧实现写死 accentLight，
    // 于是 Flutter 侧永远是薄荷白 —— 这是肉眼最明显的配色差异。
    final theme = context.watch<ThemeState?>();
    final picked = theme?.lyricColor ?? '';
    final Color highlight = picked.isEmpty
        ? tokens.accentLight
        : (() {
            final parsed = parseHexColor(picked);
            if (parsed == null) return tokens.accentLight;
            return tokens.brightness == Brightness.light
                ? highlightOnLight(parsed)
                : parsed;
          })();
    final Color color;
    final double opacity;
    if (isActive) {
      color = highlight;
      opacity = 1;
    } else if (isPast) {
      color = tokens.textDim;
      opacity = metrics.pastOpacity;
    } else if (hasTimeline) {
      color = tokens.textFaint;
      opacity = 1;
    } else {
      color = tokens.textDim;
      opacity = 1;
    }

    // 当前行只换色 + 加粗；译文行保持 400（:1980-1983）。
    final textStyle = TextStyle(
      fontSize: metrics.fontSize,
      height: metrics.lineHeight,
      color: color,
      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
    );

    final Widget mainText = canSeek
        ? GestureDetector(
            // 热区只覆盖文字本身：包文字，不包整行（:1948-1957）。
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSeek!(line.time),
            child: _lineText(textStyle, line.text, isEmpty),
          )
        : _lineText(textStyle, line.text, isEmpty);

    final Widget row = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(child: mainText),
        if (trans.isNotEmpty && !isEmpty)
          Container(
            key: ValueKey('lyric-trans-$index'),
            // margin-top 1 / 3（`.lyrics__trans` 与它在歌词页的覆盖）
            padding: EdgeInsets.only(top: metrics.transTopGap),
            // `width: fit-content; margin: auto`：热区收回文字本身（:1970-1978）。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: canSeek ? () => widget.onSeek!(line.time) : null,
              child: Text(
                trans,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: metrics.transFontSize,
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                  // 不透明度 .85（:1977）；M2a 只有深色一套，浅色那档
                  // (:1986-1988) 等 M3 加主题时再说。
                  color: tokens.textDim.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
      ],
    );

    return KeyedSubtree(
      // 用例点「行内留白」要按这个 key 取整行矩形。
      key: ValueKey('lyric-line-$index'),
      child: Container(
        // 居中定位用：ensureVisible 需要第 index 行的 BuildContext。
        key: _itemKeys[index],
        // 行内边距 6 8 / 12 14；圆角 10（:1924-1930）。当前行不上底色（:1963-1966）。
        padding: metrics.linePadding,
        decoration: null,
        child: Opacity(
          // 压暗只作用于这一行（原文与译文一起，CSS 的 opacity 在 li 上）。
          opacity: opacity,
          child: row,
        ),
      ),
    );
  }

  /// 一行的原文；空行渲染成 `·` 并压到 0.4、放开字距（:1994-1997）。
  Widget _lineText(TextStyle style, String text, bool isEmpty) => Text(
    isEmpty ? _kGapGlyph : text,
    textAlign: TextAlign.center,
    style: isEmpty
        ? style.copyWith(letterSpacing: 4, color: style.color!.withValues(alpha: 0.4))
        : style,
  );
}

/// 真实入口：订阅歌词 / 译文 / 播放进度，算出当前行后交给 [LyricsLinesView]。
///
/// 进度只走 `ValueListenableBuilder` 订阅 position（player_state.dart:8-11 明确
/// 进度不进 ChangeNotifier），别把它接进整棵树的重建。
///
/// **但「只订阅 position」还不够**：progress tick 每秒来 4 次，而
/// [LyricsLinesView] 是「全量构建」的（每行一个 Container + 1~2 个 Text，一行
/// 歌词通常 60~120 行）。每次 tick 都返回一个新的 `LyricsLinesView` 实例，
/// Flutter 就认为整棵歌词树是新的，于是 4Hz 重跑一遍全部行的 build —— 实测在
/// 80 行的完整歌词页上单帧 20~30ms，已经超掉 16.6ms 的整帧预算：表现是歌词页
/// 里拖动窗口、切歌、滚动都发顿，且只在「行数多」时明显。
///
/// 修法不是砍行数（全量构建是居中定位的硬前提，见文件头），而是把「tick」和
/// 「重建」拆开：本 widget 缓存上一次交出去的列表实例，**只有 activeIndex 真的
/// 换了**（或歌词 / 译文换了身份）才造一个新的。`Element.updateChild` 对
/// 「同一个 widget 实例」会直接短路，整棵歌词树因此完全不重建。一句歌词持续
/// 3~5 秒，于是重建从 4Hz 降到「换行时一次」—— 与 CSS 那边只切 `is-active`
/// 类的代价同阶。
class LyricsView extends StatefulWidget {
  const LyricsView({required this.variant, super.key});

  final LyricsVariant variant;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  /// 上一次交出去的列表实例，以及它对应的输入（用来判断能否直接复用）。
  ///
  /// 不用 `int? _cachedIndex` 与 `List<String>? _cachedTrans` 单独存：
  /// 前者与 [_cachedPhase] 同源（相位就是行号的 double 形式），后者每次从
  /// `BilingualState.trans` 取都是一个新 List（未启用时 `List.filled`，
  /// 启用时 `alignTranslation` 的结果），按实例判等永远不成立，存了也不能比。
  Widget? _cachedList;
  double _cachedPhase = double.nan;
  List<LyricLine>? _cachedLines;
  LyricsVariant? _cachedVariant;

  @override
  Widget build(BuildContext context) {
    final lyrics = context.watch<LyricsState>();
    final bilingual = context.watch<BilingualState>();
    final player = context.watch<PlayerState>();
    final lines = lyrics.displayLines;

    return ValueListenableBuilder<double>(
      valueListenable: player.position,
      builder: (context, position, _) {
        // 纯文本行没有时间轴：只把有时间的 cues 喂给 findActiveCue。
        final next = findActiveCue(lyrics.cues, position);
        // 相位 = 行号。行号没变就什么都不用重做 —— 连 `bilingual.trans`
        // 都不该取：它每次都新建一个 List（见类注释）。
        final phase = next.toDouble();

        final cached = _cachedList;
        // 输入全等才复用：返回**同一个 widget 实例**，`Element.updateChild`
        // 会直接短路，整棵歌词树完全不重建（见类注释）。
        //
        // `_seek` 不参与判等：它是本 State 的方法 tear-off，在 State 的整个
        // 生命周期里指向同一个接收者，不可能变；而方法 tear-off 的
        // `identical()` 并不保证为真（Dart 只保证 `==` 成立），拿它判等会让
        // 缓存永远失效 —— 这条在实测里表现为「加了缓存还是 34ms/次」。
        if (cached != null &&
            _cachedPhase == phase &&
            identical(_cachedLines, lines) &&
            _cachedVariant == widget.variant) {
          return cached;
        }

        final built = LyricsLinesView(
          lines: lines,
          trans: bilingual.trans,
          variant: widget.variant,
          activeIndex: next,
          onSeek: _seek,
        );
        _cachedList = built;
        _cachedPhase = phase;
        _cachedLines = lines;
        _cachedVariant = widget.variant;
        return built;
      },
    );
  }

  /// 点歌词 seek 的回调。写成方法（而不是内联闭包）是为了让它的身份在整个
  /// State 生命周期里稳定：内联闭包每次 build 都是新对象，虽然本文件的判等
  /// 已经不用它了，但稳定身份仍然让 `LyricsLinesView` 的 `onSeek` 在
  /// 「真的需要重建」时也不因回调变化而连带重建子层。
  void _seek(double seconds) {
    // 点歌词跳转；seek 落空不影响显示（transport 内部自己报错）。
    if (!mounted) return;
    context.read<PlayerState>().seekTo(seconds);
  }
}
