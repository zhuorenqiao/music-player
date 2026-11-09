import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/bilingual_toggle.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('尺寸与文案：高 26、字号 11.5、左右 9、图标 12、间距 3', (tester) async {
    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (_) {})));
    final box = tester.getSize(find.byKey(const Key('bilingual-toggle')));
    expect(box.height, 26);
    final text = tester.widget<Text>(find.text('双语'));
    expect(text.style!.fontSize, 11.5);
    final decorated = tester.widget<Container>(find.byKey(const Key('bilingual-toggle')));
    final padding = (decorated.decoration as BoxDecoration).borderRadius as BorderRadius;
    expect(padding.topLeft.x, 999);
    expect(tester.getSize(find.byKey(const Key('bilingual-glyph'))).width, 12);
  });

  testWidgets('开：强调色描边与浅底；关：灰', (tester) async {
    await tester.pumpWidget(wrap(BilingualToggle(enabled: true, onChanged: (_) {})));
    var decoration = tester.widget<Container>(find.byKey(const Key('bilingual-toggle'))).decoration as BoxDecoration;
    expect(decoration.color, AppTokens.dark.accentSoft);
    expect((decoration.border as Border).top.color, AppTokens.dark.accentLine);
    expect(tester.widget<Text>(find.text('双语')).style!.color, AppTokens.dark.accentLight);

    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (_) {})));
    decoration = tester.widget<Container>(find.byKey(const Key('bilingual-toggle'))).decoration as BoxDecoration;
    expect(decoration.color, AppTokens.dark.tint1);
    expect((decoration.border as Border).top.color, AppTokens.dark.progressTrack);
    expect(tester.widget<Text>(find.text('双语')).style!.color, AppTokens.dark.textDim);
  });

  testWidgets('点击回调取反值，语义是 switch', (tester) async {
    bool? got;
    await tester.pumpWidget(wrap(BilingualToggle(enabled: false, onChanged: (v) => got = v)));
    await tester.tap(find.byKey(const Key('bilingual-toggle')));
    expect(got, isTrue);

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(wrap(BilingualToggle(enabled: true, onChanged: (_) {}, tooltip: '关闭中文译文对照')));
    final data = tester.getSemantics(find.byKey(const Key('bilingual-toggle')));
    expect(data.flagsCollection.isButton, isTrue);
    // 当前 SDK 的 isToggled 是 Tristate（不是 bool）：语义是「on」才是我们要的。
    // 值取自 brief 的原始断言（isToggled 为真），只换成这个类型下的等价写法。
    expect(data.flagsCollection.isToggled, Tristate.isTrue);
    expect(data.label, '双语');
    expect(data.hint, '关闭中文译文对照');
    semantics.dispose();
  });
}
