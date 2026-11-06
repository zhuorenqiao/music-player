// test/state/recent_state_test.dart
//
// 「最近播放」状态层的两条契约（终审 C2）：
//   1. 存档一变就通知订阅者 —— 原版是 `recent` 状态一变即重绘，之前只有
//      `refresh()` / `clear()` 自己喊，`TransportController` 记进来的条目
//      整场会话都画不出来（要重开 app 才看到）；
//   2. 回调随 `dispose()` 干净解开：store 不该再攥着已释放的 ChangeNotifier。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/library/recent_store.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/recent_state.dart';

Track t(String id) =>
    Track(id: id, src: '/$id.flac', title: '歌$id', artist: '某人', duration: 100);

void main() {
  test('store.record 之后监听者收到一次通知，条目真的变长', () async {
    final store = RecentStore(AppPrefs.inMemory());
    final state = RecentState(store);
    addTearDown(state.dispose);

    var notifications = 0;
    state.addListener(() => notifications++);

    store.record(t('1'));

    expect(notifications, 1, reason: '记上一条最近播放必须立刻刷界面（C2）');
    expect(state.entries, hasLength(1));
    expect(state.entries.first.id, '1');
  });

  test('remove / clear / markInPlaylist 同样通知订阅者', () async {
    final store = RecentStore(AppPrefs.inMemory());
    final state = RecentState(store);
    addTearDown(state.dispose);

    store.record(t('1'));
    store.record(t('2'));
    await store.flushForTest();
    var notifications = 0;
    state.addListener(() => notifications++);

    await store.markInPlaylist({'1'});
    expect(notifications, greaterThanOrEqualTo(1));
    expect(
      state.entries.firstWhere((e) => e.id == '2').inPlaylist,
      isFalse,
      reason: '失效标记变了也要通知',
    );

    final before = notifications;
    await store.remove('2');
    expect(notifications, greaterThan(before), reason: '删一条也要通知');

    final beforeClear = notifications;
    await store.clear();
    expect(notifications, greaterThan(beforeClear), reason: '清空也要通知');
    expect(state.entries, isEmpty);
  });

  test('RecentState.dispose 之后不再被 store 回调（不泄漏）', () async {
    final store = RecentStore(AppPrefs.inMemory());
    final state = RecentState(store);
    var notifications = 0;
    state.addListener(() => notifications++);

    state.dispose();
    store.record(t('1'));

    expect(notifications, 0);
    // dispose 之后 store 仍可正常记账，只是不再喊到已释放的状态层
    expect(store.entries, hasLength(1));
  });

  test('RecentState.fake 也接上同一条通知链', () {
    final state = RecentState.fake();
    addTearDown(state.dispose);

    var notifications = 0;
    state.addListener(() => notifications++);
    state.store.record(t('9'));

    expect(notifications, 1);
    expect(state.entries.single.id, '9');
  });
}
