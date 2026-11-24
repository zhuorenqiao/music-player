// test/ui/scroll_physics_test.dart
//
// 电台页的软回弹物理：把「快速甩到底」的回弹压浅、放慢，但慢速拖拽到边界
// 的手感不变。这里只量曲线，不挂 widget —— 页面接入见 radio_test.dart。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/ui/scroll_physics.dart';

/// 一个贴在列表末端的滚动度量：pixels 正好等于 maxScrollExtent。
ScrollMetrics _atEnd({double pixels = 1000, double max = 1000}) =>
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: max,
      pixels: pixels,
      viewportDimension: 800,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );

/// 模拟跑 1 秒，取「越过末端最多多少 px」。
double _peakOverscroll(Simulation simulation, double maxExtent) {
  var peak = 0.0;
  for (var t = 0.0; t <= 1.0; t += 0.001) {
    final overscroll = simulation.x(t) - maxExtent;
    if (overscroll > peak) peak = overscroll;
  }
  return peak;
}

void main() {
  test('5000px/s 甩到底：回弹从 122px 压到 60px 以内，首帧也不再跳一大截', () {
    final old = const BouncingScrollPhysics().createBallisticSimulation(
      _atEnd(),
      5000,
    );
    final soft = const SoftBouncingScrollPhysics().createBallisticSimulation(
      _atEnd(),
      5000,
    );
    expect(old, isNotNull);
    expect(soft, isNotNull);

    final oldPeak = _peakOverscroll(old!, 1000);
    final softPeak = _peakOverscroll(soft!, 1000);

    // 现状留档：默认弹簧会冲出 100px 以上（实测 122px），这就是「跳一下」的来源。
    expect(oldPeak, greaterThan(100));
    // 软回弹：同样的力度只冲出 60px 以内（实测 46px）。
    expect(softPeak, lessThan(60));
    expect(softPeak, lessThan(oldPeak));

    // 第一帧（16ms）的位移：默认是 64px 量级，软回弹 21px 量级。
    final oldFirstFrame = old.x(1 / 60) - 1000;
    final softFirstFrame = soft.x(1 / 60) - 1000;
    expect(oldFirstFrame, greaterThan(50));
    expect(softFirstFrame, lessThan(25));
  });

  test('慢速拖过边界再松手：仍然回到末端，不来回荡', () {
    final soft = const SoftBouncingScrollPhysics().createBallisticSimulation(
      _atEnd(pixels: 1030),
      0,
    );
    expect(soft, isNotNull);
    // 过阻尼弹簧：2 秒内稳稳落在末端 1px 以内，且中途不会反向越过 1000。
    expect(soft!.x(2), closeTo(1000, 1));
    var minX = 1030.0;
    for (var t = 0.0; t <= 0.5; t += 0.001) {
      final x = soft.x(t);
      if (x < minX) minX = x;
    }
    expect(minX, greaterThanOrEqualTo(999.5));
  });

  test('applyTo 保留回弹上限（Scrollable 会用祖先默认物理再套一层）', () {
    const soft = SoftBouncingScrollPhysics();
    final applied = soft.applyTo(const ClampingScrollPhysics());
    expect(applied, isA<SoftBouncingScrollPhysics>());
    expect(applied.maxBounceVelocity, soft.maxBounceVelocity);
    expect(applied.parent, isA<ClampingScrollPhysics>());
  });

  test('默认弹簧比软弹簧硬：ω 从 14.1 降到 11.1', () {
    const soft = SoftBouncingScrollPhysics();
    final defaultSpring = const BouncingScrollPhysics().spring;
    expect(soft.spring.stiffness, lessThan(defaultSpring.stiffness));
    expect(soft.spring.mass, defaultSpring.mass);
  });
}
