// test/ui/glass_frost_test.dart
//
// 磨砂玻璃层（对译 app.css:449-455 的 `backdrop-filter`）：
//   blur(calc(16px + frost*26px)) saturate(calc(100% + frost*65%))
//
// 这里钉住的是**滤镜真的接上了**，而不只是「代码长得像」：
// 旧实现把 saturate 写成返回透明色的空占位，模糊之后的饱和度提升实际没有
// 发生（颜色发灰），而测试和视觉都没发现。现在断言 BackdropFilter 的
// filter 是一个 compose(outer: 饱和度矩阵, inner: blur) 的组合。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/glass_frost.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

/// 取当前树里唯一的 BackdropFilter。
BackdropFilter _backdrop(WidgetTester tester) =>
    tester.widget<BackdropFilter>(find.byType(BackdropFilter));

void main() {
  testWidgets('frost=0 时不挂磨砂层（零开销，原样返回 child）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const GlassFrostLayer(
          coverPath: '',
          frostLevel: 0,
          child: SizedBox(key: Key('inner'), width: 10, height: 10),
        ),
      ),
    );
    expect(find.byKey(const Key('inner')), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('frost>0 时 backdrop 是 blur 与 saturate 的组合（saturate 不再是空实现）', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        GlassFrostLayer(
          coverPath: '',
          frostLevel: 0.5,
          child: const SizedBox(key: Key('inner'), width: 200, height: 200),
        ),
      ),
    );
    await tester.pump();

    final filter = _backdrop(tester).filter;
    // 组合滤镜的 toString 会带上两个组成部件；模糊与饱和度都要在里面。
    final desc = filter.toString();
    expect(desc, contains('blur'));
    // ColorFilter.saturation 的矩阵不是 identity：顶层必须出现 matrix 项。
    expect(desc, contains('matrix'));

    // 逐字核对强度：frost=0.5 → blur 16+13=29、saturate 1+0.325=1.325。
    expect(desc, contains('29.0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('frost 越大模糊越强（强度按公式线性增长）', (tester) async {
    Future<String> descAt(double frost) async {
      await tester.pumpWidget(
        wrap(
          GlassFrostLayer(
            coverPath: '',
            frostLevel: frost,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      );
      await tester.pump();
      return _backdrop(tester).filter.toString();
    }

    // frost=1 → blur 16+26=42。
    final full = await descAt(1.0);
    expect(full, contains('42.0'));
    // frost=0.25 → blur 16+6.5=22.5。
    final quarter = await descAt(0.25);
    expect(quarter, contains('22.5'));
  });

  testWidgets('frost 越界值被夹到 [0,1]', (tester) async {
    await tester.pumpWidget(
      wrap(
        GlassFrostLayer(
          coverPath: '',
          frostLevel: 2.5, // 夹成 1.0 → blur 42
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pump();
    expect(_backdrop(tester).filter.toString(), contains('42.0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容画在最上层：frost>0 时卡片内容不被封面垫 / 膜层盖住', (tester) async {
    // 回归：早期实现把 child 放在 Stack 首位（最底），封面垫与膜层压在它
    // 上面 —— frost 一开整卡只剩一团模糊封面，文字全被糊死（真机截图确认）。
    // CSS 里 .glass-frost 是 z-index:-2、.player::before 是 z-index:-1，
    // 两者都在卡面内容之下（app.css:461-489）。
    await tester.pumpWidget(
      wrap(
        const GlassFrostLayer(
          coverPath: '',
          frostLevel: 1,
          child: SizedBox(key: Key('content'), width: 200, height: 200),
        ),
      ),
    );
    await tester.pump();

    final stack = tester.widget<Stack>(find.byType(Stack).first);
    // 内容必须是 Stack 的最后一个 child（最后画 = 最上层）。
    expect(stack.children.last, isA<SizedBox>());
    expect(
      (stack.children.last as SizedBox).key,
      const Key('content'),
      reason: '内容必须在封面垫与磨砂膜之后入栈，否则会被盖住',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('有封面路径但文件不存在时不崩（errorBuilder 兜底）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const GlassFrostLayer(
          coverPath: 'C:/__no_such_dir__/nope.jpg',
          frostLevel: 0.6,
          child: SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---- M4：按 CSS 层序重建玻璃栈 --------------------------------------------
  //
  // 旧实现的层序是「底色雾 + 膜 → 再压上卡面渐变」，磨砂调满也看不见；
  // React 的负 z-index 子节点画在**背景之上、内容之下**，正确层序是
  // 卡面渐变 → 色雾 → 膜 → 高光 → 内容。
  group('玻璃层序（CSS 负 z-index 的同序）', () {
    test('角度换算：165deg ≈ 几乎竖直、略偏左下→右上', () {
      final axis = cssGradientAxis(165);
      // d = (sin165, -cos165) = (0.2588, 0.9659)
      expect(axis.begin.x, closeTo(-0.2588, 0.001));
      expect(axis.begin.y, closeTo(-0.9659, 0.001));
      expect(axis.end.x, closeTo(0.2588, 0.001));
      expect(axis.end.y, closeTo(0.9659, 0.001));
      // 90deg 是「朝右」：begin 在左、end 在右，y 不变
      final right = cssGradientAxis(90);
      expect(right.begin.x, closeTo(-1, 1e-9));
      expect(right.end.x, closeTo(1, 1e-9));
      expect(right.begin.y, closeTo(0, 1e-9));
    });

    testWidgets('卡面渐变画在色雾与磨砂膜之下，内容在最上', (tester) async {
      await tester.pumpWidget(
        wrap(
          GlassFrostLayer(
            coverPath: 'C:/__no_such_dir__/nope.jpg',
            frostLevel: 0.8,
            glassLevel: 0.5,
            colorA: AppTokens.dark.cardA,
            colorB: AppTokens.dark.cardB,
            gradientDegrees: 165,
            child: const SizedBox(key: Key('content'), width: 200, height: 200),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final stack = tester.widget<Stack>(find.byType(Stack).first);
      final kids = stack.children;
      // 内容仍是最后一个子节点（最上层）
      expect(kids.last, isA<SizedBox>());
      expect((kids.last as SizedBox).key, const Key('content'));

      // 装饰层（卡面渐变/色雾/膜/高光）整体压在内容之下，而且必须自成一块
      // RepaintBoundary：不隔开的话，内容每帧重绘都会把 card 上的背景模糊
      // （BackdropFilter）重算一次，核显机型上播放/滚动/缩放全卡。
      expect(kids.first, isA<Positioned>(), reason: '装饰层应是铺满的 Positioned');
      final decor = (kids.first as Positioned).child!;
      expect(decor, isA<RepaintBoundary>(), reason: '静态装饰层要单独栅格化');
      final decorStack = (decor as RepaintBoundary).child! as Stack;
      final inner = decorStack.children;

      // 卡面渐变（DecoratedBox）必须排在磨砂膜（CustomPaint）之前 = 更底层
      int indexOfDecorated() => inner.indexWhere(
        (c) => c is Positioned && c.child is DecoratedBox &&
            (c.child as DecoratedBox).decoration is BoxDecoration &&
            ((c.child as DecoratedBox).decoration as BoxDecoration).gradient != null,
      );
      int indexOfMembrane() => inner.indexWhere(
        (c) => c is Positioned &&
            c.child is IgnorePointer &&
            (c.child as IgnorePointer).child is Opacity &&
            ((c.child as IgnorePointer).child as Opacity).child is RepaintBoundary,
      );
      final face = indexOfDecorated();
      final membrane = indexOfMembrane();
      expect(face, greaterThanOrEqualTo(0), reason: '应该画一层卡面渐变');
      expect(membrane, greaterThanOrEqualTo(0), reason: 'frost>0 应该有磨砂膜');
      expect(face, lessThan(membrane), reason: '卡面渐变必须在磨砂膜之下（旧 bug 正是反了）');
    });

    testWidgets('卡面 alpha 跟「透明」滑杆：glassLevel=0.5 时卡面 alpha 减半', (tester) async {
      await tester.pumpWidget(
        wrap(
          GlassFrostLayer(
            coverPath: '',
            frostLevel: 0,
            glassLevel: 0.5,
            colorA: AppTokens.dark.cardA,
            colorB: AppTokens.dark.cardB,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      );
      await tester.pump();
      final box = tester.widget<DecoratedBox>(
        find.byWidgetPredicate(
          (w) => w is DecoratedBox && w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient != null,
        ).first,
      );
      final gradient = (box.decoration as BoxDecoration).gradient! as LinearGradient;
      // card-a = rgba(255,255,255,0.07) → 0.07 * 0.5
      expect(gradient.colors.first.a, closeTo(0.07 * 0.5, 0.001));
      expect(gradient.colors.last.a, closeTo(0.015 * 0.5, 0.001));
    });

    testWidgets('玻璃后封面走 ImageFiltered（blur 44 + 饱和度/亮度矩阵），不是原图直出', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GlassFrostLayer(
            coverPath: 'C:/__no_such_dir__/nope.jpg',
            frostLevel: 0.5,
            colorA: Color(0x12FFFFFF),
            colorB: Color(0x04FFFFFF),
            child: SizedBox(width: 200, height: 200),
          ),
        ),
      );
      await tester.pump();
      final filtered = tester.widget<ImageFiltered>(find.byType(ImageFiltered));
      final desc = filtered.imageFilter.toString();
      expect(desc, contains('blur'));
      expect(desc, contains('44.0'), reason: '--frost-cover-filter 的 blur(44px)');
      expect(desc, contains('matrix'), reason: 'saturate/brightness 合成进颜色矩阵');
      // 外扩 124%（CSS inset:-12%），否则 44px 模糊会把四边糊成透明
      final scale = tester.widget<Transform>(find.byType(Transform).first);
      expect(scale.transform.getMaxScaleOnAxis(), closeTo(1.24, 0.001));
    });

    testWidgets('顶部 1px 高光：alpha = frost * 0.22', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GlassFrostLayer(
            coverPath: '',
            frostLevel: 0.5,
            colorA: Color(0x12FFFFFF),
            colorB: Color(0x04FFFFFF),
            child: SizedBox(width: 200, height: 200),
          ),
        ),
      );
      await tester.pump();
      final highlight = tester.widget<ColoredBox>(
        find.byKey(const Key('glass-top-highlight')),
      );
      expect(highlight.color.a, closeTo(0.5 * 0.22, 0.001));
    });

    test('saturate+brightness 矩阵：sat=1,b=1 退化成单位矩阵', () {
      final m = saturateBrightnessMatrix(1, 1);
      expect(m[0], closeTo(1, 1e-9));
      expect(m[1], closeTo(0, 1e-9));
      expect(m[4], closeTo(0, 1e-9)); // 目标通道偏移
      expect(m[18], 1); // alpha 行
      final bright = saturateBrightnessMatrix(1, 0.7);
      expect(bright[0], closeTo(0.7, 1e-9), reason: '亮度是整体乘 0.7');
      expect(bright[12], closeTo(0.7, 1e-9));
    });

    testWidgets('卡外投影只落在盒子外面：盒内不会被阴影填成一块灰板', (tester) async {
      // CSS 的 box-shadow 画在边框盒**外面**；Flutter 的 BoxShadow 会把整个盒子
      // 填一遍再模糊，卡面一透明就透出灰板（透明滑杆调高时整列发灰）。
      // 这条用例直接量像素：盒内中心必须是透明的，盒外下方必须有阴影。
      final key = GlobalKey();
      await tester.pumpWidget(
        wrap(
          Center(
            child: RepaintBoundary(
              key: key,
              // 画布比卡片大一圈，才量得到盒外的投影
              child: SizedBox(
                width: 200,
                height: 200,
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: GlassFrostLayer(
                    coverPath: '',
                    frostLevel: 0,
                    // 卡面 alpha 为 0：盒内不该有任何填充，看得到什么就是阴影透出来的
                    colorA: const Color(0x00FFFFFF),
                    colorB: const Color(0x00FFFFFF),
                    shadow: const [
                      BoxShadow(
                        color: Color(0xFF000000),
                        offset: Offset(0, 12),
                        blurRadius: 0,
                        spreadRadius: 0,
                      ),
                    ],
                    child: const SizedBox(width: 120, height: 120),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return data!;
      });
      final size = boundary.size;
      int alphaAt(int x, int y) =>
          bytes!.getUint8((y * size.width.toInt() + x) * 4 + 3);

      // 盒内中心（卡片 40..160）：透明
      expect(alphaAt(100, 100), 0, reason: '阴影不该填在盒子里面');
      // 盒外正下方（卡片下沿 160，+12 偏移 → 168 那条带）：有阴影
      expect(alphaAt(100, 168), greaterThan(0), reason: '盒子下面要有投影');
    });
  });
}
