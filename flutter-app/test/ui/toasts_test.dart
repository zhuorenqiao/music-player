// 提示条宿主：liveRegion 语义、文案渲染、error 用错误底色 token。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/toasts.dart';
import 'package:provider/provider.dart';

Widget wrap(ToastState state) => ChangeNotifierProvider<ToastState>.value(
  value: state,
  child: MaterialApp(
    theme: buildTheme(),
    home: const Scaffold(body: ToastsHost()),
  ),
);

void main() {
  testWidgets('宿主带 liveRegion 语义并渲染文案', (tester) async {
    final semantics = tester.ensureSemantics();
    final state = ToastState()..show('这首歌已经不在播放列表里了', durationMs: 1000);
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state));

    expect(find.text('这首歌已经不在播放列表里了'), findsOneWidget);
    final data = tester
        .getSemantics(find.byType(ToastsHost))
        .getSemanticsData();
    expect(data.flagsCollection.isLiveRegion, isTrue);
    expect(data.label, contains('提示'));

    semantics.dispose();
    // 让 1000ms 的计时器跑完，别把 pending timer 留给下一个用例。
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('这首歌已经不在播放列表里了'), findsNothing);
  });

  testWidgets('error 用错误底色，其余用普通底色', (tester) async {
    final state = ToastState()
      ..info('已清空')
      ..error('保存失败');
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state));

    expect(find.text('已清空'), findsOneWidget);
    expect(find.text('保存失败'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Material && widget.color == AppTokens.dark.toastErrorBg,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Material && widget.color == AppTokens.dark.toastBg,
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 3300));
    expect(find.text('已清空'), findsNothing);
    expect(find.text('保存失败'), findsNothing);
  });
}
