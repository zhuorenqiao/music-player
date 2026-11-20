import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/splash_gate.dart';
import 'package:light_music/ui/splash_page.dart';

void main() {
  testWidgets('SplashGate 先显示 2 秒开屏，再淡入首页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(tokens: AppTokens.dark),
        home: const SplashGate(
          child: Scaffold(body: Center(child: Text('home'))),
        ),
      ),
    );

    expect(find.byType(SplashPage), findsOneWidget);
    expect(find.text('home'), findsNothing);

    // 2 秒开屏结束；onCompleted 在帧后回调，再等 360ms 的淡入收尾。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(SplashPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
