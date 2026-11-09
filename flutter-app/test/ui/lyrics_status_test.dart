import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_status.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
  home: Scaffold(body: Column(children: [child])),
);

void main() {
  testWidgets('加载中显示 10×10 spinner，文案 11.5', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '正在按曲名与歌手匹配歌词…', loading: true, failed: false, showRetry: false, onRetry: _noop,
    )));
    expect(find.byKey(const Key('lyrics-status-spinner')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('lyrics-status-spinner'))), const Size(10, 10));
    expect(tester.widget<Text>(find.text('正在按曲名与歌手匹配歌词…')).style!.fontSize, 11.5);
  });

  testWidgets('失败态用 dangerInk 颜色', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '连接歌词库超时', loading: false, failed: true, showRetry: true, onRetry: _noop,
    )));
    expect(tester.widget<Text>(find.text('连接歌词库超时')).style!.color, AppTokens.dark.dangerInk);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('重试按钮最小高度 24、点击触发回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(wrap(LyricsStatusLine(
      status: '未找到', loading: false, failed: true, showRetry: true, onRetry: () => tapped++,
    )));
    expect(tester.getSize(find.byKey(const Key('lyrics-retry'))).height, greaterThanOrEqualTo(24));
    await tester.tap(find.byKey(const Key('lyrics-retry')));
    expect(tapped, 1);
  });

  testWidgets('不显示重试时没有按钮', (tester) async {
    await tester.pumpWidget(wrap(const LyricsStatusLine(
      status: '歌词自动匹配自 LRCLIB线上库', loading: false, failed: false, showRetry: false, onRetry: _noop,
    )));
    expect(find.text('重试'), findsNothing);
  });
}

void _noop() {}
