// lib/core/breakpoints.dart

/// 断点：与 `src/styles/app.css` 的 `@media (max-width: 899px)` /
/// `@media (min-width: 900px)` 一一对应。
abstract final class Breaks {
  /// 桌面双栏布局的起点（含 900）。
  static const double desktop = 900;

  /// 超窄屏（不含 480），控制行需要换行。
  static const double compact = 480;
}

/// 宽 ≥900 走桌面双栏。
bool isDesktop(double width) => width >= Breaks.desktop;

/// 宽 <480 为超窄屏。
bool isUltraCompact(double width) => width < Breaks.compact;

/// 封面圆碟直径，对应 `--cover-size` 的三档取值：
/// - 宽 ≥1180：固定 248px；
/// - 宽 ≥900：`clamp(166px, 18vw, 232px)`；
/// - 其余：`clamp(108px, 24vh, 150px)`。
///
/// [viewportHeight] 省略时按 700 估算（CSS 的 24vh 需要视口高度）。
double kCoverSize(double width, {double? viewportHeight}) {
  if (width >= 1180) return 248;
  if (width >= Breaks.desktop) return _clamp(166, width * 0.18, 232);
  return _clamp(108, (viewportHeight ?? 700) * 0.24, 150);
}

double _clamp(double min, double value, double max) =>
    value < min ? min : (value > max ? max : value);

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
