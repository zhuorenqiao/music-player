// test/state/library_state_test.dart
//
// 曲库状态层：导入 → 落库 → 冷启动还原、搜索关键词防抖与过滤、清空与删除。
// 仓储走真实文件（临时目录），只在需要观察落盘 / 防抖窗口时 await。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/toast_state.dart';

/// 等过防抖窗口：关键词只在 200ms 之后才成为「生效值」（与原版 debounce 一致）。
Future<void> afterDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: kSearchDebounceMs + 80));

void main() {
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
}
