// lib/playback/screen_awake_keeper.dart
//
// 把「正在播放」翻译成「屏幕常亮」。
//
// 只订阅 [TransportController.view]（语义快照，含 playing），不碰进度 notifier
// —— 进度每秒好几次，绝不能让它把平台通道打成热线。`view` 只在播放 / 暂停、
// 切歌、损坏、熔断这类语义变化时通知，正好是常亮需要跟着变的全部时刻。
//
// 三条约束：
//   - 幂等：view 的重复同态通知（例如同一次暂停引发的多次 publish）不重复
//     调平台，原生侧也不会因为多开多关而错乱；
//   - 失败不冒泡：平台通道缺失只是屏幕照常休眠，绝不打断播放编排；
//   - 释放即复位：应用卸载 / 测试收尾时若还在播，主动关掉常亮，别把窗口 flag
//     留给下一个界面。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/screen_wake_lock.dart';
import 'transport_controller.dart';

/// 播放期间保持屏幕常亮。
class ScreenAwakeKeeper {
  ScreenAwakeKeeper({required this.view, required this.lock})
    : _awake = view.value.playing {
    view.addListener(_onViewChanged);
    // 构造时就已处于播放态（热重启 / 装配晚于恢复）也得把常亮打开。
    if (_awake) unawaited(_apply(true));
  }

  /// 播放态快照的来源（`TransportController.view`）。
  final ValueListenable<TransportView> view;

  /// 平台开关。
  final ScreenWakeLock lock;

  bool _awake;
  bool _disposed = false;

  /// 当前是否要求屏幕常亮（测试断言用）。
  bool get keepAwake => _awake;

  void _onViewChanged() {
    if (_disposed) return;
    final playing = view.value.playing;
    if (playing == _awake) return;
    _awake = playing;
    unawaited(_apply(playing));
  }

  Future<void> _apply(bool on) async {
    try {
      await lock.setKeepAwake(on);
    } catch (error) {
      // 实现侧已经吞过通道错误；这里再兜一层，防止注入的替身抛错打断调用方。
      debugPrint('screen wake lock failed: $error');
    }
  }

  /// 停掉监听并复位常亮。幂等。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    view.removeListener(_onViewChanged);
    if (_awake) {
      _awake = false;
      unawaited(_apply(false));
    }
  }
}
