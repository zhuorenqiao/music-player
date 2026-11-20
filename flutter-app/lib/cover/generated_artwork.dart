// lib/cover/generated_artwork.dart
//
// 生成卡 → 系统封面文件（T22 的补丁）。
//
// 背景：生成卡是封面四级兜底的第四级，**纯显示**、每次现算、永不落盘
//（spec §12 红线，见 state/cover_state.dart 的写回纪律）。这条纪律对界面
// 没问题，但媒体会话只认 URI：没有真封面的歌，`coverForDisplay` 返回 ''，
// 推给系统的 artworkUri 就是 null，Android 通知 / Windows SMTC 只能退回
// 应用小图标（用户在通知栏看到的就是那道波形占位）。
//
// 这里的做法是「只读地复用」同一套 Painter：把 `GeneratedCoverPainter` 在
// 离线画布上画成一张 512×512 的 PNG，落在 `$dataDirectory/artwork/`，交给
// 媒体会话当封面。**不写回 `Track.cover`** —— 生成卡依然是「显示层现算」的
// 东西，这里产出的只是它的一张缓存快照，随时可删可重建。
//
// 两个约束：
//   * 栅格化是异步的（`Picture.toImage`），而 `artUriFor` 是同步回调，
//     所以对外是「[pathFor] 同步查 + [prime] 异步备」两步：查到就用，查不到
//     就先排进队列，落盘后 notifyListeners，装配层据此补推一次媒体会话。
//   * 文件名按派生量哈希：同一位歌手的同一首曲子（哪怕是重启后再算）落到
//     同一个文件，不重复画；不同曲名（生成卡底部小字不同）各占一份。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'generated_cover.dart';

/// 系统封面用的边长（px）。Android 通知大图标与 Windows SMTC 缩略图都在
/// 这个量级，再大只会白占内存与磁盘。
const int kGeneratedArtworkSize = 512;

class GeneratedArtworkCache extends ChangeNotifier {
  GeneratedArtworkCache({
    required this.directory,
    this.size = kGeneratedArtworkSize,
  });

  /// 落盘目录（生产是 `$dataDirectory/artwork`）。
  final String directory;

  /// 方图边长（px）。
  final int size;

  /// 已经确认在盘上的路径（键 = 绝对路径，值同键；用 Map 是为了 O(1) 判存在）。
  final Map<String, String> _ready = <String, String>{};

  /// 正在画的那些（键 = 绝对路径），用来挡并发重复请求。
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// 同步查询：这张生成卡已经有文件了吗？没有就返回 null。
  ///
  /// 磁盘上已存在（上一轮启动画过的）会就地记进 [_ready]，第二次起不再碰盘。
  String? pathFor({required String artist, required String title}) {
    if (kIsWeb) return null;
    final path = _pathForSpec(generatedCoverSpec(artist, title));
    final ready = _ready[path];
    if (ready != null) return ready;
    try {
      if (File(path).existsSync()) {
        _ready[path] = path;
        return path;
      }
    } catch (_) {
      // 目录不存在 / 无权限：当作「还没有」，交给 prime 去试。
    }
    return null;
  }

  /// 异步预热：没有就画一张落盘，完成后 [notifyListeners]。
  ///
  /// 绝不抛：画不出来顶多是系统卡片继续用占位图标，界面与播放不受影响。
  /// 返回的 Future 只给测试用（生产是「发出去就不管」的补推前置动作）。
  Future<void> prime({required String artist, required String title}) {
    if (kIsWeb) return Future<void>.value();
    final spec = generatedCoverSpec(artist, title);
    final path = _pathForSpec(spec);
    if (_ready.containsKey(path)) return Future<void>.value();
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;
    final future = _ensure(path, spec);
    _inFlight[path] = future;
    unawaited(future.whenComplete(() => _inFlight.remove(path)));
    return future;
  }

  Future<void> _ensure(String path, GeneratedCoverSpec spec) async {
    var changed = false;
    try {
      final file = File(path);
      if (!file.existsSync()) {
        await Directory(directory).create(recursive: true);
        final bytes = await _rasterize(spec);
        if (bytes == null) return;
        // 先写临时文件再改名：外部（系统卡片）不会读到半张图。
        final tmp = File('$path.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(path);
        changed = true;
      }
      _ready[path] = path;
    } catch (error) {
      debugPrint('generated artwork failed: $error');
      return;
    }
    // 只有「新画出来一张」才值得叫醒装配层；已在盘上的重复预热不刷屏。
    if (changed) notifyListeners();
  }

  /// 文件名：派生量哈希 + 边长。同歌同曲恒等，重启不重画。
  String _pathForSpec(GeneratedCoverSpec spec) {
    final hash = fnv1aHash(
      '${spec.key}\u0001${spec.label}\u0001${spec.sub}\u0001$size',
    );
    return '$directory/gen-$hash-$size.png';
  }

  /// 把生成卡画成 PNG 字节。画布尺寸即输出尺寸，Painter 内部按 600 设计稿
  /// 等比缩放（见 generated_cover.dart 的 paint）。
  Future<Uint8List?> _rasterize(GeneratedCoverSpec spec) async {
    final side = size.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, side, side));
    // 不透明底：PNG 带 alpha 的话，系统卡片把透明处当黑 / 当白都不好看。
    canvas.drawRect(
      Rect.fromLTWH(0, 0, side, side),
      Paint()..color = const Color(0xFF101014),
    );
    GeneratedCoverPainter(spec).paint(canvas, Size(side, side));
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }
}
