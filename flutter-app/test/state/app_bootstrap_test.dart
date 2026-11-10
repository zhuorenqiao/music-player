// test/state/app_bootstrap_test.dart
//
// 组合根（T23 的装配）：存档还原顺序、媒体会话附着时机，以及
// 「应用根把四个状态注册给 provider」这条界面契约。
//
// 另有两条启动健壮性（T22 修正）：媒体会话起不来 / 永不返回都不许挡住
// `runApp`，通知权限只查询不申请。
//
// 以及 T24 补上的接线（T23 遗留）：删掉正在播的那首要接着播下一首，
// 清空列表要停播并卸载内核里的曲目。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/ui/home_page.dart';
import 'package:light_music/ui/toasts.dart';
import 'package:provider/provider.dart';

Track track(String id, String title) =>
    Track(id: id, src: '/m/$id.flac', title: title, duration: 61);

/// 等落盘防抖真的到点（终审 R2）。
///
/// 停止播放那条腿必须由 `schedulePersist` 的定时器自己跑完才算数：第 1 轮那条
/// 用例手调 `flushPersist()`，于是「stopPlayback 根本不排盘」这个缺陷只在测试
/// 里被绕过。这里一律等真实窗口，不手调。
Future<void> afterPersistDebounce() => Future<void>.delayed(
  const Duration(milliseconds: kPersistDebounceMs + 150),
);

/// `start()` 直接抛：Android 没有 Activity 时 `activate()` 报 `NO_ACTIVITY`。
class _ThrowingBridge implements MediaSessionBridge {
  @override
  Stream<MediaSessionCommand> get commands =>
      const Stream<MediaSessionCommand>.empty();

  @override
  Future<void> start() async => throw StateError('NO_ACTIVITY');

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {}

  @override
  Future<void> dispose() async {}
}

/// `start()` 永不返回：卡在系统权限对话框上，或平台通道永久沉默。
class _HangingBridge implements MediaSessionBridge {
  @override
  Stream<MediaSessionCommand> get commands =>
      const Stream<MediaSessionCommand>.empty();

