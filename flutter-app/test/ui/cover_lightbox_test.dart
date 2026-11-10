// test/ui/cover_lightbox_test.dart
//
// M2b T11：封面放大层的 widget 用例 —— 开/关三路、视图复位、双击分级、
// 位移夹取、点图不关闭、caption。数值（zoomAt 与 clamp 公式）按计划基准
// 逐字验证；手势用 TestGesture 真实指针序列驱动。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/library/recent_store.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/cover_state.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/lightbox_controller.dart';
import 'package:light_music/state/panel_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/cover_lightbox.dart';
import 'package:provider/provider.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:nested/nested.dart' show SingleChildWidget;

// 600×600 视口：图片边 = min(78vw=468, 72vh=432, 620) = 432。
const double _side = 432;

/// 取灯箱当前视图（scale/offset）—— 通过 _CoverLightboxState 的 notifier
/// 不可直达，这里直接从 Transform 层读：scale 与 offset 都在 Transform 上。
({
  double scale,
  double offsetX,
  double offsetY,
}) _readView(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(
    find.descendant(
      of: find.byType(CoverLightbox),
      matching: find.byType(Transform),
    ),
  ).toList();
  // [0] = translate（外层）、[1] = scale（内层）。
  final translate = transforms[0].transform.getTranslation();
  final scale = transforms[1].transform.getMaxScaleOnAxis();
  return (
    scale: scale,
    offsetX: translate.x,
    offsetY: translate.y,
  );
}

class _Harness {
  _Harness() {
    final dir = Directory.systemTemp.createTempSync('lightbox-test-');
    directory = dir;
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
    playlist = Playlist.fromTracks(<Track>[
      Track(
        id: 't0',
        src: '/t0.flac',
        title: '十年',
        artist: '陈奕迅',
        album: '某专辑',
        duration: 226,
      ),
    ]);
    toasts = ToastState();
    library = LibraryState(
      prefs: AppPrefs.inMemory(),
      repo: LibraryRepository(directory: dir.path),
      importer: ImportService(playlist: playlist, toasts: toasts),
      toasts: toasts,
    );
    player = PlayerState(
      prefs: AppPrefs.inMemory(),
      transport: TransportController(
        player: AudioPlayer(FakeAudioDriver()),
        recent: const _NoRecent(),
        toasts: toasts,
        playlist: playlist,
      ),
    );
    recent = RecentState(RecentStore(AppPrefs.inMemory()));
    lightbox = LightboxController();
    cover = CoverState(
      json: const _NoJson(),
      bytes: const _NoBytes(),
      diskStore: CoverDiskStore(directory: dir.path),
      artistImageDirectory: dir.path,
    );
  }

  late final Directory directory;
  late final Playlist playlist;
  late final ToastState toasts;
  late final LibraryState library;
  late final PlayerState player;
  late final RecentState recent;
  late final LightboxController lightbox;
  late final CoverState cover;
  int closeCalls = 0;

  List<SingleChildWidget> providers() => <SingleChildWidget>[
        ChangeNotifierProvider<LibraryState>.value(value: library),
        ChangeNotifierProvider<PlayerState>.value(value: player),
        ChangeNotifierProvider<RecentState>.value(value: recent),
        ChangeNotifierProvider<CoverState>.value(value: cover),
        ChangeNotifierProvider<LightboxController>.value(value: lightbox),
        ChangeNotifierProvider<PanelController>(create: (_) => PanelController()),
      ];

  /// 灯箱本体（关闭走 controller.close 的包装，计数 closeCalls）。
  Widget widget() => CoverLightbox(
        onClose: () {
          closeCalls += 1;
          lightbox.close();
        },
      );

  void dispose() {
    player.dispose();
    library.dispose();
    recent.dispose();
    cover.dispose();
    toasts.dispose();
  }
}

