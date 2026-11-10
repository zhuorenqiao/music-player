// test/theme/color_utils_test.dart
//
// M3 T2：highlightOnLight 与颜色工具。黄金值由 node 按 theme.tsx:160-219
// 逐字公式现算（M3 计划「Task 2」节），实现侧任何公式偏差都在这里炸出来。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/color_utils.dart';

void main() {
  group('contrastOnWhite', () {
    test('纯黑 21、纯白（对白底）= 1.0', () {
      expect(contrastOnWhite(const Color(0xFF000000)), closeTo(21, 0.01));
      expect(contrastOnWhite(const Color(0xFFFFFFFF)), closeTo(1.0, 0.001),
          reason: '白对白没有任何对比——这正是浅色主题要压暗高亮色的原因');
    });
    test('黄金值：8 个预设色的原始对比度（node 现算）', () {
      double c(String hex) => contrastOnWhite(parseHexColor(hex)!);
      expect(c('#7de3ff'), closeTo(1.47, 0.005));
      expect(c('#8aa9ff'), closeTo(2.28, 0.005));
      expect(c('#b98cff'), closeTo(2.54, 0.005));
      expect(c('#ff8fc7'), closeTo(2.10, 0.005));
      expect(c('#ffb066'), closeTo(1.80, 0.005));
      expect(c('#ffe066'), closeTo(1.30, 0.005), reason: 'README：金 #ffe066 约 1.3:1');
      expect(c('#f2f7fb'), closeTo(1.08, 0.005));
      expect(c('#4d8dff'), closeTo(3.20, 0.005));
    });
  });

  group('highlightOnLight', () {
    test('8 个预设色的压暗结果逐字（node 现算）', () {
      Color h(String hex) => highlightOnLight(parseHexColor(hex)!);
      expect(toHexString(h('#7de3ff')), '#417685');
      expect(toHexString(h('#8aa9ff')), '#586ca3');
      expect(toHexString(h('#b98cff')), '#8162b2');
      expect(toHexString(h('#ff8fc7')), '#a35c7f');
      expect(toHexString(h('#ffb066')), '#94663b');
      expect(toHexString(h('#ffe066')), '#857435');
      expect(toHexString(h('#f2f7fb')), '#6f7273');
      // 主题三色的浅色档也过一遍（mint/pink/blue 的深色版同样压暗）。
      expect(toHexString(h('#2ee6a8')), '#1b8561');
      expect(toHexString(h('#ff6aa8')), '#b24a76');
      expect(toHexString(h('#4d8dff')), '#3f74d1');
    });

    test('已达标（≥4.5）原样返回', () {
      final dark = parseHexColor('#1b4fae')!; // 浅色蓝的 accent-light，对比度达标
      expect(highlightOnLight(dark), same(dark));
    });

    test('压暗后全部达标 ≥4.5', () {
      for (final hex in const [
        '#7de3ff', '#8aa9ff', '#b98cff', '#ff8fc7', '#ffb066', '#ffe066', '#f2f7fb',
      ]) {
        final out = highlightOnLight(parseHexColor(hex)!);
        expect(contrastOnWhite(out), greaterThanOrEqualTo(4.5),
            reason: '$hex 压暗后应达标');
      }
    });
  });

  group('hex / HSL 往返', () {
    test('parseHexColor：合法 6 位、非法 null、大小写', () {
      expect(parseHexColor('#2ee6a8'), const Color(0xFF2EE6A8));
      expect(parseHexColor('#2EE6A8'), const Color(0xFF2EE6A8));
      expect(parseHexColor('2ee6a8'), isNull);
      expect(parseHexColor('#2ee6a'), isNull);
      expect(parseHexColor(''), isNull);
    });

    test('HSL 往返：主色三例', () {
      void roundTrip(String hex) {
        final c = parseHexColor(hex)!;
        final hsl = colorToHsl(c);
        final back = hslToColor(hsl.h, hsl.s, hsl.l);
        // HSL 往返允许 ±1 的通道舍入误差。
        expect((back.r - c.r).abs(), lessThanOrEqualTo(1), reason: hex);
        expect((back.g - c.g).abs(), lessThanOrEqualTo(1), reason: hex);
        expect((back.b - c.b).abs(), lessThanOrEqualTo(1), reason: hex);
      }

      roundTrip('#2ee6a8');
      roundTrip('#ff6aa8');
      roundTrip('#4d8dff');
      roundTrip('#b9ffe9');
    });

    test('toHexString 格式', () {
      expect(toHexString(const Color(0xFF2EE6A8)), '#2ee6a8');
      expect(toHexString(const Color(0x802EE6A8)), '#2ee6a8', reason: 'alpha 不进 hex');
    });
  });
}
