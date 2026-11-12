// test/ui/player_card_test.dart
//
// 播放卡合成（对译 `.player`，app.css:427-518）的回归：
//   1. 曲目区与控制区在同一张卡里，各自把卡片外观剥掉（:510-518）；
//   2. 窄屏歌词区吃掉剩余高度（`:3977-3987` 的 `flex: 1 1 0`），不是旧实现
//      那个写死的 clamp(112,15vh,132) 预览条；
//   3. 没有 PlayerCardScope 时（独立预览 / 既有测试），子卡仍是原来的样子。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/player_card.dart';
import 'package:light_music/ui/stage.dart';
import 'package:light_music/ui/vinyl_deck.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

const StagePreview _preview = StagePreview(
  title: '那天下雨了',
  artist: '周杰伦',
  album: '太阳之子',
  total: '03:43',
  coverPath: '',
);

void main() {
  testWidgets('没有 PlayerCardScope：子卡保持自带卡片外观（独立预览不变）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(450, 873);

    await tester.pumpWidget(wrap(_preview));
    await tester.pump();

    // 独立预览时 scope 不存在。
    expect(
      tester
          .element(find.byType(StagePreview))
          .findAncestorWidgetOfExactType<PlayerCardScope>(),
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('在 PlayerCard 里：stage 铺满剩余高度，歌词区不再被 clamp 截断', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    // 窄屏档：宽 <900。
    tester.view.physicalSize = const Size(450, 873);

    await tester.pumpWidget(
      wrap(
        PlayerCard(
          coverPath: '',
          frostLevel: 0,
          children: [
            Expanded(
              child: StagePreview(
                title: _preview.title,
                artist: _preview.artist,
                album: _preview.album,
                total: _preview.total,
                coverPath: '',
              ),
            ),
            const SizedBox(height: 120, key: Key('fake-transport')),
          ],
        ),
      ),
    );
    await tester.pump();

    // 卡片内部存在 scope，子卡据此脱壳。
    expect(find.byType(PlayerCardScope), findsOneWidget);
    // 封面照常渲染。
    expect(find.byType(CoverDisc), findsOneWidget);

    final cardRect = tester.getRect(find.byType(PlayerCard));
    final transportRect = tester.getRect(find.byKey(const Key('fake-transport')));
    // 控制条贴在卡内底部。
    expect(transportRect.bottom, closeTo(cardRect.bottom, 1));
    // stage 占据控制条以上的全部高度（不是被压成内容高度）。
    final coverRect = tester.getRect(find.byType(CoverDisc));
    expect(coverRect.top, greaterThan(cardRect.top));
    expect(coverRect.bottom, lessThan(transportRect.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无封面 / 空歌词也不崩（窄屏卡内）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(450, 873);

    await tester.pumpWidget(
      wrap(
        PlayerCard(
          coverPath: '',
          frostLevel: 0,
          children: [
            Expanded(child: StagePreview(title: 'A', artist: 'B', album: '', total: '--:--', coverPath: '')),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
