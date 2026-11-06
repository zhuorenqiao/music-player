// lib/library/import_service.dart
//
// 导入流程的最后一环（spec §8）：校验扩展名 → 立即入列（可播）→ 解析内嵌标签
// → 探时长 → 交给调用方落库（[ImportService.onImported]）。
//
// 两条硬约束：
//
//   1. **入列不等元数据**。用户点了导入，歌就该马上出现在列表里并能播；标签与
//      时长是增值项，晚到几百毫秒无所谓，但一个字都不许阻塞入列，更不许因为
//      「标签读不出来」把文件挡在门外（能不能播由播放错误那条路判定）。
//   2. **回填写回活对象**。`Playlist.addAt` / `addMany` 都会经
//      toJson→normalizeTrack 克隆一份，改传进去的那份，界面上永远是文件名拆
//      出来的样子 —— 这就是原版 `applyAudioTags` 注释里记的坑（tagging.ts:
//      「Playlist.addMany 会克隆对象，直接改传进来的那份可能改到副本上」）。
//      所以这里一律 `playlist.byId(id)` 找回列表里的对象再改。
//
// id 规则与原版不同：原版是 `local-<uuid>`（每次导入都新，重名文件还会撞），
// 这里按**来源字符串**派生（[localIdFor]），同一路径永远同一个 id，于是
// 「重复导入同一个文件」天然去重。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../metadata/audio_tags.dart';
import '../metadata/byte_reader.dart';
import '../metadata/cover_image.dart';
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/track_handle.dart';
import '../playback/transport_controller.dart' show ToastSink;
import 'audio_filter.dart';

/// 一次导入的结果。
class ImportResult {
  const ImportResult({
    this.added = 0,
    this.rejected = 0,
    this.rejectedNames = const [],
    this.addedIds = const [],
  });

  /// 真正新入列的条数（已在列表里的不重复计入，也不会触发 [onImported]）。
  final int added;

  /// 被扩展名白名单挡掉的条数。
  final int rejected;

  /// 被挡掉的文件名（含扩展名，按输入顺序；同一文件出现几次就记几次。
  /// 提示文案另按名字去重，见 [ImportService.importPaths]）。
  final List<String> rejectedNames;

  /// 本次请求涉及的曲目 id，顺序即入列顺序。
  ///
  /// **包含本来就在列表里的那几首**（同一文件重复导入仍会交回同一个 id）：
  /// 调用方拿它就能回答「这些文件现在都在列表里了」，做「选中刚导入的曲目」
  /// 这类事时不必再自己算 id。新增了多少看 [added]。
  final List<String> addedIds;
}

/// 头部预读窗口：判容器格式要用的字节（与 [ByteSource.headProbeBytes] 同值，
/// 一次开文件读进来，之后的小读取都在内存里命中）。
const int _headProbeBytes = 64 * 1024;

/// 导入服务：把路径 / 目录变成列表里的曲目，再在后台补标签、封面与时长。
class ImportService {
  ImportService({
    required this.playlist,
    required this.toasts,
    this.covers,
    this.coverDirectory,
    this.durationProbe,
    this.onImported,
  });

  final Playlist playlist;
  final ToastSink toasts;

  /// 内嵌封面落盘器。与 [coverDirectory] 同时给了才会写。
  final CoverImageWriter? covers;

  /// 封面落盘目录（应用缓存目录下的 covers/）。
  final String? coverDirectory;

  /// 时长探测：路径 → 秒；探不出给任意非有限值 / 非正数（保持「未知」）。
  ///
  /// 注入而不是在这里引播放器：导入属于数据层，探时长是平台能力，
  /// 由上层（T23 起的界面层）把播放器那侧的探测函数递进来。
  final double Function(String path)? durationProbe;

  /// 新曲目入列后回调（落库用）。fire-and-forget，出错不影响导入结果。
  final Future<void> Function(List<String> ids)? onImported;

