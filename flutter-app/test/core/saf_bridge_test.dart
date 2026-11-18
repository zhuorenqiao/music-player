// test/core/saf_bridge_test.dart
//
// SAF 目录树导入桥接的归一逻辑：非 Android / 空 URI 不碰原生通道；通道成功时
// 过滤掉 null 与空串；通道报错归一为空列表，绝不把原生异常冒到界面层。
// 原生递归枚举与复制在 Kotlin 侧，本机无安卓宿主，运行时行为走真机验收。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/saf_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  final calls = <MethodCall>[];
  Object? reply;
  bool fail = false;

  setUp(() {
    messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    calls.clear();
    reply = null;
    fail = false;
    messenger.setMockMethodCallHandler(safChannel, (call) async {
      calls.add(call);
      if (fail) throw PlatformException(code: 'UNAVAILABLE', message: 'no activity');
      return reply;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(safChannel, null);
  });

  test('非 Android（桌面 / Web）恒返回空，且完全不碰通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    expect(await copyAudioTreeToLocal('content://x/y'), isEmpty);
    expect(calls, isEmpty);
  });

  test('Android 空 treeUri 直接返回空，不调通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    expect(await copyAudioTreeToLocal(''), isEmpty);
    expect(calls, isEmpty);
  });

  test('Android 通道成功：回传路径过滤 null 与空串', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    reply = ['/data/a.flac', null, '', '/data/b.mp3'];

    final out = await copyAudioTreeToLocal('content://tree/123');

    expect(out, ['/data/a.flac', '/data/b.mp3']);
    expect(calls.single.method, kSafMethodCopyAudioTree);
    expect(calls.single.arguments, {'treeUri': 'content://tree/123'});
  });

  test('Android 通道返回 null → 空列表', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    reply = null;

    expect(await copyAudioTreeToLocal('content://tree/123'), isEmpty);
  });

  test('Android 通道抛异常 → 空列表，不向上抛', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fail = true;

    expect(await copyAudioTreeToLocal('content://tree/123'), isEmpty);
    expect(calls.single.method, kSafMethodCopyAudioTree);
  });
}
