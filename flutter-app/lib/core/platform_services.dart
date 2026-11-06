// lib/core/platform_services.dart
//
// 平台侧的「非业务」能力。M1 只有一件事：Android 13+ 的通知权限。
//
// 权限态不是错误态（spec §7.1 第 2 条）：被拒时只返回 false，由界面给一条
// info 级提示「通知栏控制需要允许通知权限」，**绝不阻断播放** —— 没有通知
// 权限时前台服务仍能起，只是锁屏与通知栏看不到控件。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// 申请通知权限；桌面与 Web 直接放行。
///
/// - 只对 Android 有运行时权限：Android 13（API 33）起是 `POST_NOTIFICATIONS`，
///   更低版本没有这个权限，`request()` 不弹任何对话框（系统只在安装时决定）。
///   所以这里不必自己读 SDK_INT，交给 permission_handler 判定 —— 它在 13 以下
///   用 `areNotificationsEnabled()` 回答，语义正是「通知能不能出来」。
/// - 已经授予时不重复弹窗。
/// - 任何平台异常（插件不可用、没有 Activity、通道报错）都返回 false，
///   绝不抛出：启动流程不能因为一个权限查询而中断。
Future<bool> ensureNotificationPermission() async {
  if (kIsWeb || !Platform.isAndroid) return true;
  try {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    // 永久拒绝再 request 也不会弹窗，直接如实回答。
    if (status.isPermanentlyDenied) return false;
    final result = await Permission.notification.request();
    return result.isGranted;
  } catch (_) {
    // 权限不可用：按「没有通知栏控制」处理，播放照旧。
    return false;
  }
}
