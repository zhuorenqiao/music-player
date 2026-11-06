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

    // 空列表上任何定位都不能造出当前项（原版 playlist.js:205-209、220-223）。
    expect(p.setCurrentIndex(0), isNull);
    expect(p.currentIndex, -1);
    expect(p.setCurrentById('nope'), isNull);
    expect(p.currentIndex, -1);
  });

  test('非法曲目在建列表时被丢掉', () {
    final p = Playlist(tracks: [
      {'id': 'a', 'src': '/a', 'title': 'A'},
      {'title': '缺 id'},
    ]);
    expect(p.size, 1);
    expect(p.tracks.first.title, 'A');

    // 单条插入与批量追加遇到非法曲目同样丢弃，且不改列表
    // （原版 playlist.js:231-237 返回 null；255-259 返回 {0,-1,false}）。
    expect(p.addAt(Track(id: '', src: '/x', title: '空 id')), isNull);
    expect(p.addAt(Track(id: 'b', src: '', title: '空 src')), isNull);
    expect(p.size, 1);

    final r = p.addMany([
      Track(id: '', src: '/x', title: '空 id'),
      Track(id: 'y', src: '', title: '空 src'),
    ]);
    expect(r.added, 0);
    expect(r.firstIndex, -1);
    expect(r.loadedFirst, isFalse);
    expect(p.size, 1);
    expect(p.currentIndex, 0);
  });

  test('addAt 落在当前项之前时当前索引后移一位', () {
    final p = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    p.addAt(t('0'), at: 0);
    expect(p.currentIndex, 2);
    expect(p.current!.id, '2');
    expect(p.tracks.map((e) => e.id), ['0', '1', '2', '3']);

    // 定位不到 id 时返回当前曲目且不改状态（原版 playlist.js:220-223）。
    expect(p.setCurrentById('nope')!.id, '2');
    expect(p.currentIndex, 2);
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
    expect(p.currentIndex, 0);
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

    // 但 byId 必须返回列表里的**活对象**而非副本（spec §8 的元数据回填依赖此点）：
    // 身份与 tracks 中同一格相同，且写穿 byId 能在 tracks 里读到。
    // 若 byId 返回 copy()，下面两条都会失败。
    expect(identical(p.byId('9'), p.tracks[p.indexOfId('9')]), isTrue);
    p.byId('9')!.title = '写穿';
    expect(p.tracks[p.indexOfId('9')].title, '写穿');

    // 未知时长（NaN）经 toJson→normalizeTrack 克隆往返后仍是 NaN。
    p.addMany([Track(id: 'n', src: '/n', title: 'N')]);
    expect(p.tracks.last.duration.isNaN, isTrue);
  });

  test('removeById 三种位置各按原版处理', () {
    // 删当前项之前的曲目：索引整体前移一位，当前曲目没换 → currentChanged=false。
    final before = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 2);
    final rBefore = before.removeById('1');
    expect(rBefore.removed!.id, '1');
    expect(rBefore.currentChanged, isFalse);
    expect(before.currentIndex, 1);
    expect(before.current!.id, '3');

    // 删当前项之后的曲目：索引与当前曲目都不动 → currentChanged=false。
    final after = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 0);
    final rAfter = after.removeById('3');
    expect(rAfter.removed!.id, '3');
    expect(rAfter.currentChanged, isFalse);
    expect(after.currentIndex, 0);
    expect(after.current!.id, '1');

    // 删当前项：落到下一首 → currentChanged=true。
    final current = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    final r = current.removeById('2');
    expect(r.currentChanged, isTrue);
    expect(r.removed!.id, '2');
    expect(current.current!.id, '3');

    // 删末尾的当前项：退到新的末尾 → currentChanged=true。
    final last = Playlist(tracks: [t('1'), t('2')], currentIndex: 1);
    final rLast = last.removeById('2');
    expect(rLast.currentChanged, isTrue);
    expect(last.current!.id, '1');

    // 删空列表里的最后一首：索引 -1 → currentChanged=true。
    final only = Playlist(tracks: [t('1')], currentIndex: 0);
    final rOnly = only.removeById('1');
    expect(rOnly.currentChanged, isTrue);
    expect(only.size, 0);
    expect(only.currentIndex, -1);
    expect(only.current, isNull);

    // 找不到的 id：什么都不改（原版 playlist.js:278-280）。
    final missing = only.removeById('1');
    expect(missing.removed, isNull);
    expect(missing.currentChanged, isFalse);
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

    // delta=0 落在合法区间内：返回 true，顺序与当前项都不变（原版 playlist.js:307-322）。
    final noop = Playlist(tracks: [t('1'), t('2'), t('3')], currentIndex: 1);
    expect(noop.move('1', 0), isTrue);
    expect(noop.currentIndex, 1);
    expect(noop.current!.id, '2');
    expect(noop.tracks.map((e) => e.id), ['1', '2', '3']);
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

    // SHUFFLE 模式的 prevIndex 回退游标（原版 playlist.js:372-384 → 391-410）。
    final sp = Playlist(
      tracks: [t('1'), t('2'), t('3')],
      mode: PlayMode.shuffle,
      random: Random(3),
    );
    expect(sp.shuffleOrderForTest, [0, 2, 1]);
    // 当前项在队首（游标 0），回退越界 → 绕到队尾，即 front-wrap。
    expect(sp.prevIndex(), sp.shuffleOrderForTest.last);
    expect(sp.prevIndex(), 1);
    // 非绕回情形：当前项在队列中段，退一格拿到队列里的前一项。
    sp.setCurrentById('3');
    expect(sp.shuffleOrderForTest.indexOf(sp.currentIndex), 1);
    expect(sp.prevIndex(), 0);
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
    // 建表队列（Random(3) 固定种子 → [0,2,1]），当前项被保留在队首。
    expect(p.shuffleOrderForTest, [0, 2, 1]);

    p.setCurrentById('3');
    final queue = p.shuffleOrderForTest;
    expect(p.currentIndex, 2);

    // 关键：手动点选后游标必须落在「当前项在队列中的位置」，而不是留在队首。
    final pos = queue.indexOf(p.currentIndex);
    expect(pos, 1);

    // 于是 nextIndex 的推进起点就是 pos，返回 pos 的后一格（Random(3) 下为 1）。
    // 若 _syncShuffleCursor 缺失，游标会停在 0，这里会拿到 queue[1] == 2。
    final afterManual = p.nextIndex();
    expect(afterManual, 1);
    expect(queue[pos + 1], afterManual);
    expect(afterManual, isNot(p.currentIndex));
  });

  test('列表变化后重建队列，totalDuration 跳过未知时长', () {
    final p = Playlist(tracks: [
      {'id': '1', 'src': '/a', 'title': 'A', 'duration': 100},
      {'id': '2', 'src': '/b', 'title': 'B'},
    ]);
    expect(p.totalDuration, 100);
    p.addAt(t('3'));
    expect(p.shuffleOrderForTest.length, p.size);

    // clear 返回被清空的曲目本体，并重置当前项与洗牌游标（原版 playlist.js:329-336）。
    final old = p.clear();
    expect(old.map((e) => e.id), ['1', '2', '3']);
    expect(p.size, 0);
    expect(p.currentIndex, -1);
    expect(p.current, isNull);
    expect(p.totalDuration, 0);
    expect(p.shuffleOrderForTest, isEmpty);
    expect(p.nextIndex(), -1);
    expect(p.prevIndex(), -1);
  });

  test('replaceAll 整体替换：当前项回队首、洗牌队列按新长度重建', () {
    final p = Playlist(tracks: [t('old1'), t('old2')], mode: PlayMode.shuffle);
    final next = [t('c'), t('a'), t('b')];

    p.replaceAll(next);

    expect(p.tracks.map((e) => e.id), ['c', 'a', 'b']);
    expect(p.currentIndex, 0);
    expect(p.current?.id, 'c');
    // 传入的列表原样持有，不再经 toJson 克隆成副本
    expect(identical(p.tracks.first, next.first), isTrue);
    expect(p.shuffleOrderForTest.length, 3);

    p.replaceAll(const []);
    expect(p.size, 0);
    expect(p.currentIndex, -1);
    expect(p.current, isNull);
    expect(p.shuffleOrderForTest, isEmpty);
  });
}
