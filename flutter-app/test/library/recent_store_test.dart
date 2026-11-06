// test/library/recent_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/recent_store.dart';
import 'package:light_music/playback/track.dart';

Track t(String id) =>
    Track(id: id, src: '/$id.flac', title: '歌$id', artist: '某人');

void main() {
  late AppPrefs prefs;
  late int clock;
  late RecentStore store;

  setUp(() {
    prefs = AppPrefs.inMemory();
    clock = 1000000;
    store = RecentStore(prefs, now: () => clock);
  });

  test('真正出声才写入，重播置顶且无重复条目', () {
    store.record(t('1'));
    store.record(t('2'));
    expect(store.entries.map((e) => e.id), ['2', '1']);

    clock += 600;
    store.record(t('1'));
    expect(store.entries.map((e) => e.id), ['1', '2']);
    expect(store.entries.length, 2);
    // 置顶的同时刷新时间戳：排序依据是「最近一次播放」
    expect(store.entries.first.at, clock);
  });

  test('500ms 内的重复事件被忽略', () {
    store.record(t('1'));
    clock += 100;
    store.record(t('1'));
    expect(store.entries.length, 1);
    expect(store.entries.single.at, 1000000);

    // 窗口边界是「小于 500ms」：正好 500ms 就要重新记账
    clock = 1000000 + 500;
    store.record(t('1'));
    expect(store.entries.single.at, clock);
  });

  test('上限 50 条，超出丢最旧', () {
    for (var i = 0; i < 60; i++) {
      clock += 600;
      store.record(t('$i'));
    }
    expect(store.entries.length, 50);
    expect(store.entries.first.id, '59');
    expect(store.entries.last.id, '10');
  });

  test('落盘并可 restore', () async {
    store.record(t('1'));
    await store.flushForTest();

    final fresh = RecentStore(prefs, now: () => clock);
    await fresh.restore();
    expect(fresh.entries.single.id, '1');
    expect(fresh.entries.single.title, '歌1');
    expect(fresh.entries.single.artist, '某人');
    // 时长未知时必须写 null，不能把 NaN 写进 JSON
    expect(fresh.entries.single.duration, isNull);

    final raw = await prefs.readJson(StorageKeys.recent);
    expect(raw, isA<List<Object?>>());
    expect((raw! as List<Object?>).single, containsPair('duration', null));
  });

  test('脏数据回退空列表', () async {
    prefs.debugSeed(StorageKeys.recent, '[bad');
    final fresh = RecentStore(prefs);
    await fresh.restore();
    expect(fresh.entries, isEmpty);
    // readJson 顺手清掉了脏数据，不会反复报错
    expect(prefs.debugContains(StorageKeys.recent), isFalse);
  });

  test('单条结构坏掉只丢那一条，restore 后按存档顺序还原', () async {
    prefs.debugSeed(
      StorageKeys.recent,
      '[{"id":"1","title":"甲","at":30},'
          '{"id":"","title":"乙","at":20},'
          '{"title":"丙","at":10},'
          '{"id":"4","title":"丁"},'
          '{"id":"5","title":"戊","at":"x"},'
          '{"id":"1","title":"重复","at":40}]',
    );
    final fresh = RecentStore(prefs);
    await fresh.restore();
    expect(fresh.entries.map((e) => e.id), ['1']);
    expect(fresh.entries.single.title, '甲');
  });

  test('restore 乐观地认为曲目都在播放列表里', () async {
    store.record(t('1'));
    await store.markInPlaylist(const {});
    final fresh = RecentStore(prefs, now: () => clock);
    await fresh.restore();
    expect(fresh.entries.single.inPlaylist, isTrue);
  });

  test('不在列表里的条目标记为失效', () async {
    store.record(t('1'));
    store.record(t('2'));
    await store.markInPlaylist({'1'});
    expect(store.entries.firstWhere((e) => e.id == '2').inPlaylist, isFalse);
    expect(store.entries.firstWhere((e) => e.id == '1').inPlaylist, isTrue);
  });

  test('remove 与 clear', () async {
    store.record(t('1'));
    store.record(t('2'));
    await store.remove('1');
    expect(store.entries.map((e) => e.id), ['2']);

    final afterRemove = RecentStore(prefs, now: () => clock);
    await afterRemove.restore();
    expect(afterRemove.entries.map((e) => e.id), ['2']);

    await store.clear();
    expect(store.entries, isEmpty);
    final afterClear = RecentStore(prefs, now: () => clock);
    await afterClear.restore();
    expect(afterClear.entries, isEmpty);
  });

  group('相对时间文案', () {
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;

    test('刚刚 / 分钟前 / 小时前', () {
      expect(formatRelativeTime(0, now: 30 * 1000), '刚刚');
      expect(formatRelativeTime(0, now: 5 * minute), '5 分钟前');
      expect(formatRelativeTime(0, now: 3 * hour + 1 * minute), '3 小时前');
      // 未来时间（时钟回拨）按「刚刚」兜底，不出现负数
      expect(formatRelativeTime(1000, now: 0), '刚刚');
    });

    test('昨天与几天前', () {
      expect(formatRelativeTime(0, now: day + 2 * hour), '昨天');
      expect(formatRelativeTime(0, now: 3 * day), '3 天前');
      // 恰好两天不再是「昨天」
      expect(formatRelativeTime(0, now: 2 * day), '2 天前');
    });

    /// 终审 minor 6 的缺陷复现（改前红）：从前这里按「经过 24~48 小时」算昨天，
    /// 原版按**日历日**算（recent-store.js:158-167：`sameDay(new Date(timestamp),
    /// new Date(now - day))`）。差别出现在跨过两个日历日但只过了 24~48 小时的窗口：
    /// 3 月 10 日 22:00 听的一首，到 3 月 12 日凌晨 1 点已经隔了一整个日历日，
    /// 原版说「1 天前」，我们却说「昨天」。
    test('「昨天」按日历日判定，不是按经过的小时数', () {
      final marTen = DateTime.parse('2026-03-10T22:00:00').millisecondsSinceEpoch;

      // 经过 27 小时，但日历上已经是隔了一天 → 不是昨天
      final twelveOhOne = DateTime.parse('2026-03-12T01:00:00').millisecondsSinceEpoch;
      expect(
        formatRelativeTime(marTen, now: twelveOhOne),
        '1 天前',
        reason: '24~48 小时这个窗口里还要看日历日：条目属于「前天」就不是「昨天」',
      );

      // 同一批条目，第二天晚上看就是昨天（日历日差 1）
      final elevenOhTwentyThree =
          DateTime.parse('2026-03-11T23:00:00').millisecondsSinceEpoch;
      expect(formatRelativeTime(marTen, now: elevenOhTwentyThree), '昨天');

      // 满 48 小时（还是隔了一天）→ 2 天前
      final twelveOhTwentyThree =
          DateTime.parse('2026-03-12T22:00:00').millisecondsSinceEpoch;
      expect(formatRelativeTime(marTen, now: twelveOhTwentyThree), '2 天前');
    });

    /// 原版把「不足一天」短路在日历日判定之前（recent-store.js:154-156），
    /// 所以前一天深夜的条目在次日凌晨仍然报「N 小时前」而不是「昨天」。
    /// 这条用例把顺序钉住，免得将来「顺手」把它改成日历日优先。
    test('不足 24 小时一律走「小时前」，与原版同一顺序', () {
      final marTenNight = DateTime.parse('2026-03-10T22:00:00').millisecondsSinceEpoch;
      final marElevenOneAm = DateTime.parse('2026-03-11T01:00:00').millisecondsSinceEpoch;
      expect(formatRelativeTime(marTenNight, now: marElevenOneAm), '3 小时前');
    });

    test('一周以上显示日期，跨年带年份', () {
      expect(
        formatRelativeTime(
          _millis('2026-01-01'),
          now: _millis('2026-03-05'),
          localeDate: _dateOf,
        ),
        '1月1日',
      );
      expect(
        formatRelativeTime(
          _millis('2025-12-30'),
          now: _millis('2026-01-10'),
          localeDate: _dateOf,
        ),
        contains('2025'),
      );
    });
  });

  test('entries 是只读视图', () {
    store.record(t('1'));
    expect(() => store.entries.clear(), throwsUnsupportedError);
  });
}

DateTime _dateOf(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);

int _millis(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;
