// lib/core/breakpoints.dart

/// 断点：与 `src/styles/app.css` 的媒体查询一一对应。
abstract final class Breaks {
  /// 桌面双栏布局的起点（含 900）：`@media (min-width: 900px)`。
  static const double desktop = 900;

  /// 超窄屏（不含 480），控制行需要换行：`@media (max-width: 479px)`。
  static const double compact = 480;

  /// 大屏（含 1280）：沉浸模式把播放列表放回左列、整页上限放宽到 1360
  /// （`@media (min-width: 1280px)`，app.css:4980-5057）。
  static const double wide = 1280;

  /// 满宽档（含 1680）：整页上限 1680、边距 28/32/32、歌词阅读列 800
  /// （`@media (min-width: 1680px)`，app.css:5059-5110）。
  static const double ultra = 1680;

  /// 封面加档的起点（含 1180）：`@media (min-width: 1180px) { --cover-size: 248px }`
  /// （app.css:4980-4996）—— 这一档只抬封面，不动骨架。
  static const double wideCover = 1180;
}

/// 宽 ≥900 走桌面双栏。
bool isDesktop(double width) => width >= Breaks.desktop;

/// 宽 <480 为超窄屏。
bool isUltraCompact(double width) => width < Breaks.compact;

/// 宽 ≥1280 为大屏：沉浸模式左列常驻播放列表。
bool isWide(double width) => width >= Breaks.wide;

/// 宽 ≥1680 为满宽档。
bool isUltraWide(double width) => width >= Breaks.ultra;

/// 内容最大宽度三档：`.app { max-width }` 在 1180 / 1360 / 1680 之间跳。
double contentMaxWidth(double viewportWidth) {
  if (viewportWidth >= Breaks.ultra) return 1680;
  if (viewportWidth >= Breaks.wide) return 1360;
  return 1180;
}

/// 沉浸模式下左列（播放列表）的宽度：`clamp(300px, 26vw, 400px)`
/// （app.css:5015-5018 的 `--panel-width`）。
double lyricsDockedPanelWidth(double viewportWidth) =>
    _clamp(300, viewportWidth * 0.26, 400);

/// 封面圆碟直径，对应 `--cover-size` 的四档取值：
/// - 宽 ≥1680：固定 288px（app.css:5102-5104）；
/// - 宽 ≥1280：固定 268px（app.css:5054-5056）；
/// - 宽 ≥1180：固定 248px（app.css:4980-4996）；
/// - 宽 ≥900：`clamp(166px, 18vw, 232px)`；
/// - 其余：`clamp(108px, 24vh, 150px)`。
///
/// 桌面端（≥900）`.stage__cover-wrap` 还有一道高度上限
/// `width: min(var(--cover-size), 46vh, 340px)`，所以给了 [viewportHeight]
/// 时结果是 `min(基准值, 0.46 * viewportHeight, 340)`；不给则按视口充足处理，
/// 只返回基准值（与改动前的行为一致）。`<900` 分支没有这条上限。
///
/// [viewportHeight] 省略时按 700 估算（CSS 的 24vh 需要视口高度）。
double kCoverSize(double width, {double? viewportHeight}) {
  if (width >= Breaks.ultra) {
    return _capByHeight(288, viewportHeight, width);
  }
  if (width >= Breaks.wide) {
    return _capByHeight(268, viewportHeight, width);
  }
  if (width >= Breaks.wideCover) {
    return _capByHeight(248, viewportHeight, width);
  }
  if (width >= Breaks.desktop) {
    return _capByHeight(_clamp(166, width * 0.18, 232), viewportHeight, width);
  }
  return _clamp(108, (viewportHeight ?? 700) * 0.24, 150);
}

/// 播放卡里歌词块的宽度上限：`.stage__lyrics { max-width }` 的三档
/// （app.css:4955-4957 / :5050-5052 / :5084-5086）。
///
/// 宽 <900 没有上限（返回 null）：手机单栏那档歌词本来就该铺满。
/// 桌面不设上限的话，1920 上歌词会横着摊到 1200 多像素，与封面那列完全不成比例。
double? stageLyricsMaxWidth(double viewportWidth) {
  if (viewportWidth >= Breaks.ultra) return 620;
  if (viewportWidth >= Breaks.wide) return 520;
  if (viewportWidth >= Breaks.desktop) return 460;
  return null;
}

/// 桌面端的 `min(value, 46vh, 340px)`；[viewportHeight] 缺省或宽 <900 时原样返回。
double _capByHeight(double value, double? viewportHeight, double width) {
  if (viewportHeight == null || width < Breaks.desktop) return value;
  return _min(_min(value, viewportHeight * 0.46), 340);
}

double _clamp(double min, double value, double max) =>
    value < min ? min : (value > max ? max : value);

double _min(double a, double b) => a < b ? a : b;

/// 控制行圆钮直径：`.controls > .btn { width: 40px; height: 40px }`。
const double kButtonSize = 40;

/// 最小触控尺寸：`.btn { min-height: 44px }`。
const double kTouchTarget = 44;

/// `--radius-xl: 24px`
const double kRadiusXl = 24;

/// `--radius-lg: 16px`
const double kRadiusLg = 16;

/// `--radius-md: 12px`
const double kRadiusMd = 12;

/// 进度条拖拽圆点的命中直径。
const double kTrackThumb = 44;
