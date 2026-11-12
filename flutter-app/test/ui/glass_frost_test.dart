// test/ui/glass_frost_test.dart
//
// 磨砂玻璃层（对译 app.css:449-455 的 `backdrop-filter`）：
//   blur(calc(16px + frost*26px)) saturate(calc(100% + frost*65%))
//
// 这里钉住的是**滤镜真的接上了**，而不只是「代码长得像」：
// 旧实现把 saturate 写成返回透明色的空占位，模糊之后的饱和度提升实际没有
// 发生（颜色发灰），而测试和视觉都没发现。现在断言 BackdropFilter 的
// filter 是一个 compose(outer: 饱和度矩阵, inner: blur) 的组合。
import 'package:flutter/material.dart';
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
}
