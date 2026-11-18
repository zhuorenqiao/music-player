// lib/core/saf_bridge.dart
//
// 安卓 SAF 目录树导入的原生桥接（文件夹导入路线 A）。
//
// file_picker 在安卓选文件夹返回的是 `content://` 目录树 URI，`dart:io` 既无法
// 枚举这棵树，也读不了里面的字节。这里把树 URI 交给原生 Kotlin 通道：原生递归
// 枚举白名单音频、复制到应用专属目录，再回传一批**本地绝对路径**；之后整条既有
// 导入链路（标签回填 / 时长探测 / 封面落盘 / 播放 / 落库）按本地路径原样复用，
// 不需要给 SAF 句柄补 ContentResolver 读写能力。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与安卓 `MainActivity` 注册的通道名必须一致。
const String kSafChannelName = 'com.lightmusic.light_music/saf';

/// 通道方法：入参 `treeUri`（String），返回复制后的本地路径 `List<String>`。
const String kSafMethodCopyAudioTree = 'copyAudioTree';

/// 原生通道实例抽成可注入的顶层字段：widget / 单元测试可以替换成假通道，
/// 不碰平台选择器与原生实现。
MethodChannel safChannel = MethodChannel(kSafChannelName);

/// 把一棵 SAF 目录树里的音频复制到应用专属目录，返回复制后的本地绝对路径列表。
///
/// - 非 Android（桌面 / Web）：恒返回空列表 —— 桌面文件夹导入走本地目录扫描，
///   不经过这条桥。平台判定口径与 `platform_services.dart` 一致
///   （`defaultTargetPlatform`，测试可 `debugDefaultTargetPlatformOverride` 覆盖）。
/// - 通道缺失 / 报错 / 一棵树都没复制出来：归一为空列表，由调用方给「没有可播放
///   的音频文件」一类提示，绝不把原生异常冒到界面层。
Future<List<String>> copyAudioTreeToLocal(String treeUri) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const [];
  }
  if (treeUri.isEmpty) return const [];
  try {
    final result = await safChannel.invokeMethod<List<Object?>>(
      kSafMethodCopyAudioTree,
      <String, Object?>{'treeUri': treeUri},
    );
    if (result == null) return const [];
    return [
      for (final item in result)
        if (item is String && item.isNotEmpty) item,
    ];
  } catch (_) {
    // 通道未注册 / 原生抛错 / 选择器或复制中途失败：按空结果处理。
    return const [];
  }
}
