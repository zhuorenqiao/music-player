// test/core/platform_services_test.dart
//
// 通知权限：只查询、绝不申请（T22 修正）。
//
// 申请归 `FlutterMediaSession.activate()`：它在 Android 上先
// `requestNotificationPermission()` 再激活前台服务。启动流程如果再问一次，
// 同一个权限会出现两遍弹窗，第二遍往往直接拿到拒绝 —— 缓存的 false 就再也
// 对不上用户真实的选择。这里的断言盯着两件事：Android 分支只发
// `checkPermissionStatus`，以及查询永远不会抛。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/platform_services.dart';

const MethodChannel _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

/// permission_handler 走的那条通道的替身。
///
/// `checkPermissionStatus` 的返回值是 int：0 = denied，1 = granted
/// （`PermissionStatusValue.statusByValue`）。`requestPermissions` 一旦被调用就
/// 记一笔 `request`，让「有没有偷偷弹窗」变成可断言的事实。
class _PermissionChannel {
  _PermissionChannel(this.messenger);

  final TestDefaultBinaryMessenger messenger;

  /// 收到过的方法名，按顺序。
  final List<String> calls = [];

  /// `checkPermissionStatus` 的答案。
  int status = 0;

  /// 通道直接报错（插件不可用 / 没有 Activity）。
  bool fail = false;

  void install() {
    messenger.setMockMethodCallHandler(_permissionChannel, (call) async {
      if (call.method == 'requestPermissions') calls.add('request');
      calls.add(call.method);
      if (fail) {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no activity');
      }
      if (call.method == 'checkPermissionStatus') return status;
      if (call.method == 'requestPermissions') return <int, int>{};
      return null;
    });
  }

  void uninstall() =>
      messenger.setMockMethodCallHandler(_permissionChannel, null);
}

void main() {
  // 通道替身要有 binary messenger。
  TestWidgetsFlutterBinding.ensureInitialized();

  late _PermissionChannel channel;

  setUp(() {
    channel = _PermissionChannel(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
    )..install();
  });

  tearDown(() {
    // 覆盖平台必须还原，否则 flutter_test 在收尾时报「调试变量被改过」。
    debugDefaultTargetPlatformOverride = null;
    channel.uninstall();
  });

  group('notificationPermissionGranted', () {
    test('非 Android（桌面 / Web）恒为 true，且完全不碰权限通道', () async {
      // flutter_test 里 defaultTargetPlatform 默认就是 android（与宿主无关），
      // 桌面那条路要显式覆盖过去。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(await notificationPermissionGranted(), isTrue);
      expect(channel.calls, isEmpty);
    });

    test('Android 已授予 → true，只查询不申请', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      channel.status = 1; // granted

      expect(await notificationPermissionGranted(), isTrue);
      expect(channel.calls, ['checkPermissionStatus']);
    });

    test('Android 未授予 → false，同样不申请（弹窗是 activate() 的事）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      channel.status = 0; // denied

      expect(await notificationPermissionGranted(), isFalse);
      // 关键断言：没有 request —— 否则会在启动时弹第二次。
      expect(channel.calls, ['checkPermissionStatus']);
      expect(channel.calls, isNot(contains('request')));
    });

    test('Android 通道异常 → false，不抛（权限态不该变成启动错误）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      channel.fail = true;

      expect(await notificationPermissionGranted(), isFalse);
      expect(channel.calls, ['checkPermissionStatus']);
    });

    test('ensureNotificationPermission 是查询的别名：Android 上也不弹窗', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      channel.status = 0;

      expect(await ensureNotificationPermission(), isFalse);
      expect(channel.calls, ['checkPermissionStatus']);
      expect(channel.calls, isNot(contains('request')));
    });
  });
}
