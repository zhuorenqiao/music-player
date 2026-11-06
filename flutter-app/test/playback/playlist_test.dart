// test/playback/playlist_test.dart
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';

Track t(String id, {String? title, String src = '/a.flac'}) => Track(
      id: id,
      src: src,
      title: title ?? '歌$id',
      duration: 100,
    );

void main() {
  test('模式标签与循环顺序逐字对齐', () {
    expect(playModeLabel(PlayMode.list), '列表循环');
    expect(playModeLabel(PlayMode.one), '单曲循环');
    expect(playModeLabel(PlayMode.shuffle), '随机播放');
    expect(kModeOrder.map(playModeId), ['list', 'one', 'shuffle']);
    expect(Playlist(tracks: [t('1')]).cycleMode(), PlayMode.one);
    expect(Playlist(tracks: [t('1')], mode: PlayMode.shuffle).cycleMode(),
        PlayMode.list);
    expect(playModeFromId('nonsense'), PlayMode.list);
  });

  test('空列表 current 为 null、currentIndex -1', () {
    final p = Playlist(tracks: const []);
    expect(p.size, 0);
    expect(p.current, isNull);
    expect(p.currentIndex, -1);
    expect(p.nextIndex(), -1);
    expect(p.prevIndex(), -1);
    expect(p.totalDuration.isNaN, isFalse);
  });

  test('非法曲目在建列表时被丢掉', () {
    final p = Playlist(tracks: [
      {'id': 'a', 'src': '/a', 'title': 'A'},
      {'title': '缺 id'},
    ]);
    expect(p.size, 1);
    expect(p.tracks.first.title, 'A');
  });

  test('addAt 落在当前项之前时当前索引后移一位', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    p.addAt(t('0'), at: 0);
    expect(p.currentIndex, 2);
    expect(p.current!.id, '2');
    expect(p.tracks.map((e) => e.id), ['0', '1', '2', '3']);
  });

  test('空列表时 addAt 直接把当前项设为它', () {
    final p = Playlist(tracks: const []);
    final added = p.addAt(t('9'));
    expect(p.currentIndex, 0);
    expect(added!.id, '9');
  });

  test('addMany 克隆对象，返回 firstIndex 与 loadedFirst', () {
    final p = Playlist(tracks: const []);
    final r = p.addMany([t('1'), t('2')]);
    expect(r.added, 2);
    expect(r.firstIndex, 0);
    expect(r.loadedFirst, isTrue);
    expect(identical(p.tracks.first, p.tracks.first), isTrue);
    p.tracks.first.title = '改了';
    expect(p.tracks.first.title, '改了');
    final r2 = p.addMany([t('3')]);
    expect(r2.firstIndex, 2);
    expect(r2.loadedFirst, isFalse);

    // 原版 addMany 是克隆语义（src/lib/playlist.js:256 normalizeTrack 重建对象）：
    // 列表里的活对象必须不是调用方传入的那个。
    final src = t('9');
    p.addMany([src]);
    expect(identical(p.byId('9'), src), isFalse);
    src.title = '原对象';
    expect(p.byId('9')!.title, '歌9');

    // 未知时长（NaN）经 toJson→normalizeTrack 克隆往返后仍是 NaN。
    p.addMany([Track(id: 'n', src: '/n', title: 'N')]);
    expect(p.tracks.last.duration.isNaN, isTrue);
  });

  test('removeById 三种位置各按原版处理', () {
    final before = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 2);
    before.removeById('1');
    expect(before.currentIndex, 1);
    expect(before.current!.id, '3');
    expect(before.removeById('1').removed, isNull);

    final current = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    final r = current.removeById('2');
    expect(r.currentChanged, isTrue);
    expect(r.removed!.id, '2');
    expect(current.current!.id, '3');

    final last = Playlist(tracks: [t('1'), t('2')], currentIndex: 1);
    last.removeById('2');
    expect(last.current!.id, '1');

    final only = Playlist(tracks: [t('1')], currentIndex: 0);
    only.removeById('1');
    expect(only.size, 0);
    expect(only.currentIndex, -1);
    expect(only.current, isNull);
  });

  test('move 越界返回 false，当前项跟随移动', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 0);
    expect(p.move('1', 1), isTrue);
    expect(p.currentIndex, 1);
    expect(p.tracks.map((e) => e.id), ['2', '1', '3']);
    expect(p.move('1', 5), isFalse);
    expect(p.move('nope', 1), isFalse);

    // 原版 move 的另两种游标补偿（src/lib/playlist.js:316-319）。
    final crossed = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    expect(crossed.move('1', 1), isTrue); // at=0 < cur=1，to=1 >= cur
    expect(crossed.currentIndex, 0);
    expect(crossed.current!.id, '2');
    final back = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    expect(back.move('3', -2), isTrue); // at=2 > cur=1，to=0 <= cur
    expect(back.currentIndex, 2);
    expect(back.current!.id, '2');
  });

  test('list 模式环形推进，one 模式 auto 时原地重播', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 2);
    expect(p.nextIndex(), 0);
    expect(p.prevIndex(), 1);
    final one = Playlist(tracks: [t('1'), t('2')], mode: PlayMode.one);
    expect(one.nextIndex(auto: true), 0);
    expect(one.nextIndex(), 1);

    // SHUFFLE 模式下 auto 不享受原地重播，照旧推进洗牌游标（原版 349-364 的分支顺序）。
    final sh = Playlist(
      tracks: [t('1'), t('2'), t('3')],
      mode: PlayMode.shuffle,
      random: Random(9),
    );
    expect(sh.nextIndex(auto: true), isNot(sh.currentIndex));
  });

  test('shuffle 一轮内不重复，一轮结束重洗且首项不与上一项相同', () {
    final p = Playlist(
      tracks: [t('1'), t('2'), t('3'), t('4')],
      mode: PlayMode.shuffle,
      random: Random(7),
    );
    // 一轮 = size 个槽位，从建表时保留在队首的当前项算起（原版 playlist.js:447-452）。
    // 简报原文的循环从队首后一格开始采 4 个值，第 4 个已跨入下一轮，与原版
    // 「一轮内不重复」不变量矛盾（Dart Random(7) 下实测为 [1,3,2,3]），按原版修正。
    final firstRound = <int>[p.currentIndex];
    for (var i = 0; i < 3; i++) {
      firstRound.add(p.nextIndex());
      p.setCurrentIndex(firstRound.last);
    }
    expect(firstRound.toSet().length, 4);
    final fifth = p.nextIndex();
    expect(fifth, isNot(firstRound.last));
    // nextIndex 的副作用可直接观察：越界重洗后游标停在新队列队首。
    expect(p.shuffleOrderForTest.length, 4);
    expect(p.shuffleOrderForTest.first, fifth);
  });

  test('手动点选会把随机游标同步到队列位置后继续推进', () {
    final p = Playlist(
      tracks: [t('1'), t('2'), t('3')],
      mode: PlayMode.shuffle,
      random: Random(3),
    );
    p.setCurrentById('3');
    final afterManual = p.nextIndex();
    final queue = p.shuffleOrderForTest;
    // 原版 JS 用 queue[String(idx)] != null 检查下标有效；Dart 列表不能按字符串下标取值，
    // 改为「该索引在队列中占有一格」这一等价完整性断言。
    expect(
        queue.contains(p.indexOfId(p.tracks[afterManual].id)), isTrue);
    expect(afterManual, isNot(2));
  });

  test('列表变化后重建队列，totalDuration 跳过未知时长', () {
    final p = Playlist(tracks: [
      {'id': '1', 'src': '/a', 'title': 'A', 'duration': 100},
      {'id': '2', 'src': '/b', 'title': 'B'},
    ]);
    expect(p.totalDuration, 100);
    p.addAt(t('3'));
    expect(p.shuffleOrderForTest.length, p.size);
  });
}