  @override
  Future<void> start() => Completer<void>().future;

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory dir;
  late AppPrefs prefs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('light-boot');
    prefs = AppPrefs.inMemory();
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [track('a', '十年'), track('b', '孤勇者')],
        order: ['b', 'a'],
        currentId: 'a',
        mode: PlayMode.one,
      ),
    );
    await prefs.writeNumber(StorageKeys.volume, 0.25);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('启动装配：按存档顺序还原、读回音量与模式、附着媒体会话', () async {
    final bridge = FakeMediaSessionBridge();

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: bridge,
    );

    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
    expect(bootstrap.library.currentId, 'a');
    expect(bootstrap.player.transport.playlist.mode, PlayMode.one);
    expect(bootstrap.player.volume, 0.25);
    // 媒体会话 attach 时列表已就位，首推就是还原出来的当前曲目
    expect(bridge.startCount, 1);
    expect(bridge.published.last.title, '十年');
  });

  /// 终审 R4：原版 `src/state/player.tsx:556` 的还原光标规则是
  /// `storedId && playlist.indexOfId(storedId) >= 0 ? indexOfId(storedId) : 0`
  /// —— **任何一次启动都落得到一个光标**：没有有效存档就是列表第一首，而且是
  /// `player.load(track, { autoplay: false })` 的暂停态；只有空列表才是空舞台。
  /// 第 1 轮移植在这里写了 `clearCurrent()`（「没有有效 id 就没有光标」），
  /// 与本用例正面冲突。
  test('无有效存档时光标落到第一首且不自动播', () async {
    final driver = FakeAudioDriver();
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [track('a', '十年'), track('b', '孤勇者')],
        order: ['b', 'a'],
        mode: PlayMode.list,
      ),
    );
    // prefs 那份现场与文件仓逐位一致（自洽），但 currentId 指着一首先前就被删掉
    // 的曲目：两份痕迹都给不出有效光标。
    await prefs.writeJson(StorageKeys.order, ['b', 'a']);
    await prefs.writeString(StorageKeys.currentId, 'local:ghost');

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: driver,
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
    expect(
      bootstrap.library.currentId,
      'b',
      reason: '没有有效存档 ⇒ 落到列表第一首（原版 player.tsx:556），不是空舞台',
    );
    expect(
      await prefs.readString(StorageKeys.currentId),
      'b',
      reason: '定了光标就要把 prefs 的 currentId 补写一致'
          '（原版 persist 每次都跟着 playlist 重写，player.tsx:243-249）',
    );
    // 光标只是「指着」第一首，绝不该自动播起来（自动播放策略）
    expect(bootstrap.player.playing, isFalse);
    expect(driver.calls, isNot(contains('play')));
  });

  /// 终审 R2：I4 的「停止播放」那条腿从前只活在手调 `flushPersist()` 的用例里。
  /// 这里走真实链路：播 → 停（系统侧 Stop 命令走的就是同一个
  /// `TransportController.stopPlayback`）→ 等防抖自己落盘 → **重建 bootstrap**
  /// （它内部就会 `library.restore()`）→ 已停的那首不许复活。
  test('stopPlayback 后重建 bootstrap 再 restore：不复活已停的曲目', () async {
    final firstDriver = FakeAudioDriver();
    final first = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: firstDriver,
      bridge: FakeMediaSessionBridge(),
    );

    // 存档现场是顺序 [b, a]、光标 a：先把 a 真的播起来，让 prefs 落下这份现场。
    await first.player.playTrack('a');
    expect(first.player.playing, isTrue);
    await afterPersistDebounce();
    expect(
      await prefs.readString(StorageKeys.currentId),
      'a',
      reason: '播放推进那一次落下的现场（对照用：停止之后必须把它推翻）',
    );
    expect(await prefs.readJson(StorageKeys.order), ['b', 'a']);

    await first.player.transport.stopPlayback();
    await afterPersistDebounce();
    expect(
      await prefs.readString(StorageKeys.currentId),
      isNull,
      reason: 'stopPlayback 必须自己排一次落盘：prefs 里的光标要如实清掉',
    );
    expect(
      await prefs.readJson(StorageKeys.order),
      ['b', 'a'],
      reason: '列表原样保留，痕迹里只清光标那一项',
    );

    // 「重开应用」：新的 bootstrap 读同一份存档与 prefs 现场。
    // 先把上一份的落盘定时器与事件订阅关掉（dispose 是同步的），否则它迟到的
    // 那一次 flush 会踩在第二个 bootstrap 刚写好的痕迹上。
    first.player.dispose();
    final secondDriver = FakeAudioDriver();
    final second = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: secondDriver,
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(second.player.dispose);

    expect(
      second.library.currentId,
      isNot('a'),
      reason: 'prefs 现场自洽而 currentId 键缺失 = 用户停过，不许回落到档案值',
    );
    // 与 R4 合起来的最终语义：停过之后重启落到第一首（这里就是 b），保持暂停。
    expect(second.library.currentId, 'b');
    expect(second.player.playing, isFalse);
    expect(secondDriver.calls, isNot(contains('play')));
    expect(await prefs.readString(StorageKeys.currentId), 'b');
  });

  /// 终审 R2 的**残留**（A 段报告第 5 条）：上面那条等的是「防抖自己跑完」，
  /// 可停止这一条腿接的正是 `schedulePersist` 那个 400ms 窗口 ——
  /// 「按了停止，应用随即被杀 / 立刻重开」就落在窗口里，prefs 留的还是停止前
  /// 那个 currentId，重启照样复活用户明明停掉的那一首。
  /// 所以停止这一次必须**同步落盘**（`await stopPlayback()` 返回即已落定）。
  /// 只做在停止这一条腿上：播放推进的防抖语义（连续切歌只写最后一次）不动。
  test('停止后不落防抖窗口：立刻重建也不复活', () async {
    final first = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );

    await first.player.playTrack('a');
    expect(first.player.playing, isTrue);
    await afterPersistDebounce();
    expect(await prefs.readString(StorageKeys.currentId), 'a');

    await first.player.transport.stopPlayback();
    // 一个毫秒都不等：防抖窗口不是「可以丢」的窗口
    expect(
      await prefs.readString(StorageKeys.currentId),
      isNull,
      reason: 'stopPlayback 返回时现场必须已经落定，不留 400ms 的空档',
    );

    first.player.dispose();
    final secondDriver = FakeAudioDriver();
    final second = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: secondDriver,
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(second.player.dispose);

    expect(
      second.library.currentId,
      isNot('a'),
      reason: '「停止 → 马上杀进程」不是没停过：已停的那首不许复活',
    );
    // 与 R4 同一条结论：停过之后重启落到列表第一首（顺序 [b, a]），保持暂停。
    expect(second.library.currentId, 'b');
    expect(second.player.playing, isFalse);
    expect(secondDriver.calls, isNot(contains('play')));
  });

  /// 终审 R6：模式与光标同源同权 —— 播放推进只写 prefs（`PlayerState.cycleMode`
  /// 那句 `writeString(mode)`），文件仓只在列表变化时才跟着重写，所以**prefs 才是
  /// 更新的陈述**。原版更是只认 prefs 一处（`src/state/player.tsx:567`
  /// `playlist.setMode(Storage.read(STORAGE_KEYS.mode, PLAY_MODES.LIST))`，
  /// localStorage 那份曲目档案里根本不存 mode）。
  /// 第 1 轮把 `currentId` 升级成 prefs 优先时漏了 mode，于是「改完模式直接
  /// 退出重开」会被档案里的旧模式盖回去。
  test('改完模式直接重启：模式不丢', () async {
    final first = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    // 本用例的起点：存档说的是单曲循环（setUp 里写的 mode: PlayMode.one）
    expect(first.player.transport.playlist.mode, PlayMode.one);

    // 用户切到随机播放：prefs 立刻变成 shuffle，文件仓那份档案没被碰过
    first.player.cycleMode();
    expect(first.player.transport.playlist.mode, PlayMode.shuffle);
    expect(await prefs.readString(StorageKeys.mode), 'shuffle');
    expect(
      (await LibraryRepository(directory: dir.path).load()).mode,
      PlayMode.one,
      reason: '对照用：档案仍是旧模式，重建时读它就是 R6 的缺陷',
    );

    first.player.dispose();
    final second = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(second.player.dispose);

    expect(
      second.player.transport.playlist.mode,
      PlayMode.shuffle,
      reason: 'prefs 里有 mode 就用它，档案那份只在 prefs 缺失时兜底',
    );
    expect(second.player.view.value.mode, PlayMode.shuffle);
  });

  /// 终审 R6 的另一半：prefs 没有 `mode` 键时**才**回落到档案（原版那句
  /// `Storage.read(mode, PLAY_MODES.LIST)` 的缺省回落同理，只是我们的档案里
  /// 多一份 mode）。老存档 + 老 prefs（从没写过 mode 键）不能凭空变成列表循环。
  test('prefs 没写过模式时才回落档案里的模式', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(prefs.containsKey(StorageKeys.mode), isFalse);
    expect(bootstrap.player.transport.playlist.mode, PlayMode.one);
  });


  /// 终审 A1：音量与静音的真相只有 prefs 那两个键。
  ///
  /// 文件仓「重建 / 不可用」（这里是空目录，等价于仓储被清掉）不许把音量悄悄
  /// 洗成默认 0.7 —— 从前 `LibrarySnapshot.volume` 是个只写不读的死字段，
  /// 谁要真拿它去覆盖 prefs 就会踩这个坑，所以字段删掉了（minor 4）。
  test('文件仓重建（空目录）也照原样读回 prefs 里的音量', () async {
    await prefs.writeNumber(StorageKeys.volume, 0.33);
    final fresh = Directory.systemTemp.createTempSync('light-boot-empty');
    addTearDown(() => fresh.deleteSync(recursive: true));

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: fresh.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(bootstrap.library.tracks, isEmpty, reason: '空目录就是没有存档');
    expect(
      bootstrap.player.volume,
      closeTo(0.33, 1e-9),
      reason: '音量不跟着文件仓走，仓储重建不许把它清成默认 0.7',
    );
  });

  test('旧档案里残留的 volume / muted 不参与还原：仍以 prefs 为准', () async {
    // 修复前的存档会白写这两个键（值一律是默认的 null / false）；
    // 这里故意写一份「带音量」的老档案，读档必须完全无视它。
    File('${dir.path}${Platform.pathSeparator}library.json').writeAsStringSync(
      '''{"version":1,"tracks":[{"id":"a","src":"/m/a.flac","title":"十年"}],'''
      '''"order":["a"],"currentId":"a","mode":"list","volume":0.9,"muted":true}''',
    );
    await prefs.writeNumber(StorageKeys.volume, 0.33);
    await prefs.writeBool(StorageKeys.muted, false);

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(bootstrap.library.tracks.map((t) => t.id), ['a']);
    expect(bootstrap.player.volume, closeTo(0.33, 1e-9));
    expect(bootstrap.player.muted, isFalse);

    // 这条档案里的记录没有 duration（`/m/a.flac` 也不在盘上），所以它是自愈回填
    // 的候选：第 3 轮 I1 把谓词的准入从 `isLocal` 换成句柄能力位之后，这类
    // 「只有文件名 + 纯路径」的老记录**开始**进队列了（该进 —— 路径是真能开的）。
    // 文件不在盘上 ⇒ 这一批什么都没学到 ⇒ 第 4 轮 I9 起**不会**再触发收尾那次
    // `persist()`（从前会，白写一遍档案）。仍等批次信号落定：既让断言见到最终状态，
    // 也不给 Windows 留一个「还在跑的目录删除」。
    await bootstrap.library.enrichmentSettled;
    // 文件根本不在盘上 → 这次什么都没读到，不许记探测标记（第 3 轮 C1 同一条规则
    // 在装配层这一侧的落点）。
    expect(
      bootstrap.library.tracks.single.metadataProbed,
      isFalse,
      reason: '装配层这条真链路也一样：打不开文件就不记账',
    );
  });

  /// 第 4 轮复核对 I11 的边界修正落点：R8 的「坏档只读不写」gate 的是**曲库层
  /// 自己**那两次写（还原末尾与回填收尾的 `persist()`）；播放侧 `flushPersist`
  /// 写的是用户动作的如实陈述（停止就该清掉 `currentId`），在坏档会话里照样写 ——
  /// 把它一起 gate 掉反而会把 R2（停止不落盘、停过的歌重启复活）重新撕开。
  test('损坏档案 + 停止：播放侧 flushPersist 仍如实记录停止', () async {
    // 先让正式文件与 `.bak` 都长成一份正常档案，再把正式文件写坏：
    // 仓储只能回退 `.bak`，并把这一份快照标成 corrupted。
    final repo = LibraryRepository(directory: dir.path);
    for (var i = 0; i < 2; i++) {
      await repo.save(
        LibrarySnapshot(
          tracks: [track('a', '十年')],
          order: const ['a'],
          currentId: 'a',
          mode: PlayMode.list,
        ),
      );
    }
    File('${dir.path}${Platform.pathSeparator}library.json')
        .writeAsStringSync('{"tracks": [坏数据]}');

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);

    expect(
      bootstrap.library.tracks.map((t) => t.id),
      ['a'],
      reason: '回退出来的正是 `.bak` 那份：这一轮确实是坏档会话',
    );
    await bootstrap.library.enrichmentSettled;

    // 停止：清指针 + 同步落盘（R2 残留那条腿）。
    await bootstrap.player.transport.stopPlayback();

    expect(
      await prefs.readString(StorageKeys.currentId),
      isNull,
      reason: '停止是一句用户陈述，坏档会话里也必须如实写下去',
    );
    expect(
      await prefs.readJson(StorageKeys.order),
      ['a'],
      reason: '顺序跟着现场走，不该被坏档的 gate 冻住',
    );
  });

  test('通知权限只查询不申请：结果进 AppBootstrap，且能再查一次', () async {
    var queries = 0;
    var granted = false;

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      queryNotificationPermission: () async {
        queries += 1;
        return granted;
      },
    );

    // 启动只查一次，结果如实落到界面要用的字段上（T24 的提示条）。
    expect(queries, 1);
    expect(bootstrap.notificationGranted, isFalse);

    // 用户在系统对话框里点了「允许」：提示条能拿到新的真实状态，不停在首帧。
    granted = true;
    expect(await bootstrap.notificationPermission(), isTrue);
    expect(queries, 2);
  });

  test('通知权限查询抛异常：按「没有」处理，装配照旧完成', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      queryNotificationPermission: () async => throw StateError('no channel'),
    );

    expect(bootstrap.notificationGranted, isFalse);
    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
  });

  test('媒体会话 activate 抛异常：启动照旧（只是没有系统控件）', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: _ThrowingBridge(),
      queryNotificationPermission: () async => true,
    );

    // 存档还原、播放器、曲库一样不少 —— runApp 前不会炸。
    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
    expect(bootstrap.player.transport.playlist.size, 2);
    expect(bootstrap.notificationGranted, isTrue);
  });

  test('媒体会话永不返回：attach 超时后 buildBootstrap 照样返回', () async {
    final watch = Stopwatch()..start();

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: _HangingBridge(),
      mediaSessionAttachTimeout: const Duration(milliseconds: 50),
      queryNotificationPermission: () async => true,
    );
    watch.stop();

    expect(bootstrap.library.tracks, hasLength(2));
    // 默认 3 秒上限：绝不允许无限等下去（否则界面永远不出现）。
    expect(watch.elapsed, lessThan(kMediaSessionAttachTimeout));
  });

  testWidgets('应用根把四个状态注册给 provider', (tester) async {
    // M3 T11 起 transport 多一行 transport__wave（+33px）：默认 600 高的
    // 视口会溢出 21px，parity 校正把视口加高。
    tester.view.physicalSize = const Size(800, 660);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 组合根要读真实文件；testWidgets 的假时钟里必须借 runAsync 跑真异步
    final bootstrap = (await tester.runAsync(
      () => buildBootstrap(
        prefs: prefs,
        dataDirectory: dir.path,
        driver: FakeAudioDriver(),
        bridge: FakeMediaSessionBridge(),
      ),
    ))!;

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));

    final context = tester.element(find.byType(HomePage));
    expect(context.read<LibraryState>(), same(bootstrap.library));
    expect(context.read<PlayerState>(), same(bootstrap.player));
    expect(context.read<RecentState>(), same(bootstrap.recent));
    expect(context.read<ToastState>(), same(bootstrap.toasts));
    // 提示条宿主编在路由之上：任何页面都能看到同一条提示
    expect(find.byType(ToastsHost), findsOneWidget);
  });

  test('删除正在播的曲目：接续曲目接手播放', () async {
    final driver = FakeAudioDriver();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: driver,
      bridge: FakeMediaSessionBridge(),
    );
    // 存档顺序是 [b, a]、当前曲目 a：先真的把 a 加载起来
    await bootstrap.player.playTrack('a');
    expect(driver.calls, contains('open:/m/a.flac'));
    driver.calls.clear();

    await bootstrap.library.removeTrack('a');
    await pumpEventQueue();

    expect(bootstrap.player.current?.id, 'b');
    // 内核里那首被删掉了，接续的那首必须真的被加载 —— 否则界面显示 b、
    // 声音还停在已删的 a 上（或直接静音）
    expect(driver.calls, contains('open:/m/b.flac'));
  });

  test('清空播放列表：停播并卸载内核里的曲目', () async {
    final driver = FakeAudioDriver();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: driver,
      bridge: FakeMediaSessionBridge(),
    );
    await bootstrap.player.playTrack('a');
    driver.calls.clear();

    await bootstrap.library.clearPlaylist();
    await pumpEventQueue();

    expect(bootstrap.player.current, isNull);
    expect(bootstrap.player.view.value.current, isNull);
    // stopPlayback：暂停 + 卸载；只清列表不卸载，通知栏会留一条幽灵条目
    expect(driver.calls, contains('pause'));
    expect(driver.calls, contains('stop'));
  });

  test('组合根给导入服务接上时长探测（I1）', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );

    // 这条线以前根本没接：`ImportService.durationProbe` 在 lib/ 里没有任何赋值点，
    // ID3v1-only / FLAC 无 Vorbis comment 一类的曲目就永远没有时长（进度条 --:--）。
    // 真探测走 media_kit，测试环境里起不来，所以这里只验「装配有没有接上」，
    // 探测逻辑本身的可测接缝见 test/library/duration_probe_test.dart。
    expect(bootstrap.library.importer.durationProbe, isNotNull);
  });

  test('注入的探测接缝真的接到导入：无时长曲目落库时带上了时长', () async {
    // 只带 ID3v1（无 ID3v2）的文件：标签里没有时长，全靠探测补。
    final file = File('${dir.path}${Platform.pathSeparator}probe.flac')
      ..writeAsBytesSync(List<int>.filled(1024, 0));
    final stale = Track(
      id: localIdFor(file.path),
      src: file.path,
      title: '无标签曲',
      duration: double.nan,
      isLocal: true,
    );
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(tracks: [stale], order: [stale.id]),
    );

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      durationOpener: (source) async => 203.5,
    );
    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);
    addTearDown(bootstrap.recent.dispose);
    addTearDown(bootstrap.toasts.dispose);

    expect(bootstrap.library.tracks.single.hasDuration, isFalse);
    await bootstrap.library.enrichmentSettled;

    expect(bootstrap.library.tracks.single.duration, 203.5);
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks.single.duration, 203.5, reason: '探测到的时长要跟着批次落库');
  });

  test('播放推进就刷「最近播放」；删掉已听过的歌，失效标记跟着变（C2）', () async {
    final driver = FakeAudioDriver();
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: driver,
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);
    addTearDown(bootstrap.recent.dispose);
    addTearDown(bootstrap.toasts.dispose);

    var recentNotifications = 0;
    bootstrap.recent.addListener(() => recentNotifications++);

    await bootstrap.player.playTrack('a');
    await pumpEventQueue();
    // 真出声（位置推过 0）才记账：记账之后界面必须立刻看到（原版即画即变）
    driver.emitPosition(4);
    await pumpEventQueue();

    expect(bootstrap.recent.entries.map((e) => e.id), contains('a'));
    expect(
      recentNotifications,
      greaterThan(0),
      reason: 'record 之后要通知 RecentState 的订阅者',
    );
    expect(bootstrap.recent.entries.single.inPlaylist, isTrue);

    await bootstrap.library.removeTrack('a');
    await pumpEventQueue();

    // 列表变了：「已失效」标记跟着列表走，不该等下一次冷启动才校正
    expect(bootstrap.recent.entries.single.id, 'a');
    expect(bootstrap.recent.entries.single.inPlaylist, isFalse);
  });

  // -- 终审 A2：时长探测的原生 Player 必须有明确释放点 --------------------------

  test('AppBootstrap.dispose 关掉时长探测内核（探针持有释放接缝）', () async {
    var closes = 0;
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      durationOpener: (source) async => 100,
      durationOpenerClose: () async => closes++,
    );
    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);

    // 探针是组合根持有的（从前它连个引用都没留下，自然没人能关它）
    expect(bootstrap.durationProbe, isNotNull);
    expect(bootstrap.durationProbe!.isClosed, isFalse);
    expect(closes, 0);

    await bootstrap.dispose();
    expect(closes, 1, reason: 'MediaKitDurationOpener.dispose 那一条链路走通');
    expect(bootstrap.durationProbe!.isClosed, isTrue);

    // 幂等：重复 dispose 不多关一次
    await bootstrap.dispose();
    expect(closes, 1);
  });

  testWidgets('应用根卸载时释放探测内核（dispose 链接到界面层）', (tester) async {
    // M3 T11 起 transport 多一行：parity 校正把视口加高（与 provider 注册
    // 那条用例同因）。
    tester.view.physicalSize = const Size(800, 660);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var closes = 0;
    final bootstrap = (await tester.runAsync(
      () => buildBootstrap(
        prefs: prefs,
        dataDirectory: dir.path,
        driver: FakeAudioDriver(),
        bridge: FakeMediaSessionBridge(),
        durationOpener: (source) async => 100,
        durationOpenerClose: () async => closes++,
      ),
    ))!;

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));
    expect(closes, 0);

    // 换掉整棵树 = 应用根卸载：这就是生产上唯一的释放时机。
    // `State.dispose` 只能 `unawaited` 那次关闭（同步契约），而 close 排在
    // 探测队列的尾部，是一个微任务之后才落到 opener 上 —— 假时钟里要借
    // `runAsync(pumpEventQueue)` 才排得干（与 m1_smoke_test 同一手法）。
    await tester.pumpWidget(const SizedBox(width: 0, height: 0));
    await tester.runAsync(pumpEventQueue);
    expect(closes, 1);

    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);
  });

  test('生产那份探针在测试环境里起不来原生库，dispose 依然不抛', () async {
    // 不注入 durationOpener = 走 MediaKitDurationOpener 那条真链路：
    // `Player()` 在这里必然抛（没有 libmpv），opener 内部把它当「探不出来」，
    // 而 dispose 也绝不能因为「原生实例从来没见过」就往外抛。
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
    );
    addTearDown(bootstrap.player.dispose);
    addTearDown(bootstrap.library.dispose);

    expect(bootstrap.durationProbe, isNotNull);
    await bootstrap.dispose();
    expect(bootstrap.durationProbe!.isClosed, isTrue);
  });
}
