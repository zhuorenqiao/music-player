// lib/ui/scroll_physics.dart
//
// 电台页专用滚动物理：保留 iOS 那套「橡皮筋 + 弹簧回弹」，只把**撞到底部之后
// 那一段**压软。
//
// 为什么不用裸的 `BouncingScrollPhysics`：
// 它把撞到列表末端时的速度原样交给弹簧，上限 5000 px/s
//（`BouncingScrollSimulation.maxSpringTransferVelocity`）；默认弹簧
// mass 0.5 / stiffness 100 / ratio 1.1（ω≈14.1 rad/s）。于是 5000 px/s 撞边会
// 先冲出 122px、69ms 就弹回来 —— 60fps 下第一帧就位移 64px、第二帧 36px，
// 屏幕上是「啪一下跳到底」，看着像掉帧，其实是回弹太快。
//
// 这里改两处：
//   1. 交给弹簧的速度封顶 [maxBounceVelocity]（默认 1500 = 原上限的 30%）：
//      同样的 5000 px/s 甩到底只冲出 ~46px，不再是 122px；
//   2. 弹簧放软一档（stiffness 100 → 62，ω≈11.1）：顶点从 69ms 推迟到 87ms，
//      首帧速度从 3900 px/s 降到 1200 px/s，每帧位移自己衰减，不再是一帧
//      冲出去一大截；回落到 1px 以内的总时长基本不变（≈0.66s → ≈0.70s）——
//      变的是过程，不是尾巴。
//
// 越界阻力（`applyPhysicsToUserOffset`）、fling 阈值、连续甩动的动量叠加
// 仍沿用 [BouncingScrollPhysics]，所以慢速拖到边界的手感和 iOS 一致；
// 鼠标滚轮根本走不到越界（`ScrollPosition.pointerScroll` 自己夹在
// min/max 之间），桌面端不受影响。
//
// 只在电台页用：其余页面走各平台默认（Android 是 clamping、不回弹），
// React 端整页滚动也一样不回弹 —— 这一页刻意保留 iOS 手感。
//
// 改写自 Flutter 的 `BouncingScrollSimulation`
//（packages/flutter/lib/src/widgets/scroll_simulation.dart，BSD-3-Clause），
// 只加了 `maxBounceVelocity` 与自定义弹簧，其余解析逻辑逐行照搬。
import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// 软回弹滚动物理：iOS 橡皮筋手感 + 更慢、更浅的触边回弹。
class SoftBouncingScrollPhysics extends BouncingScrollPhysics {
  const SoftBouncingScrollPhysics({
    this.maxBounceVelocity = 1500,
    super.decelerationRate,
    super.parent,
  });

  /// 触边后交给弹簧的最大速度（px/s）。
  ///
  /// Flutter 默认是 5000：一次快速甩动到底能冲出 120px 上下。压到 1500 后
  /// 同样力度只冲出 45px 上下 —— 回弹还在，但不再是「撞一下」。
  final double maxBounceVelocity;

  /// 比 Flutter 默认（mass 0.5 / stiffness 100 / ratio 1.1）软一档。
  /// ω = sqrt(62 / 0.5) ≈ 11.1 rad/s；过阻尼 1.1，回弹不来回荡。
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 62,
    ratio: 1.1,
  );

  @override
  SpringDescription get spring => _spring;

  @override
  SoftBouncingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SoftBouncingScrollPhysics(
      maxBounceVelocity: maxBounceVelocity,
      decelerationRate: decelerationRate,
      parent: buildParent(ancestor),
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (velocity.abs() >= tolerance.velocity || position.outOfRange) {
      return _SoftBouncingScrollSimulation(
        spring: spring,
        position: position.pixels,
        velocity: velocity,
        leadingExtent: position.minScrollExtent,
        trailingExtent: position.maxScrollExtent,
        maxBounceVelocity: maxBounceVelocity,
        constantDeceleration: switch (decelerationRate) {
          ScrollDecelerationRate.fast => 1400,
          ScrollDecelerationRate.normal => 0,
        },
        tolerance: tolerance,
      );
    }
    return null;
  }
}

