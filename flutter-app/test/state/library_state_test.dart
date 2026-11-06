// test/state/library_state_test.dart
//
// 曲库状态层：导入 → 落库 → 冷启动还原、搜索关键词防抖与过滤、清空与删除。
// 仓储走真实文件（临时目录），只在需要观察落盘 / 防抖窗口时 await。
//
// 末尾那组「回填批次落库」的用例（终审 C1）用真实的带标签文件 + 真封面落盘器：
// 回填写的是内存里的活对象，但只有**批次完成后再落一次库**才不会在重启后丢掉
// 标签，所以断言一律从 `LibraryRepository.load()` 读回来验，而不是只看内存。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/metadata/cover_image.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/toast_state.dart';

import '../metadata/tag_fixtures.dart';

/// 等过防抖窗口：关键词只在 200ms 之后才成为「生效值」（与原版 debounce 一致）。
Future<void> afterDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: kSearchDebounceMs + 80));

/// 真实的 1×1 不透明 PNG：内嵌封面的最小样本（与 import_service_test 同一常量）。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

/// ID3v2.3 标签 + 一段 MPEG 帧，像真音频（与 import_service_test 同一造法）。
List<int> withId3(List<List<int>> frames) => [
  ...id3v2(frames),
  ...mpegFrame(),
];

/// 记下 save 次数的仓储：验「一批回填只落一次库」这条约束用。
class _CountingRepository extends LibraryRepository {
  _CountingRepository({required super.directory});

  int saves = 0;

  @override
  Future<void> save(LibrarySnapshot snapshot) {
    saves += 1;
    return super.save(snapshot);
  }
}

