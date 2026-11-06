// test/library/library_repository_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('light-lib'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Track t(String id) => Track(
    id: id,
    src: '/$id.flac',
    title: '歌$id',
    artist: '某人',
    duration: 100,
  );

  String primaryPath() => '${dir.path}/library.json';
  String backupPath() => '${dir.path}/library.json.bak';
  String tmpPath() => '${dir.path}/library.json.tmp';

  test('空目录 load 得到空快照而非异常', () async {
    final repo = LibraryRepository(directory: dir.path);
    final snap = await repo.load();
    expect(snap.tracks, isEmpty);
    expect(snap.order, isEmpty);
    expect(snap.currentId, isNull);
    expect(snap.mode, PlayMode.list);
    expect(snap.volume, isNull);
    expect(snap.muted, isFalse);
    expect(snap.corrupted, isFalse);
    expect(repo.corrupted, isFalse);
  });

  test('保存后读回，顺序与音量都在', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(
      LibrarySnapshot(
        tracks: [t('1'), t('2')],
        order: ['1', '2'],
        currentId: '2',
        mode: PlayMode.shuffle,
        volume: 0.32,
        muted: true,
      ),
    );
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['1', '2']);
    expect(snap.tracks.first.title, '歌1');
    expect(snap.tracks.first.artist, '某人');
    expect(snap.tracks.first.duration, 100);
    expect(snap.order, ['1', '2']);
    expect(snap.currentId, '2');
    expect(snap.mode, PlayMode.shuffle);
    expect(snap.volume, 0.32);
    expect(snap.muted, isTrue);
    expect(snap.corrupted, isFalse);
    expect(repo.corrupted, isFalse);
  });

  test('正式文件坏掉时回退 .bak 并保留脏文件', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    File(primaryPath()).writeAsStringSync('{ 坏掉的 json');
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['1']);
    expect(snap.order, ['1']);
    expect(snap.corrupted, isTrue);
    expect(repo.corrupted, isTrue);
    // 回退只读不写：脏文件留在原处，方便人工排查
    expect(File(primaryPath()).readAsStringSync(), '{ 坏掉的 json');
  });

  test('两个文件都坏时得到空快照，不抛', () async {
    File(primaryPath()).writeAsStringSync('x');
    File(backupPath()).writeAsStringSync('y');
    final repo = LibraryRepository(directory: dir.path);
    final snap = await repo.load();
    expect(snap.tracks, isEmpty);
    expect(snap.order, isEmpty);
    expect(snap.mode, PlayMode.list);
    expect(snap.corrupted, isTrue);
    expect(repo.corrupted, isTrue);
  });

  test('非法条目在 load 时被丢弃而不炸整份数据', () async {
    File(primaryPath()).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'tracks': [
          {'id': '1', 'src': '/a.flac', 'title': 'A'},
          {'title': '缺 id'},
          'not-a-map',
          {'id': 5, 'src': '/b.flac', 'title': 'id 不是字符串'},
        ],
        'order': ['1', 'bad'],
      }),
    );
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks.map((e) => e.id), ['1']);
    expect(snap.order, ['1']);
    // 缺字段走默认值而不是整份失败
    expect(snap.currentId, isNull);
    expect(snap.mode, PlayMode.list);
    expect(snap.volume, isNull);
    expect(snap.muted, isFalse);
  });

  test('deleteTracks 同步清 order 与 currentId', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(
      LibrarySnapshot(
        tracks: [t('1'), t('2')],
        order: ['1', '2'],
        currentId: '1',
      ),
    );
    await repo.deleteTracks(['1']);
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['2']);
    expect(snap.order, ['2']);
    expect(snap.currentId, isNull);

    // 删的不是当前曲目时，currentId 必须留着
    await repo.save(
      LibrarySnapshot(
        tracks: [t('1'), t('2')],
        order: ['1', '2'],
        currentId: '2',
      ),
    );
    await repo.deleteTracks(['1']);
    final second = await repo.load();
    expect(second.tracks.map((e) => e.id), ['2']);
    expect(second.order, ['2']);
    expect(second.currentId, '2');
  });

  test('并发保存不产生半截文件', () async {
    final repo = LibraryRepository(directory: dir.path);
    // 每份快照长度不同：交错写入会把文件截断成半截，或让 tracks 与 order 混代
    LibrarySnapshot gen(int count) => LibrarySnapshot(
      tracks: [for (var j = 0; j < count; j++) t('$j')],
      order: [for (var j = 0; j < count; j++) '$j'],
    );
    await Future.wait([for (var i = 1; i <= 8; i++) repo.save(gen(i))]);

    List<Object?> idsOf(Map<String, Object?> json) => (json['tracks'] as List)
        .map((e) => (e as Map<String, Object?>)['id'])
        .toList();

    // 正式文件必须能直接解析出完整 JSON：半截写入会在这里炸
    final primary = (jsonDecode(File(primaryPath()).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final ids = idsOf(primary);
    expect(ids, isNotEmpty);
    expect(primary['order'], ids); // tracks 与 order 必须来自同一次保存
    expect(ids, [for (var j = 0; j < ids.length; j++) '$j']);

    final backup = (jsonDecode(File(backupPath()).readAsStringSync()) as Map)
        .cast<String, Object?>();
    expect(backup['order'], idsOf(backup));

    final reader = LibraryRepository(directory: dir.path);
    final snap = await reader.load();
    expect(snap.tracks.length, ids.length);
    expect(snap.order, ids);
    expect(snap.corrupted, isFalse);
    expect(reader.corrupted, isFalse);
    expect(File(tmpPath()).existsSync(), isFalse);
  });

  test('order 缺项补末尾、重复只留一次，currentId 指空归零', () async {
    File(primaryPath()).writeAsStringSync(
      jsonEncode({
        'tracks': [
          {'id': '1', 'src': '/1.flac', 'title': '一'},
          {'id': '2', 'src': '/2.flac', 'title': '二'},
          {'id': '1', 'src': '/1b.flac', 'title': '重复的 1'},
        ],
        'order': ['2', '2', 'ghost'],
        'currentId': 'ghost',
      }),
    );
    final snap = await LibraryRepository(directory: dir.path).load();
    expect(snap.tracks.map((e) => e.id), ['1', '2']);
    expect(snap.tracks.first.title, '一');
    expect(snap.order, ['2', '1']);
    expect(snap.currentId, isNull);
  });

  test('第二次保存把上一份滚进 .bak', () async {
    final repo = LibraryRepository(directory: dir.path);
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    await repo.save(LibrarySnapshot(tracks: [t('2')], order: ['2']));
    // 直接读正式文件确认当前是第二份
    final current = (jsonDecode(File(primaryPath()).readAsStringSync()) as Map)
        .cast<String, Object?>();
    expect((current['tracks'] as List).single, containsPair('id', '2'));
    File(primaryPath()).writeAsStringSync('{');
    final snap = await repo.load();
    expect(snap.tracks.map((e) => e.id), ['1']);
  });

  test('目录不存在时 save 自动创建', () async {
    final nested = '${dir.path}/a/b/c';
    final repo = LibraryRepository(directory: nested);
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    final snap = await LibraryRepository(directory: nested).load();
    expect(snap.tracks.map((e) => e.id), ['1']);
  });

  test('fileName 可改，不碰默认文件名', () async {
    final repo = LibraryRepository(directory: dir.path, fileName: 'shelf.json');
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    expect(File('${dir.path}/shelf.json').existsSync(), isTrue);
    expect(File(primaryPath()).existsSync(), isFalse);
    final snap = await LibraryRepository(
      directory: dir.path,
      fileName: 'shelf.json',
    ).load();
    expect(snap.tracks.map((e) => e.id), ['1']);
  });

  test('落盘失败不抛，也不破坏挡路的文件', () async {
    final blocker = File('${dir.path}/blocked')..writeAsStringSync('x');
    final repo = LibraryRepository(directory: blocker.path);
    await repo.save(LibrarySnapshot(tracks: [t('1')], order: ['1']));
    expect(blocker.readAsStringSync(), 'x');
    final snap = await repo.load();
    expect(snap.tracks, isEmpty);
  });
}