  /// 导入一批路径。
  ///
  /// 空输入直接返回零结果、不发提示（拖了个空文件夹不该弹「已跳过 0 个」）。
  /// 白名单外的一律拒绝**并点名**，其余立刻入列；标签 / 时长在后台补。
  /// 同一个文件重复导入不会变成两条记录：已在列表里的只交回 id，不重建。
  Future<ImportResult> importPaths(List<String> paths) async {
    if (paths.isEmpty) return const ImportResult();
    final partition = partitionByExtension(paths);
    final announced = <String>{};
    for (final path in partition.rejected) {
      final name = _basename(path);
      // 同一批里重名的只提示一次：一次拖进 20 个同名非音频文件不该刷 20 条横幅。
      if (!announced.add(name)) continue;
      toasts.show('不支持的文件格式，已跳过：$name', key: 'skip-$name');
    }

    // idsInCall：本次涉及的 id（含本来就在列表里的），按首次出现顺序去重。
    // newIds：真正新入列的，决定 added、后台回填与落库钩子。
    final idsInCall = <String>[];
    final seen = <String>{};
    final newIds = <String>[];
    for (final path in partition.accepted) {
      final id = localIdFor(path);
      final isNew = playlist.byId(id) == null;
      if (isNew) {
        final inserted = playlist.addAt(_buildTrack(path, id));
        if (inserted == null) continue; // 理论上不会：字段都是这里给的
        newIds.add(id);
        // 入列即可播；元数据不阻塞（见文件头第 1 条）。
        _spawn(() => _enrich(inserted));
      }
      // 同一文件第二次导入：不重建、不改顺序，但仍然把 id 交回去。
      if (seen.add(id)) idsInCall.add(id);
    }

    if (newIds.isNotEmpty) {
      final notify = onImported;
      if (notify != null) _spawn(() => notify(newIds));
    }

    return ImportResult(
      added: newIds.length,
      rejected: partition.rejected.length,
      rejectedNames: [for (final path in partition.rejected) _basename(path)],
      addedIds: idsInCall,
    );
  }

  /// 扫一个目录再导入。
  ///
  /// 扫描只收白名单内的音频（T17），所以这里不会有「拒绝」；一个都没扫到
  /// 就提示一句并交回零结果 —— 这种情况多半是选错文件夹，静默返回太像卡住。
  Future<ImportResult> importDirectory(
    String root, {
    int maxFiles = 2000,
  }) async {
    final found = await scanAudioDirectory(root, maxFiles: maxFiles);
    if (found.isEmpty) {
      toasts.info('这个目录里没有可播放的音频文件');
      return const ImportResult();
    }
    return importPaths([for (final item in found) item.path]);
  }

  /// 读内嵌标签回填到**列表里的活对象**（导入时与将来的启动还原都走这里）。
  ///
  /// 字段归属：标签是文件自带的权威信息，优先于文件名；文件名只在标签缺字段
  /// 时兜底（[mergeTaggedNames] 的语义，标题与歌手各自独立判断）。封面只在
  /// 「有图 + 还没有真封面 + 给了落盘器与目录」时写，写出的路径存回 `cover`。
  ///
  /// 任何失败（文件不在、读不了、SAF URI 用不了 dart:io、标签畸形）都只意味着
  /// 「这次没回填」，绝不抛：导入是用户点的按钮，不能因为一个坏文件整页崩掉。
  Future<void> hydrateMetadata(Track track) async {
    final live = playlist.byId(track.id) ?? track;
    final path = live.handle.pathish;
    final head = await _prefetchHead(path);
    if (head == null) return;
    final source = ByteSource.fromFile(path, prefetched: head);
    final tags = await readAudioTags(source, fileName: live.handle.displayName);
    if (!tags.hasAnyText && !tags.hasPicture) return;

    final names = mergeTaggedNames(
      tags,
      _stripExtension(live.handle.displayName),
    );
    if (names.title.isNotEmpty) live.title = names.title;
    if (names.artist.isNotEmpty) live.artist = names.artist;
    if (tags.album.isNotEmpty) live.album = tags.album;

    final picture = tags.picture;
    final writer = covers;
    final directory = coverDirectory;
    if (picture == null ||
        picture.isEmpty ||
        writer == null ||
        directory == null ||
        live.hasRealCover) {
      return;
    }
    final saved = await writer.write(
      picture,
      tags.pictureMime,
      directory: directory,
      id: live.id,
    );
    if (saved != null) live.cover = saved;
  }

