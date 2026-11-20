// test/playback/screen_awake_keeper_test.dart
//
// 「播放期间屏幕常亮」的绑定层：只验开关语义（什么时候开 / 什么时候放开 /
// 重复通知是否幂等 / 释放是否复位），不碰真实平台通道。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/screen_wake_lock.dart';
import 'package:light_music/playback/screen_awake_keeper.dart';
import 'package:light_music/playback/transport_controller.dart';

/// 记录每一次平台开关调用的替身。
class _RecordingLock implements ScreenWakeLock {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setKeepAwake(bool on) {
    calls.add(on);
    return Future<void>.value();
  }
}

void main() {
  test('开播即常亮，暂停即放开', () {
    final lock = _RecordingLock();
    final view = ValueNotifier<TransportView>(TransportView());
    final keeper = ScreenAwakeKeeper(view: view, lock: lock);
    addTearDown(keeper.dispose);
    addTearDown(view.dispose);

    expect(lock.calls, isEmpty, reason: '初始未播放不该要求常亮');

    view.value = TransportView(playing: true);
    expect(lock.calls, <bool>[true]);
    expect(keeper.keepAwake, isTrue);

    view.value = TransportView();
    expect(lock.calls, <bool>[true, false]);
    expect(keeper.keepAwake, isFalse);
  });

  test('播放态没变时重复通知不重复调平台', () {
    final lock = _RecordingLock();
    final view = ValueNotifier<TransportView>(TransportView());
    final keeper = ScreenAwakeKeeper(view: view, lock: lock);
    addTearDown(keeper.dispose);
    addTearDown(view.dispose);

    view.value = TransportView(playing: true);
    // view 因别的字段变化再发一次通知，playing 没变：平台开关不该被再碰一次。
    view.value = TransportView(playing: true, volume: 0.35);
    expect(lock.calls, <bool>[true]);
  });

  test('构造时已在播放：立刻要求常亮', () {
    final lock = _RecordingLock();
    final view = ValueNotifier<TransportView>(TransportView(playing: true));
    final keeper = ScreenAwakeKeeper(view: view, lock: lock);
    addTearDown(keeper.dispose);
    addTearDown(view.dispose);

    expect(lock.calls, <bool>[true]);
  });

  test('dispose 时还在播：主动复位，之后的视图变化不再触发', () {
    final lock = _RecordingLock();
    final view = ValueNotifier<TransportView>(TransportView());
    final keeper = ScreenAwakeKeeper(view: view, lock: lock);

    view.value = TransportView(playing: true);
    expect(lock.calls, <bool>[true]);

    keeper.dispose();
    expect(lock.calls, <bool>[true, false]);

    view.value = TransportView();
    expect(lock.calls, <bool>[true, false], reason: '监听已摘，不该再调平台');
    view.dispose();
  });
}