Future<void> _pumpOpen(
  WidgetTester tester,
  _Harness h,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(600, 600);
  addTearDown(tester.view.reset);
  h.lightbox.open();
  await tester.pumpWidget(
    MultiProvider(
      providers: h.providers(),
      child: MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  // 把灯箱推到 Stack 顶层（与 home_page 相同的挂法）。
  await tester.pumpWidget(
    MultiProvider(
      providers: h.providers(),
      child: MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: Scaffold(
          body: Stack(
            children: [
              const SizedBox.expand(),
              Positioned.fill(child: h.widget()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('打开后显示大图与 caption；初始视图 1× 居中', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOpen(tester, h);

    expect(find.byType(CoverLightbox), findsOneWidget);
    expect(find.byKey(const Key('lightbox-cover')), findsOneWidget);
    // caption 逐字（App.tsx:1444）：[title, artist, album].join(' · ')。
    expect(find.text('十年 · 陈奕迅 · 某专辑'), findsOneWidget);
    final view = _readView(tester);
    expect(view.scale, 1.0);
    expect(view.offsetX, 0.0);
    expect(view.offsetY, 0.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('双击分级：1× → 2× → 4× → 1×，中心锚点 offset 保持 0', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOpen(tester, h);
    final cover = find.byKey(const Key('lightbox-cover'));

    Future<void> doubleTap() async {
      // 双击 = 两根独立指针 40ms（kDoubleTapMinTime）内的两次 down/up；
      // 第二次 up 后把 300ms 双击窗口完整泵完，arena 归零再进下一轮。
      final gesture = await tester.startGesture(tester.getCenter(cover));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 40));
      final gesture2 = await tester.startGesture(tester.getCenter(cover));
      await gesture2.up();
      await tester.pump(const Duration(milliseconds: 350));
    }

    await doubleTap();
    expect(_readView(tester).scale, 2.0, reason: '1× → 2×');
    expect(_readView(tester).offsetX, 0.0, reason: '中心锚点不平移');

    await doubleTap();
    expect(_readView(tester).scale, 4.0, reason: '2× → 4×（上限）');

    await doubleTap();
    final view = _readView(tester);
    expect(view.scale, 1.0, reason: '4× → 1×（回正）');
    expect(view.offsetX, 0.0);
    expect(view.offsetY, 0.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('位移夹取：scale=2 时拖 500 夹回 ±234（468×(2−1)/2）', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOpen(tester, h);
    final cover = find.byKey(const Key('lightbox-cover'));
    final maxX = _side * (2 - 1) / 2;

    // 先双击到 2×。
    final gesture = await tester.startGesture(tester.getCenter(cover));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 40));
    final gesture2 = await tester.startGesture(tester.getCenter(cover));
    await gesture2.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(_readView(tester).scale, 2.0);

    // 从图中心按住拖到 +500：clamp 到 maxX。拖拽的 down/up 都会触发
    // doubleTap 倒计时/窗口：每次 up 后 pump 350 消化干净。
    final origin = tester.getCenter(cover);
    final drag = await tester.startGesture(origin);
    await drag.moveBy(const Offset(500, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final x = _readView(tester).offsetX;
    expect(x, maxX, reason: '位移被夹在图片边缘不离开视口');
    expect(x, lessThanOrEqualTo(maxX));

    // 反向同理。
    final drag2 = await tester.startGesture(origin);
    await drag2.moveBy(const Offset(-1000, 0));
    await tester.pump();
    await drag2.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(_readView(tester).offsetX, -maxX);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点图不关闭；点遮罩空白关闭；关闭按钮关闭', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOpen(tester, h);

    // 点图（图中心）→ 不关。图上有 DoubleTapGestureRecognizer：单击会留
    // 一个 40ms 的倒计时 Timer，泵过 300ms 窗口再断言（防 pending timer）。
    await tester.tap(find.byKey(const Key('lightbox-cover')), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 350));
    expect(h.lightbox.isOpen, isTrue, reason: '点在图上不关闭（App.tsx:1321）');
    expect(h.closeCalls, 0);

    // 点遮罩空白（左上角 10,10）→ 关。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(h.lightbox.isOpen, isFalse, reason: '点图以外的遮罩关闭');
    expect(h.closeCalls, 1);

    // 再开，点右上角关闭按钮 → 关。
    h.lightbox.open();
    await tester.pump();
    await tester.tap(find.byKey(const Key('lightbox-close')));
    await tester.pump();
    expect(h.lightbox.isOpen, isFalse);
    expect(h.closeCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮缩放：向上滚放大到 clamp(1..4)，光标为锚点', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOpen(tester, h);
    final cover = find.byKey(const Key('lightbox-cover'));
    final center = tester.getCenter(cover);

    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    // down 落在图上会启动 doubleTap 的 40ms 倒计时：先把窗口泵完再发滚轮。
    await tester.pump(const Duration(milliseconds: 350));
    await gesture.moveTo(center);
    // 向上滚一格（deltaY 负）：scale = exp(120*0.0016) ≈ 1.21。
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(300, 300),
        scrollDelta: Offset(0, -120),
      ),
    );
    await tester.pump();
    await gesture.removePointer();
    await tester.pump(const Duration(milliseconds: 350));
    final view = _readView(tester);
    expect(view.scale, closeTo(math.exp(120 * 0.0016), 0.01));
    // 锚点在中心：offset 保持 0。
    expect(view.offsetX, 0.0);
    expect(tester.takeException(), isNull);
  });
}

class _NoRecent implements RecentRecorder {
  const _NoRecent();

  @override
  void record(Track track, {DateTime? at}) {}
}

class _NoJson implements HttpJsonClient {
  const _NoJson();

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async =>
      const JsonNetwork();
}

class _NoBytes implements ImageBytesClient {
  const _NoBytes();

  @override
  Future<ImageBytesOutcome> getBytes(
    Uri url, {
    required Duration timeout,
  }) async =>
      const ImageBytesNetwork();
}