  /// 入列后的后台补全：标签 → 时长。
  ///
  /// 标签先跑，是为了让「文件名猜反了」的曲目在探时长之前就拿到正确的词
  /// （与原版 tagging.ts 的顺序一致）。时长只填空缺：已经有时长的不重探。
  Future<void> _enrich(Track live) async {
    await hydrateMetadata(live);
    final probe = durationProbe;
    if (probe == null || live.hasDuration) return;
    final value = probe(live.handle.pathish);
    // NaN / 0 / 负数 / 无穷都算「探不出来」：未知时长必须保持 NaN，不是 0。
    if (value.isFinite && value > 0) live.duration = value;
  }

  /// 文件名 → 曲目。歌手与曲名按原版规则拆（左侧歌手、右侧曲名），
  /// 拆不出就整串当曲名；时长未知（NaN），等探测回填。
  Track _buildTrack(String path, String id) {
    final handle = FilePathHandle(path);
    final split = splitArtistTitle(_stripExtension(handle.displayName));
    return Track(
      id: id,
      src: path,
      title: split.title.isEmpty ? handle.displayName : split.title,
      artist: split.artist,
      duration: double.nan,
      isLocal: true,
      handle: handle,
    );
  }

  /// 头部预读：一次开文件把判格式要用的字节读进来。
  ///
  /// 文件不存在 / 打不开（含 Android 的 `content://`）返回 null ——
  /// 调用方据此跳过回填，而不是把它当成「标签为空」。
  Future<Uint8List?> _prefetchHead(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final size = await handle.length();
      final take = size < _headProbeBytes ? size : _headProbeBytes;
      return await handle.read(take);
    } catch (_) {
      return null;
    } finally {
      try {
        await handle?.close();
      } catch (_) {
        // 关闭失败不影响已经读到的字节。
      }
    }
  }

  /// 后台任务：不 await、出错也不许冒泡。
  ///
  /// 导入已经成功，回填是增值项 —— 一条失败不能变成未捕获异常把界面拖垮。
  void _spawn(Future<void> Function() task) {
    unawaited(
      Future<void>.sync(task).then<void>((_) {}, onError: (Object _) {}),
    );
  }
}

/// 同一来源恒定同一个 id：路径（或 SAF URI）的 sha1 前 16 位。
///
/// 原版用 `local-<uuid>`：每次导入都换一个，同一个文件导两次就是两条记录。
/// 这里按来源字符串派生，重复导入天然去重，也便于「按路径找回曲目」。
/// 只取前 16 个十六进制字符：够散（64 bit），又短到能当封面文件名。
///
/// 注意：id 只认调用方给的字符串本身，不做路径归一化 —— 选择器与目录扫描
/// 交回来的已经是同一个形态（桌面是绝对路径），归一化放到调用方更安全。
String localIdFor(String source) {
  final digest = crypto.sha1.convert(utf8.encode(source)).toString();
  return 'local:${digest.substring(0, 16)}';
}

/// 取路径最后一段（不依赖 `package:path`：这里只需要切分隔符）。
String _basename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// 去掉最后一段扩展名（`.flac` / `.mp3`…）。点开头且没有别的内容的
/// 名字（`.hidden`）原样保留 —— `dot > 0` 与白名单判定同一条规则。
String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
