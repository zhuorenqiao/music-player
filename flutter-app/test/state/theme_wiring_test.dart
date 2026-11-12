// test/state/theme_wiring_test.dart
//
// M3 T5 装配闸口：组合根建出 ThemeState、MaterialApp 主题随它切换、
// 持久化往返（换肤「选择会记住」）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/color_utils.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';

class _Matcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const LyricsMatch(status: 'not-found');
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const TranslationResult(status: 'not-found', reason: 'song-not-matched');
}

void main() {
  test('组合根建出 ThemeState：持久化的 mode/color 读回', () async {
    final dir = Directory.systemTemp.createTempSync('theme-wiring-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
    final prefs = AppPrefs.inMemory();
    // 先写一份「浅色 + 粉」的存档，load 后必须原样读回（选择会记住）。
    await prefs.writeString('themeMode', 'light');
    await prefs.writeString('themeColor', 'pink');

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(bootstrap.theme.mode, ThemeModeSetting.light);
    expect(bootstrap.theme.color, ThemeColorSetting.pink);
    expect(bootstrap.theme.themeKey, 'light-pink');
  });

  testWidgets('MaterialApp 主题随 ThemeState 切换（token 换表）', (tester) async {
    final prefs = AppPrefs.inMemory();
    final theme = await ThemeState.load(prefs, platformDark: () => false);
    final dir = Directory.systemTemp.createTempSync('theme-w2-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
    // 组合根要跑真异步（repo.save / attach 的 .timeout）：testWidgets 的
    // FakeAsync 里 await 真异步等不到头 —— 塞进 runAsync（M2a 同款手法）。
    final bootstrap = await tester.runAsync(
      () => buildBootstrap(
        prefs: prefs,
        dataDirectory: dir.path,
        driver: FakeAudioDriver(),
        bridge: FakeMediaSessionBridge(),
        lyricsMatcher: _Matcher(),
        translationFetcher: _Fetcher(),
        themeState: theme,
      ),
    );
    final boot = bootstrap!;
    addTearDown(boot.player.dispose);

    await tester.pumpWidget(LightMusicApp(bootstrap: boot));
    await tester.pump();

    final context = tester.element(find.byType(Navigator).first);
    var tokens = Theme.of(context).extension<AppTokensData>()!.tokens;
    expect(tokens.name, 'mint-light', reason: '默认 mode=color → 浅色薄荷');

    // 切到深色蓝：token 表换、accent 变。
    boot.theme.setMode(ThemeModeSetting.dark);
    boot.theme.setColor(ThemeColorSetting.blue);
    await tester.pumpAndSettle();

    tokens = Theme.of(context).extension<AppTokensData>()!.tokens;
    expect(tokens.name, 'blue-dark');
    expect(toHexString(tokens.accent), '#4d8dff');
  });
}
