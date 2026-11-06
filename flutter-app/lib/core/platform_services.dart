// lib/core/platform_services.dart
//
// 平台侧的「非业务」能力。M1 只有一件事：Android 13+ 的通知权限。
//
// 权限态不是错误态（spec §7.1 第 2 条）：被拒时只返回 false，由界面给一条
// info 级提示「通知栏控制需要允许通知权限」，**绝不阻断播放** —— 没有通知
// 权限时前台服务仍能起，只是锁屏与通知栏看不到控件。
//
// **本文件不申请通知权限**：Android 13+ 的弹窗由 `FlutterMediaSession.activate()`
// 负责（包在 Android 上先 request 再激活服务，见 flutter_media_session 3.0.9
// 的 `lib/flutter_media_session.dart`）。这里如果再 `request()` 一次，同一个
// 权限会被问两遍，第二次往往直接拿到拒绝 —— 缓存的 false 就变成骗人的状态，
// 而且用户会看到两次弹窗。所以这里只「查」不「问」。
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// 查询通知权限**当前**是否已授予；绝不弹窗，任何异常都按「没有」回答。
///
/// - 非 Android（桌面 / Web）：恒为 true —— M1 的桌面端（Windows）系统控件
///   不需要通知权限，iOS 不在范围内。
/// - Android：只读 `Permission.notification.status`，不调用 `request()`。
///   Android 13 以下这个权限没有运行时对话框，permission_handler 用
///   `areNotificationsEnabled()` 回答，语义正是「通知能不能出来」；
///   Android 13+ 在 `activate()` 弹过窗之后，这里读到的就是用户的真实选择。
/// - 平台判定用 `defaultTargetPlatform` 而不是 `Platform.isAndroid`：与
///   `flutter_media_session` 内部（`activate()` 的判定）同一套口径，测试里也能
///   用 `debugDefaultTargetPlatformOverride` 覆盖到 Android 分支。
///
/// 界面提示条（T24）用它取真实状态：首帧之后用户可能在系统对话框或设置里
/// 改过权限，缓存启动时那一次不值钱。
Future<bool> notificationPermissionGranted() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    return (await Permission.notification.status).isGranted;
  } catch (_) {
    // 权限不可用（插件缺失 / 通道报错）：按「没有通知栏控制」处理，播放照旧。
    return false;
  }
}

/// 兼容旧调用点的别名：等价于 [notificationPermissionGranted]。
///
/// 名字里的 `ensure` 是历史包袱 —— 它**不申请**权限（见文件头），只如实回答
/// 当前状态。新代码请直接用 [notificationPermissionGranted]。
Future<bool> ensureNotificationPermission() => notificationPermissionGranted();