/// [BouncingScrollSimulation] 的改写版：同样的「摩擦滑行 → 撞边 → 弹簧」三段，
/// 区别只有撞边时交给弹簧的速度被封在 [maxBounceVelocity]。
class _SoftBouncingScrollSimulation extends Simulation {
  _SoftBouncingScrollSimulation({
    required double position,
    required double velocity,
    required this.leadingExtent,
    required this.trailingExtent,
    required this.spring,
    required this.maxBounceVelocity,
    double constantDeceleration = 0,
    super.tolerance,
  }) : assert(leadingExtent <= trailingExtent) {
    // 已经越界时（拖过边界再松手）也封顶：甩动时手指速度可以很大，
    // 但越界的位移本来就被橡皮筋压过，回弹不该再按原速弹。
    final double bounceVelocity = velocity.clamp(
      -maxBounceVelocity,
      maxBounceVelocity,
    );
    if (position < leadingExtent) {
      _springSimulation = _underscrollSimulation(position, bounceVelocity);
      _springTime = double.negativeInfinity;
    } else if (position > trailingExtent) {
      _springSimulation = _overscrollSimulation(position, bounceVelocity);
      _springTime = double.negativeInfinity;
    } else {
      // 与 iOS `UIScrollView.decelerationRate = .normal` 同一档：0.998^1000 ≈ 0.135。
      _frictionSimulation = FrictionSimulation(
        _drag,
        position,
        velocity,
        constantDeceleration: constantDeceleration,
      );
      final double finalX = _frictionSimulation.finalX;
      if (velocity > 0.0 && finalX > trailingExtent) {
        _springTime = _frictionSimulation.timeAtX(trailingExtent);
        _springSimulation = _overscrollSimulation(
          trailingExtent,
          math.min(_frictionSimulation.dx(_springTime), maxBounceVelocity),
        );
        assert(_springTime.isFinite);
      } else if (velocity < 0.0 && finalX < leadingExtent) {
        _springTime = _frictionSimulation.timeAtX(leadingExtent);
        _springSimulation = _underscrollSimulation(
          leadingExtent,
          math.max(_frictionSimulation.dx(_springTime), -maxBounceVelocity),
        );
        assert(_springTime.isFinite);
      } else {
        _springTime = double.infinity;
      }
    }
  }

  /// 摩擦阶段的每秒衰减比例（同 Flutter/iOS 的 0.135）。
  static const double _drag = 0.135;

  /// 内容比 minScrollExtent 更靠前时，弹簧回到这里。
  final double leadingExtent;

  /// 内容比 maxScrollExtent 更靠后时，弹簧回到这里。
  final double trailingExtent;

  /// 回弹用的弹簧（由 [SoftBouncingScrollPhysics.spring] 传入）。
  final SpringDescription spring;

  /// 撞边时交给弹簧的速度上限（px/s）。
  final double maxBounceVelocity;

  late FrictionSimulation _frictionSimulation;
  late Simulation _springSimulation;
  late double _springTime;
  double _timeOffset = 0.0;

  Simulation _underscrollSimulation(double x, double dx) =>
      ScrollSpringSimulation(spring, x, leadingExtent, dx);

  Simulation _overscrollSimulation(double x, double dx) =>
      ScrollSpringSimulation(spring, x, trailingExtent, dx);

  Simulation _simulation(double time) {
    final Simulation simulation;
    if (time > _springTime) {
      _timeOffset = _springTime.isFinite ? _springTime : 0.0;
      simulation = _springSimulation;
    } else {
      _timeOffset = 0.0;
      simulation = _frictionSimulation;
    }
    return simulation..tolerance = tolerance;
  }

  @override
  double x(double time) => _simulation(time).x(time - _timeOffset);

  @override
  double dx(double time) => _simulation(time).dx(time - _timeOffset);

  @override
  bool isDone(double time) => _simulation(time).isDone(time - _timeOffset);
}
