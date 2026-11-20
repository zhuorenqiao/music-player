import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 开屏页：2 秒，暗色留白排版 —— 左上品牌、大字「听」、一条竖向细线与薄荷绿光点。
///
/// 使用方式：
/// ```dart
/// SplashPage(
///   onCompleted: () => Navigator.of(context).pushReplacementNamed('/home'),
/// );
/// ```
class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    this.duration = const Duration(seconds: 2),
    this.logo,
    this.logoAsset,
    this.logoSize = 38,
    this.title = '流光音乐',
    this.englishTitle = 'LIU GUANG',
    this.heroText = '听',
    this.tagline = '把此刻，交给声音',
    this.onCompleted,
    this.backgroundColor = const Color(0xFF0B0E0D),
    this.textColor = const Color(0xFFF4F1E9),
    this.accentColor = const Color(0xFF2DE6A8),
    this.logoTileColor = const Color(0xFF102223),
    this.logoBarColor = const Color(0xFF2DE6A8),
  });

  /// 动画总时长，默认 2 秒。
  final Duration duration;

  /// 自定义 Logo 组件，优先级最高。
  final Widget? logo;

  /// Logo 图片资源路径，例如 `assets/images/logo.png`。
  final String? logoAsset;

  /// Logo 显示尺寸（正方形边长）。
  final double logoSize;

  /// 品牌名。
  final String title;

  /// 右上角的小号英文。
  final String englishTitle;

  /// 版面中间的大字。
  final String heroText;

  /// 底部文案。
  final String tagline;

  /// 动画播放完（默认 2 秒）后的回调，通常在这里跳转首页。
  final VoidCallback? onCompleted;

  /// 暗色背景。
  final Color backgroundColor;

  /// 浅色文字（由纸白反相而来）。
  final Color textColor;

  /// 点缀色（细线末端的光点、底部短线）。
  final Color accentColor;

  /// Logo 底板颜色（深墨绿方块）。
  final Color logoTileColor;

  /// Logo 声浪柱颜色（薄荷绿）。
  final Color logoBarColor;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus)
      ..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开启“减弱动画”时，直接展示最终状态并结束。
    if (MediaQuery.disableAnimationsOf(context) && !_completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.value = 1;
        _notifyCompleted();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _notifyCompleted();
    }
  }

  void _notifyCompleted() {
    if (_completed) return;
    _completed = true;
    final callback = widget.onCompleted;
    if (callback == null) return;
    // 放到下一帧再回调，避免在动画 tick 中直接发起路由跳转。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  /// 把整体进度 [t]（0~1）映射到 [begin]~[end] 区间并裁剪。
  double _segment(double t, double begin, double end) {
    if (end <= begin) return t >= end ? 1 : 0;
    return ((t - begin) / (end - begin)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // 开屏颜色跟随应用主题；浅色主题下必须把系统栏图标翻成深色，
    // 否则状态栏 / 手势条会是白字白底。
    final lightBackground = widget.backgroundColor.computeLuminance() > 0.4;
    final iconBrightness = lightBackground ? Brightness.dark : Brightness.light;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        statusBarBrightness: lightBackground
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: widget.backgroundColor,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      child: Scaffold(
        backgroundColor: widget.backgroundColor,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                widget.backgroundColor,
                Color.lerp(widget.backgroundColor, widget.accentColor, 0.04)!,
              ],
            ),
          ),
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(28, 22, 28, 26),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scale = (constraints.maxWidth / 334).clamp(0.86, 1.16);
                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => _buildContent(scale),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(double scale) {
    final t = _controller.value;
    final seconds = t * widget.duration.inMilliseconds / 1000.0;
    final heroSize = 152.0 * scale;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBrandRow(t, seconds, scale),
        const Spacer(flex: 3),
        _buildHeroRow(t, heroSize, scale),
        const Spacer(flex: 3),
        _buildFooter(t, scale),
      ],
    );
  }

  Widget _buildBrandRow(double t, double seconds, double scale) {
    final appear = Curves.easeOutCubic.transform(_segment(t, 0.0, 0.26));

    return Opacity(
      opacity: appear,
      child: Transform.translate(
        offset: Offset(0, 6 * (1 - appear)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: widget.logoSize,
              height: widget.logoSize,
              child: _buildLogo(seconds),
            ),
            const SizedBox(width: 11),
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.1,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.4,
                color: widget.textColor,
              ),
            ),
            const Spacer(),
            Text(
              widget.englishTitle,
              style: TextStyle(
                fontSize: 7.5,
                height: 1.1,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.9,
                color: widget.textColor.withValues(alpha: 0.38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroRow(double t, double heroSize, double scale) {
    final reveal = Curves.easeOutCubic.transform(_segment(t, 0.08, 0.44));
    final lineIn = Curves.easeOutCubic.transform(_segment(t, 0.32, 0.55));
    final dotIn = Curves.easeOutBack.transform(_segment(t, 0.50, 0.64));
    final pulse = _segment(t, 0.66, 1.0);
    final dotPulse = 1 + 0.10 * math.max(0.0, math.sin(pulse * 2 * math.pi));

    final lineHeight = heroSize * 0.94;
    final dotSize = 5.5 * scale;

    return SizedBox(
      height: heroSize * 1.1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 大字：从下方轻轻升起。
          Positioned(
            left: 0,
            bottom: 0,
            child: Opacity(
              opacity: reveal,
              child: Transform.translate(
                offset: Offset(0, 22 * (1 - reveal)),
                child: Text(
                  widget.heroText,
                  style: TextStyle(
                    fontSize: heroSize,
                    height: 1.0,
                    fontWeight: FontWeight.w300,
                    color: widget.textColor,
                  ),
                ),
              ),
            ),
          ),
          // 竖向细线 + 末端光点。
          Positioned(
            right: 72 * scale,
            top: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 1.2,
                  height: lineHeight * lineIn,
                  color: widget.textColor.withValues(alpha: 0.20),
                ),
                const SizedBox(height: 10),
                Opacity(
                  opacity: dotIn.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: (0.5 + 0.5 * dotIn) * dotPulse,
                    child: Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.accentColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(double t, double scale) {
    final ruleIn = Curves.easeOutCubic.transform(_segment(t, 0.46, 0.64));
    final tagIn = Curves.easeOutCubic.transform(_segment(t, 0.54, 0.74));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34 * scale * ruleIn,
          height: 2,
          color: widget.accentColor,
        ),
        const SizedBox(height: 13),
        Opacity(
          opacity: tagIn,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - tagIn)),
            child: Text(
              widget.tagline,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                fontWeight: FontWeight.w400,
                letterSpacing: 2.0,
                color: widget.textColor.withValues(alpha: 0.62),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogo(double seconds) {
    final custom = widget.logo;
    if (custom != null) return custom;

    final asset = widget.logoAsset;
    if (asset != null) {
      return Image.asset(
        asset,
        width: widget.logoSize,
        height: widget.logoSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }

    return _SoundWaveLogo(
      size: widget.logoSize,
      seconds: seconds,
      barColor: widget.logoBarColor,
      tileColor: widget.logoTileColor,
    );
  }
}

/// 内置 Logo：深墨绿圆角方块 + 薄荷绿声浪柱，无发光。
class _SoundWaveLogo extends StatelessWidget {
  const _SoundWaveLogo({
    required this.size,
    required this.seconds,
    required this.barColor,
    required this.tileColor,
  });

  final double size;
  final double seconds;
  final Color barColor;
  final Color tileColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SoundWaveLogoPainter(
        seconds: seconds,
        barColor: barColor,
        tileColor: tileColor,
      ),
    );
  }
}

class _SoundWaveLogoPainter extends CustomPainter {
  _SoundWaveLogoPainter({
    required this.seconds,
    required this.barColor,
    required this.tileColor,
  });

  final double seconds;
  final Color barColor;
  final Color tileColor;

  /// 5 根声浪柱的初始高度，比例取自品牌 Logo。
  static const List<double> _barHeights = [0.156, 0.468, 0.787, 0.468, 0.156];

  /// 每根柱子各自的律动周期，起始相位都为 0，静止时与品牌图形一致。
  static const List<double> _barPeriods = [0.85, 0.75, 0.80, 0.75, 0.85];

  /// 两侧短柱摆幅更大，中间长柱更稳。
  static const List<double> _barAmplitudes = [0.24, 0.16, 0.12, 0.16, 0.24];

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final bounds = Offset.zero & size;

    // 深色圆角底板。
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, Radius.circular(side * 0.09)),
      Paint()..color = tileColor,
    );

    // 居中声浪柱。
    final barWidth = side * 0.071;
    final gap = side * 0.085;
    final totalWidth =
        _barHeights.length * barWidth + (_barHeights.length - 1) * gap;
    final startX = (side - totalWidth) / 2;
    final barPaint = Paint()..color = barColor;

    for (var i = 0; i < _barHeights.length; i++) {
      // 两侧柱子与中间柱反向摆动，看起来像真的声浪。
      final oscillation = i == 0 || i == _barHeights.length - 1
          ? -math.sin(seconds * 2 * math.pi / _barPeriods[i])
          : math.sin(seconds * 2 * math.pi / _barPeriods[i]);
      final height =
          side * _barHeights[i] * (1 + _barAmplitudes[i] * oscillation);
      final rect = Rect.fromLTWH(
        startX + i * (barWidth + gap),
        (side - height) / 2,
        barWidth,
        height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth * 0.28)),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SoundWaveLogoPainter oldDelegate) {
    return oldDelegate.seconds != seconds ||
        oldDelegate.barColor != barColor ||
        oldDelegate.tileColor != tileColor;
  }
}
