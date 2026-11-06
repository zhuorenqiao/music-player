// lib/core/file_picking.dart
//
// 文件 / 文件夹选择：**唯一** import `file_picker` 的地方。
//
// 界面层只认这两个函数，所以 widget 测试注入回调后完全不碰原生选择器；
// 将来换平台实现（或换成自绘选择器）也只改这一处。
//
// 取消与平台报错一律归一成「空结果」：调用方据此直接返回、不弹任何提示 ——
// 导入服务对空结果与不支持的格式另有自己的处理。
import 'package:file_picker/file_picker.dart';

import '../playback/play_error.dart' show kAudioExtensions;

/// 多选音频文件，返回真实文件系统路径。
///
/// 扩展名白名单直接取 [kAudioExtensions]（与原版一致）；Android 上选择器
/// 可能给缓存副本的路径，那也照用 —— 导入本来就要复制 / 落库。
/// 取消或平台报错时返回空列表。
Future<List<String>> pickAudioFiles() async {
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: kAudioExtensions.toList()..sort(),
    );
    final paths = <String>[];
    for (final file in files) {
      final path = file.path;
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    return paths;
  } catch (_) {
    // 平台通道异常（缺少插件 / 权限被拒 / 选择器自己崩了）不该冒到界面层
    return const [];
  }
}

/// 选一个目录，返回绝对路径；取消或平台报错时返回 null。
Future<String?> pickAudioFolder() async {
  try {
    final path = await FilePicker.getDirectoryPath();
    return (path == null || path.isEmpty) ? null : path;
  } catch (_) {
    return null;
  }
}