void main() {
  // 封面落盘要引擎的图像编解码（dart:ui）；其余用例仍是普通 test()，走真异步。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AppPrefs prefs;
  late Playlist playlist;
  late ToastState toasts;
  late LibraryState state;

  /// 造一个新实例：模拟「重开应用」，但共享同一份存档目录与 prefs。
  LibraryState buildState({Playlist? target}) => LibraryState(
    prefs: prefs,
    repo: LibraryRepository(directory: dir.path),
    importer: ImportService(
      playlist: target ?? Playlist(tracks: const []),
      toasts: toasts,
    ),
    toasts: toasts,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('light-state');
    prefs = AppPrefs.inMemory();
    playlist = Playlist(tracks: const []);
    toasts = ToastState();
    state = buildState(target: playlist);
  });

  tearDown(() {
    state.dispose();
    dir.deleteSync(recursive: true);
  });

  test('导入后落库，重启可原样还原顺序', () async {
    await state.importPaths(['/m/陈奕迅 - 十年.flac', '/m/孤勇者.flac']);
    await state.enrichmentSettled; // 回填批次的那一次落库先排干净，再验还原
    expect(state.tracks.length, 2);

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();

    expect(fresh.tracks.length, 2);
    expect(fresh.tracks.map((t) => t.handle.displayName).toList(), [
      '陈奕迅 - 十年.flac',
      '孤勇者.flac',
    ]);
    expect(fresh.restoring, isFalse);
  });

  test('搜索只匹配歌名，关键词大小写不敏感且去空白', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    state.tracks.first.title = 'Hello 十年';
    state.tracks.first.artist = '陈奕迅';
    state.tracks.last.title = '白玫瑰';

    state.keyword = 'HELLO';
    await afterDebounce();
    expect(state.filteredTracks.map((t) => t.title), ['Hello 十年']);

    // 歌手不参与搜索：关键词命中歌手名也不该有结果
    state.keyword = '陈奕迅';
    await afterDebounce();
    expect(state.filteredTracks, isEmpty);

    state.keyword = '  十年  ';
    await afterDebounce();
    expect(state.filteredTracks.map((t) => t.title), ['Hello 十年']);
  });

  test('关键词防抖：输入即时回显，过滤值等 200ms 才生效', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    state.tracks.first.title = '十年';
    state.tracks.last.title = '白玫瑰';

    state.keyword = '十年';
    expect(state.keyword, '十年'); // 输入框自己回显
    expect(state.filteredTracks.length, 2); // 生效值还在防抖窗口里

    await afterDebounce();
    expect(state.filteredTracks.map((t) => t.title), ['十年']);

    // 删到空：立刻回到完整列表，不等防抖窗口
    state.keyword = '';
    expect(state.filteredTracks.length, 2);
  });

  test('清空播放列表同时清文件仓与顺序键', () async {
    await state.importPaths(['/m/a.flac']);
    await state.enrichmentSettled; // 让回填收尾先落完库，别排在清空之后再写一遍顺序
    final id = state.tracks.first.id;
    await prefs.writeString(StorageKeys.currentId, id);
    await prefs.writeJson(StorageKeys.order, [id]);

    await state.clearPlaylist();

    expect(state.tracks, isEmpty);
    expect(state.currentId, isNull);
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks, isEmpty);
    expect(await prefs.readString(StorageKeys.currentId), isNull);
    expect(await prefs.readJson(StorageKeys.order), isNull);
  });

  test('删除当前曲目后指向接续的那首，删空则 currentId 为空', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    await state.enrichmentSettled;
    final firstId = state.tracks.first.id;
    await state.setCurrent(firstId);

    await state.removeTrack(firstId);

    expect(state.tracks.length, 1);
    expect(state.currentId, state.tracks.first.id);

    await state.removeTrack(state.tracks.first.id);

    expect(state.tracks, isEmpty);
    expect(state.currentId, isNull);
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks, isEmpty);
  });

  test('还原期间 restoring 为真，界面走骨架而不是空态', () async {
    var observed = false;
    state.addListener(() {
      if (state.restoring) observed = true;
    });

    await state.restore();

    expect(observed, isTrue);
    expect(state.restoring, isFalse);
  });

  test('脏文件仓不炸界面，退化成空歌单', () async {
    await state.importPaths(['/m/a.flac']);
    await state.enrichmentSettled; // 回填收尾的落库必须先跑完，否则会盖掉下面这份坏档
    // 正式文件与 `.bak` 都写坏：仓储无处回退，这也正是「脏存档」的极端形态
    const junk = '{"tracks": [坏数据]}';
    File('${dir.path}/library.json').writeAsStringSync(junk);
    File('${dir.path}/library.json.bak').writeAsStringSync(junk);

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();

    expect(fresh.tracks, isEmpty);
    expect(fresh.restoring, isFalse);
  });

  test('还原按存档顺序重建，模式与当前曲目一并读回', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    // 先排干回填收尾那一次落库：它写的是「导入时的自然顺序」，
    // 晚一步就会盖掉下面这份特意改过顺序的存档。
    await state.enrichmentSettled;
    final secondId = state.tracks[1].id;
    // 存档里的顺序、当前曲目与模式都是还原时要用的权威值
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: state.tracks,
        order: [
          state.tracks[2].id,
          state.tracks[0].id,
          state.tracks[1].id,
        ],
        currentId: secondId,
        mode: PlayMode.one,
      ),
    );

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();

    expect(fresh.tracks.map((t) => t.id).toList(), [
      state.tracks[2].id,
      state.tracks[0].id,
      secondId,
    ]);
    expect(fresh.currentId, secondId);
    expect(fresh.playlist.mode, PlayMode.one);
  });

  /// 造一个记录回调的实例：`onPlaylistChanged` 的每次调用都落进 [calls]。
  LibraryState buildRecordingState(List<String?> calls) => LibraryState(
    prefs: prefs,
    repo: LibraryRepository(directory: dir.path),
    importer: ImportService(playlist: Playlist(tracks: const []), toasts: toasts),
    toasts: toasts,
    onPlaylistChanged: ({String? removedId}) => calls.add(removedId),
  );

  test('删除曲目：回调带上被删掉的 id，装配层据此判断是不是在播的那首', () async {
    final calls = <String?>[];
    final seam = buildRecordingState(calls);
    addTearDown(seam.dispose);
    await seam.importPaths(['/m/a.flac', '/m/b.flac']);
    await seam.enrichmentSettled; // 回填收尾也走一次 _changed：先排干再数删除那一声
    calls.clear(); // 导入那一次的收尾不算

    final id = seam.tracks.first.id;
    await seam.removeTrack(id);

    expect(calls, [id]);
  });

  test('清空播放列表：回调不带 id（列表已空，装配层据此停播）', () async {
    final calls = <String?>[];
    final seam = buildRecordingState(calls);
    addTearDown(seam.dispose);
    await seam.importPaths(['/m/a.flac']);
    await seam.enrichmentSettled; // 同上：回填收尾那一次 _changed 不该混进下面的断言
    calls.clear();

    await seam.clearPlaylist();

    expect(calls, [null]);
    expect(seam.tracks, isEmpty);
  });

  // -- 终审 C1：回填批次必须再落一次库 ---------------------------------------

  /// 等文件仓里出现期望的元数据。
  ///
  /// 「回填跑完」与「回填后的落库完成」是两个时刻，而 C1 的缺陷正是后者从不发生，
  /// 所以这里等到仓储真能读出期望内容为止（超时即失败，不用固定 sleep 撞运气）。
  Future<LibrarySnapshot> loadUntil(
    bool Function(LibrarySnapshot) done, {
    required String reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final snap = await LibraryRepository(directory: dir.path).load();
      if (done(snap)) return snap;
      if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  File taggedFile(String name, List<List<int>> frames) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(withId3(frames));
    return file;
  }

  /// 带真封面落盘器与时长探测的实例（模拟 main.dart 的装配形态）。
  LibraryState buildEnrichingState({
    LibraryRepository? repo,
    Playlist? target,
    Future<double> Function(String path)? probe,
  }) => LibraryState(
    prefs: prefs,
    repo: repo ?? LibraryRepository(directory: dir.path),
    importer: ImportService(
      playlist: target ?? Playlist(tracks: const []),
      toasts: toasts,
      covers: const CoverImageWriter(),
      coverDirectory: '${dir.path}${Platform.pathSeparator}covers',
      durationProbe: probe,
    ),
    toasts: toasts,
  );

  test('导入回填完成后会再落一次库：重启读档带标签、时长与封面', () async {
    final file = taggedFile('陈奕迅 - 十年.mp3', [
      textFrame('TIT2', '白玫瑰'),
      textFrame('TPE1', '陈奕迅'),
      textFrame('TALB', '认了吧'),
      apicFrame('image/png', onePixelPng),
    ]);
    final enriching = buildEnrichingState(probe: (path) async => 187.5);
    addTearDown(enriching.dispose);

    await enriching.importPaths([file.path]);
    // 入列立刻可见（首帧体验不许倒退）：此刻列表已有一首，标签还在后台补
    expect(enriching.tracks, hasLength(1));

    final snap = await loadUntil(
      (s) =>
          s.tracks.length == 1 &&
          s.tracks.single.hasDuration &&
          s.tracks.single.cover.isNotEmpty &&
          s.tracks.single.title == '白玫瑰',
      reason: '回填批次完成之后再落的那一次库',
    );
    expect(snap.tracks.single.artist, '陈奕迅');
    expect(snap.tracks.single.album, '认了吧');
    expect(snap.tracks.single.duration, 187.5);
    // 封面走真实落盘器：存档里存的是文件路径，重启后仍能显示
    expect(File(snap.tracks.single.cover).existsSync(), isTrue);
  });

  test('一批导入的回填只多落一次库，不是每首一次', () async {
    final files = [
      taggedFile('a.mp3', [textFrame('TIT2', '甲')]),
      taggedFile('b.mp3', [textFrame('TIT2', '乙')]),
      taggedFile('c.mp3', [textFrame('TIT2', '丙')]),
    ];
    final counting = _CountingRepository(directory: dir.path);
    final enriching = buildEnrichingState(
      repo: counting,
      probe: (path) async => 120,
    );
    addTearDown(enriching.dispose);

    await enriching.importPaths([for (final f in files) f.path]);
    final snap = await loadUntil(
      (s) => s.tracks.every((t) => t.hasDuration),
      reason: '三首歌的回填批次落库',
    );
    expect(snap.tracks.map((t) => t.title).toList(), ['甲', '乙', '丙']);
    // 导入本身一次 + 回填批次收尾一次；每首各落一次库的写法会到 4 次以上
    expect(counting.saves, lessThanOrEqualTo(2));
  });

  test('回填批次收尾会通知界面（不只是改了内存对象）', () async {
    final file = taggedFile('a.mp3', [textFrame('TIT2', '甲')]);
    final enriching = buildEnrichingState(probe: (path) async => 90);
    addTearDown(enriching.dispose);

    var notifications = 0;
    enriching.addListener(() => notifications++);
    await enriching.importPaths([file.path]);
    final before = notifications;

    await loadUntil(
      (s) => s.tracks.single.hasDuration,
      reason: '回填批次落库',
    );
    expect(notifications, greaterThan(before), reason: '回填完成后必须刷一次界面');
  });

  test('冷启动还原把缺元数据的旧记录补跑回填，并再落一次库', () async {
    final file = taggedFile('陈奕迅 - 十年.mp3', [
      textFrame('TIT2', '白玫瑰'),
      textFrame('TPE1', '陈奕迅'),
    ]);
    // 一份「C1 修之前就存下的脏档案」：只有文件名拆出来的猜测值、无时长、无封面
    final stale = Track(
      id: localIdFor(file.path),
      src: file.path,
      title: '十年',
      artist: '陈奕迅',
      duration: double.nan,
      isLocal: true,
    );
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(tracks: [stale], order: [stale.id], mode: PlayMode.list),
    );

    final fresh = buildEnrichingState();
    addTearDown(fresh.dispose);
    await fresh.restore();
    expect(fresh.tracks.single.title, '十年'); // 还原出来的还是旧值

    final snap = await loadUntil(
      (s) => s.tracks.single.title == '白玫瑰',
      reason: '还原时的自愈回填落库',
    );
    expect(snap.tracks.single.artist, '陈奕迅');
    // 标签里没有时长、探测也没接上：保持「未知」而不是编一个 0
    expect(snap.tracks.single.duration, isNaN);
  });

  test('还原时元数据齐备的曲目不重复回填，也不多落库', () async {
    final file = taggedFile('a.mp3', [textFrame('TIT2', '甲')]);
    final complete = Track(
      id: localIdFor(file.path),
      src: file.path,
      title: '甲',
      artist: '某人',
      album: '某碟',
      cover: '${dir.path}${Platform.pathSeparator}covers/exists.jpg',
      duration: 200,
      isLocal: true,
    );
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [complete],
        order: [complete.id],
        mode: PlayMode.list,
      ),
    );
    final counting = _CountingRepository(directory: dir.path);
    var probes = 0;
    final fresh = buildEnrichingState(
      repo: counting,
      probe: (path) async {
        probes += 1;
        return 300;
      },
    );
    addTearDown(fresh.dispose);

    await fresh.restore();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(fresh.tracks.single.title, '甲');
    expect(probes, 0, reason: '时长与封面都在了，不该再探一次');
    expect(counting.saves, 0, reason: '没有东西被补上就不必再落库');
  });

  // -- 终审 I4：prefs 的 currentId / order 必须如实同步 ----------------------

  test('落库时 currentId 跟着列表走：换曲写、删空清', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    await state.enrichmentSettled;
    final firstId = state.tracks.first.id;

    await state.setCurrent(firstId);
    // 以前 persist() 根本不碰这个键：只有播放层 flushPersist 会写，
    // 「只改列表不碰播放」的路径留下的就是空值或旧值。
    expect(await prefs.readString(StorageKeys.currentId), firstId);

    await state.removeTrack(firstId);
    expect(await prefs.readString(StorageKeys.currentId), state.currentId);

    await state.removeTrack(state.tracks.first.id);
    expect(state.currentId, isNull);
    expect(await prefs.readString(StorageKeys.currentId), isNull);
  });

  test('还原以文件仓为准：陈旧 order 被纠正、过期 currentId 被清掉', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    await state.enrichmentSettled;
    final ids = state.tracks.map((t) => t.id).toList();
    final firstId = ids.first;

    // 一份与文件仓矛盾的 prefs：顺序反着，光标指着「即将被删掉」的那首
    await prefs.writeJson(StorageKeys.order, ids.reversed.toList());
    await prefs.writeString(StorageKeys.currentId, firstId);
    await LibraryRepository(directory: dir.path).deleteTracks([firstId]);

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();
    await fresh.enrichmentSettled;

    final survived = ids.skip(1).toList();
    // 顺序一律以文件仓为准，prefs 那份陈旧值不许把列表带偏
    expect(fresh.tracks.map((t) => t.id).toList(), survived);
    // 痕迹要跟真相一致：纠正 prefs 的那份 order，并清掉指向已删曲目的光标
    expect(await prefs.readJson(StorageKeys.order), survived);
    expect(await prefs.readString(StorageKeys.currentId), isNull);
  });

  test('还原时光标仍在列表里就保留，两边一起指向同一首', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    await state.enrichmentSettled;
    final secondId = state.tracks.last.id;
    await prefs.writeString(StorageKeys.currentId, secondId);

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();
    await fresh.enrichmentSettled;

    expect(await prefs.readString(StorageKeys.currentId), secondId);
    expect(fresh.currentId, secondId);
  });

  test('现场自洽而文件仓没记光标：prefs 那份 currentId 也要接住', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    await state.enrichmentSettled;
    final ids = state.tracks.map((t) => t.id).toList();
    final thirdId = ids.last;
    // 老版本存的档 / 仓储重建后的档：顺序在、光标没记。prefs 那份现场是自洽的
    // （order 与文件仓逐位相同），它才是最后一次如实写入的光标。
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(tracks: state.tracks, order: ids),
    );
    await prefs.writeString(StorageKeys.currentId, thirdId);

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();
    await fresh.enrichmentSettled;

    // 以前 restore() 根本不读这个键：光标停在 replaceAll 默认的队首，
    // 现场也被 `_syncPrefsTrace` 改写成队首 —— 用户重启后光标跳回第一首。
    expect(fresh.currentId, thirdId);
    expect(await prefs.readString(StorageKeys.currentId), thirdId);
  });

  test('两边都指不到曲目：保持无光标，过期 currentId 被清掉而不是复活队首', () async {
    await state.importPaths(['/m/a.flac', '/m/b.flac']);
    await state.enrichmentSettled;
    final ids = state.tracks.map((t) => t.id).toList();
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(tracks: state.tracks, order: ids),
    );
    // 一个早已不在列表里的光标（停在已删曲目上的旧现场）
    await prefs.writeString(StorageKeys.currentId, 'local:ghost');

    final fresh = buildState();
    addTearDown(fresh.dispose);
    await fresh.restore();
    await fresh.enrichmentSettled;

    expect(fresh.currentId, isNull);
    expect(await prefs.readString(StorageKeys.currentId), isNull);
    expect(
      await prefs.readJson(StorageKeys.order),
      ids,
      reason: '顺序仍按文件仓纠正成现场',
    );
  });
}
