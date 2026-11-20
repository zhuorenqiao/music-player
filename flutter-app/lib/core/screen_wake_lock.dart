// lib/core/screen_wake_lock.dart
//
// 屏幕常亮的平台出口（安卓窗口 `FLAG_KEEP_SCREEN_ON`）。
//
// 为什么需要它：手机按系统休眠时间黑屏后音乐仍在播，但每看一次进度都得先
// 解锁 —— 移动端播放器最常被抱怨的一条。Flutter 本身没有「保持屏幕常亮」的
// API；安卓侧的正解是给当前窗口加 `FLAG_KEEP_SCREEN_ON`：不需要 `WAKE_LOCK`
// 权限，屏幕在应用可见期间不自动熄灭，用户按电源键手动熄屏照样有效。
//
// 这一层只管「开 / 关」，什么时候开由播放态决定（见
// `playback/screen_awake_keeper.dart`）。原生实现是 `MainActivity.kt` 里注册
// 的 screen 通道；通道名 / 方法名与那边必须一字不差。
//
// 平台门禁与 `saf_bridge.dart` 同一口径（`defaultTargetPlatform`，测试可
// 用 `debugDefaultTargetPlatformOverride` 覆盖）：非安卓恒为无操作，绝不把
// 「通道没注册」这类异常冒到播放编排里 —— 常亮拿不到只是屏幕会照常熄灭，
// 音乐与界面不能受任何影响。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与安卓 `MainActivity` 注册的通道名必须一致。
const String kScreenChannelName = 'com.lightmusic.light_music/screen';

/// 通道方法：给窗口加 `FLAG_KEEP_SCREEN_ON`。
const String kScreenMethodKeepAwake = 'keepAwake';

/// 通道方法：撤掉 `FLAG_KEEP_SCREEN_ON`，屏幕恢复按系统设置休眠。
const String kScreenMethodAllowSleep = 'allowSleep';

/// 原生通道实例抽成可替换的顶层字段：单元测试换成假通道，不碰 Activity。
MethodChannel screenWakeLockChannel = MethodChannel(kScreenChannelName);

/// 「播放期间屏幕常亮」的平台开关。
///
/// 语义只表达结果，不表达次数：重复打开 / 重复关闭都必须是幂等的 —— 播放态
/// 的抖动（缓冲、被拦后重试、通知栏暂停）会反复落到同一条指令上。
abstract interface class ScreenWakeLock {
  /// [on] 为真时要求屏幕常亮，为假时恢复系统休眠。
  Future<void> setKeepAwake(bool on);
}

/// 空实现：测试装配与非安卓平台的默认出口，什么都不做。
class NoopScreenWakeLock implements ScreenWakeLock {
  const NoopScreenWakeLock();

  @override
  Future<void> setKeepAwake(bool on) async {}
}

/// 走安卓原生窗口 flag 的实现。
class SystemScreenWakeLock implements ScreenWakeLock {
  const SystemScreenWakeLock();

  @override
  Future<void> setKeepAwake(bool on) async {
    // 桌面 / Web 没有这条通道，也无需常亮：直接返回，别去碰平台选择器。
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await screenWakeLockChannel.invokeMethod<void>(
        on ? kScreenMethodKeepAwake : kScreenMethodAllowSleep,
      );
    } catch (error) {
      // 通道未注册（例如宿主换成了不实现该方法的容器）不影响播放。
      debugPrint('screen wake lock unavailable: $error');
    }
  }
}
