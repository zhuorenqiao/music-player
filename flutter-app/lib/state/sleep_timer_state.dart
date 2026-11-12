// lib/state/sleep_timer_state.dart
//
// 睡眠定时器：设定一个时长，倒计时归零时**暂停播放**（保留当前进度，再按播放
// 即可继续）。
//
// 状态只有一个：**截止时刻（deadline，墙钟）**。没有 deadline = 未启用。
// 剩余时间由 1s 的 tick 现算（deadline - now），不另存一个会漂移的倒计时器。
//
// 定时器按墙钟走：切歌不重置、暂停 / 播放歌曲都不影响它 —— 它只认时间。
// deadline 写进 prefs：重启应用后倒计时接着走；否则用户重启一下定时器就凭空
// 失效，太意外。
//
// 对译 React 版 `src/state/sleep-timer.tsx`（同语义）。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import 'player_state.dart';
import 'toast_state.dart';

/// 预设档位（分钟）。10 分钟是默认档。
const List<int> kSleepTimerPresets = <int>[10, 15, 20, 30, 60];

/// 缺省时长（分钟）：面板打开时这一档默认选中，自定义输入也预填它。
const int kSleepTimerDefaultMinutes = 10;

/// 自定义输入的范围（分钟）。
const int kSleepTimerMinMinutes = 1;
const int kSleepTimerMaxMinutes = 999;

/// 剩余不足这一分钟就算「快到了」（按钮上换个颜色提醒）。
const Duration kSleepTimerEndingThreshold = Duration(minutes: 1);

/// 睡眠定时器的状态与操作。
class SleepTimerState extends ChangeNotifier {
  SleepTimerState({
    // 私有字段的命名初始化形参：对外参数名仍是 `prefs` / `player` / `toasts`
    // （与 LyricsState 同一套写法）。
    required this._prefs,
    required this._player,
    required this._toasts,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppPrefs _prefs;
  final PlayerState _player;
  final ToastState _toasts;

  /// 取当前时刻的接缝（测试里注入假时钟）。
  final DateTime Function() _now;

  DateTime? _deadline;
  Timer? _tick;

  /// 到点只触发一次；重新设定后要能再触发。
  bool _fired = false;

  /// 截止时刻；null = 未启用。
  DateTime? get deadline => _deadline;

  /// 是否在倒计时。
  bool get running => _deadline != null;

  /// 剩余时长；未启用为 0。
  Duration get remaining {
    final deadline = _deadline;
    if (deadline == null) {
      return Duration.zero;
    }
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 剩余时间的 mm:ss（分钟可以超过 59 —— 60 分钟档就是 60:00）。
  String get remainingText {
    final total = (remaining.inMilliseconds / 1000).ceil();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 剩余不足一分钟。
  bool get ending {
    final left = remaining;
    return left > Duration.zero && left <= kSleepTimerEndingThreshold;
  }

  /// 设定定时器（分钟；越界夹到合法区间）。
  void start(int minutes) {
    final safe = minutes.clamp(kSleepTimerMinMinutes, kSleepTimerMaxMinutes);
    _deadline = _now().add(Duration(minutes: safe));
    _fired = false;
    _startTicking();
    notifyListeners();
    unawaited(
      _prefs.writeNumber(
        StorageKeys.sleepTimer,
        _deadline!.millisecondsSinceEpoch,
      ),
    );
  }

  /// 取消定时器。
  void cancel() {
    _deadline = null;
    _fired = false;
    _tick?.cancel();
    _tick = null;
    notifyListeners();
    unawaited(_prefs.remove(StorageKeys.sleepTimer));
  }

  /// 启动时恢复上次的定时器：deadline 还在就接着走；早就过期的清掉。
  Future<void> restore() async {
    final stored = await _prefs.readNumber(StorageKeys.sleepTimer);
    if (stored == null) {
      return;
    }
    final deadline = DateTime.fromMillisecondsSinceEpoch(stored.toInt());
    if (deadline.isBefore(_now())) {
      await _prefs.remove(StorageKeys.sleepTimer);
      return;
    }
    _deadline = deadline;
    _fired = false;
    _startTicking();
    notifyListeners();
  }

  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // 补一次：挂上这一刻可能已经过了截止时刻（应用被挂起过、或重启后恢复的）
    _onTick();
  }

  void _onTick() {
    final deadline = _deadline;
    if (deadline == null || _fired) {
      return;
    }
    if (_now().isBefore(deadline)) {
      notifyListeners();
      return;
    }
    _fired = true;
    _deadline = null;
    _tick?.cancel();
    _tick = null;
    notifyListeners();
    unawaited(_prefs.remove(StorageKeys.sleepTimer));
    unawaited(_player.pause());
    _toasts.show('定时结束，已暂停播放');
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }
}
