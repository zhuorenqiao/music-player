// lib/metadata/cover_image.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 内嵌封面落盘：解出图像 → 缩到最长边不超过 [maxEdge] → 写成文件，返回绝对路径。
///
/// 对译 React 版 src/lib/audio-tags.js 的封面链路（原版是
/// `canvas.toDataURL('image/jpeg', 0.86)` 的 data URL）。契约：
///
/// * **永不抛**：空字节、解不出的图像、写盘失败统统返回 null，调用方据此继续
///   走在线匹配 / 占位图那几级兜底；
/// * **格式约定（task-10-brief Step 4 的裁定）**：`ui.Image.toByteData` 只给
///   PNG 与 raw 两种输出，Flutter 没有 JPEG 编码器，本移植也不为凑 JPEG 加第三方
///   编码依赖。所以文件名沿用原版的 `id.jpg`，**内容实际是 PNG 字节**。读取方
///   （M2 的封面显示层）必须按字节嗅探（魔数判断）而不是扩展名判型 —— 这样
///   「名字 .jpg、内容 PNG」的不一致不会影响显示。
/// * [write] 的 `mime` 只为对齐接口保留（原版把它写进 data URL）；解码交给引擎，
///   不信任声明 —— APIC / FLAC PICTURE 的 mime 写错的文件很常见。
class CoverImageWriter {
  const CoverImageWriter();

  /// 最长边的上限（对齐原版的 600px）。
  static const int maxEdge = 600;

  /// 落盘的扩展名：沿用原版的 `.jpg`（内容见类注释：是 PNG 字节）。
  static const String fileExtension = '.jpg';

  /// id 为空或全是非法字符时用的文件名主干。
  static const String fallbackStem = 'cover';

  /// 文件名里不允许出现的字符（路径分隔符、通配符、空格等）一律换成 `_`。
  static final RegExp _unsafeStem = RegExp(r'[^A-Za-z0-9._-]');

  /// 写封面到 `directory/<id>.jpg`，返回绝对路径；任何失败返回 null。
  ///
  /// [directory] 不存在时递归创建。同一 id 重复写会覆盖（缓存语义）。
  Future<String?> write(
    Uint8List bytes,
    String mime, {
    required String directory,
    String id = '',
  }) async {
    if (bytes.isEmpty || directory.isEmpty) return null;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      if (decoded.width <= 0 || decoded.height <= 0) return null;
      final size = _fitWithin(decoded.width, decoded.height);
      final png = await _renderPng(decoded, size);
      if (png == null) return null;
      final file = File(
        '$directory${Platform.pathSeparator}${_stemOf(id)}$fileExtension',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png, flush: true);
      return file.absolute.path;
    } catch (_) {
      // 解不出 / 写不进：当作没有内嵌封面，继续走后面的兜底级。
      return null;
    } finally {
      _quietly(() => decoded?.dispose());
      _quietly(() => codec?.dispose());
    }
  }

  /// 释放原生资源时出错也不许抛：`write` 的契约是「任何情况都返回 null」，
  /// 而 `finally` 里的异常已经不会被上面的 `catch` 接住。
  void _quietly(void Function() action) {
    try {
      action();
    } catch (_) {
      // 忽略：资源释放失败不影响本次结果。
    }
  }

  /// 等比缩到最长边不超过 [maxEdge]；本来就在范围内就原样返回。
  (int, int) _fitWithin(int width, int height) {
    if (width <= maxEdge && height <= maxEdge) return (width, height);
    final longest = width > height ? width : height;
    final ratio = maxEdge / longest;
    final scaledWidth = (width * ratio).round();
    final scaledHeight = (height * ratio).round();
    // 极端长宽比可能把短边算成 0：toImage 不接受 0 边长。
    return (
      scaledWidth < 1 ? 1 : scaledWidth,
      scaledHeight < 1 ? 1 : scaledHeight,
    );
  }

  /// 把 [image] 重绘到 [size]，再编码成 PNG 字节。
  ///
  /// 走 PictureRecorder 而不是直接改原图，是为了让缩放后的尺寸成为输出尺寸
  /// （原版 `canvas.drawImage(img, 0, 0, w, h)` 的等价物）。
  Future<Uint8List?> _renderPng(ui.Image image, (int, int) size) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, size.$1.toDouble(), size.$2.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    ui.Image? rendered;
    try {
      rendered = await picture.toImage(size.$1, size.$2);
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      _quietly(() => rendered?.dispose());
      _quietly(picture.dispose);
    }
  }

  /// id → 安全的文件名主干：去掉路径分隔符等字符，空串回退到 [fallbackStem]。
  String _stemOf(String id) {
    final stem = id.trim().replaceAll(_unsafeStem, '_');
    if (stem.isEmpty || stem.replaceAll('.', '').isEmpty) return fallbackStem;
    return stem;
  }
}
