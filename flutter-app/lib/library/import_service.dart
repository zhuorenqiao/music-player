// lib/library/import_service.dart
//
// 导入流程的最后一环（spec §8）：校验扩展名 → 立即入列（可播）→ 解析内嵌标签
// → 探时长 → 交给调用方落库（[ImportService.onImported] / [ImportResult.enrichment]）。
//
// 两条硬约束：
//
//   1. **入列不等元数据**。用户点了导入，歌就该马上出现在列表里并能播；标签与
//      时长是增值项，晚到几百毫秒无所谓，但一个字都不许阻塞入列，更不许因为
//      「标签读不出来」把文件挡在门外（能不能播由播放错误那条路判定）。
//      代价是「谁去落这批回填」必须有个明确答案：本批的完成信号就是
//      [ImportResult.enrichment]，调用方（`LibraryState`）在它之上再做一次
//      落库 + 重绘，一批只做一次（终审 C1）。
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
import 'package:flutter/foundation.dart' show visibleForTesting;

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
    this.enrichment,
  });

  /// 真正新入列的条数（已在列表里的不重复计入，也不会触发 [onImported]）。
  final int added;

  /// 被扩展名白名单挡掉的条数。
  final int rejected;

  /// 被挡掉的文件名（含扩展名，按输入顺序；同一文件出现几次就记几次。
  /// 提示文案另按名字去重并封顶，见 [ImportService.importPaths]）。
  final List<String> rejectedNames;

  /// 本次请求涉及的曲目 id，顺序即入列顺序。
  ///
  /// **包含本来就在列表里的那几首**（同一文件重复导入仍会交回同一个 id）：
  /// 调用方拿它就能回答「这些文件现在都在列表里了」，做「选中刚导入的曲目」
  /// 这类事时不必再自己算 id。新增了多少看 [added]。
  final List<String> addedIds;

  /// 本批后台回填（标签 → 时长 → 封面）的完成信号；没有新曲目时为 null。
  ///
  /// **导入返回刻意不等它**：入列立刻可见、立刻可播这条不许倒退（见文件头第 1 条）。
  /// 但调用方必须在它完成之后再落一次库、刷一次界面 —— 回填改的是内存里的活对象，
  /// 没人再 persist 的话，文件仓里永远存着「只有文件名、时长 NaN、无封面」的记录，
  /// 用户加完歌直接重启就永久丢标签（终审 C1）。一个批次只等这一条 Future，
  /// 落库也只做一次，几百首歌不许写几百遍。
  final Future<void>? enrichment;
}

/// 头部预读窗口：判容器格式要用的字节（与 [ByteSource.headProbeBytes] 同值，
/// 一次开文件读进来，之后的小读取都在内存里命中）。
const int _headProbeBytes = 64 * 1024;

/// 逐条点名的上限：超过这个数的拒绝一律汇总成一句。
///
/// 原版对拒绝只发一句汇总（`skipped <n> unsupported files`）；这里保留点名
/// 更好定位，但必须有上限 —— 拖进一个 300 个 `.lrc` 的文件夹时，逐条弹窗
/// 会把界面刷屏。规则：前 [_maxNamedRejections] 个名字逐条提示，其余合成
/// 一句汇总（error 级），一次导入的提示总数因此恒定 ≤ 3。
const int _maxNamedRejections = 2;

/// 已是完整 URI（带 scheme 与权限段）的来源，如 Android SAF 的 `content://`。
///
/// 与 `track_handle.dart` 的判定同规则，但那边是私有常量，这里单独留一份：
/// 两处的用途不同（拼 file URI vs. 取展示名），不必为此互相暴露。
final RegExp _uriSourcePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

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

  /// 时长探测：来源 → 秒（探不到给任意非有限值 / 非正数，保持「未知」）。
  ///
  /// 注入而不是在这里引播放器：导入属于数据层，探时长是平台能力，由装配层
  /// （`main.dart`）把内核那侧递进来 —— 生产上是 `DurationProbe` 包着的
  /// media_kit opener（终审 I1：这条线以前根本没接，ID3v1-only / FLAC 无
  /// Vorbis comment 的曲目就永远没有时长，进度条一直是 `--:--`）。
  ///
  /// 异步签名：真探测要等原生内核回报时长，同步版只能靠阻塞读，而那会冻住
  ///  isolate。实现必须在自己的预算内返回且绝不抛（排队 / 超时见
  /// `library/duration_probe.dart`）。
  final Future<double> Function(String source)? durationProbe;

  /// 新曲目入列后回调（落库用）。fire-and-forget，出错不影响导入结果。
  final Future<void> Function(List<String> ids)? onImported;

  /// 导入一批路径。
  ///
  /// 空输入直接返回零结果、不发提示（拖了个空文件夹不该弹「已跳过 0 个」）。
  /// 白名单外的一律拒绝**并点名**（有上限，见 [_maxNamedRejections]），
  /// 其余立刻入列；标签 / 时长在后台补。
  /// 同一个文件重复导入不会变成两条记录：已在列表里的只交回 id，不重建。
  Future<ImportResult> importPaths(List<String> paths) async {
    if (paths.isEmpty) return const ImportResult();
    final partition = partitionByExtension(paths);
    _announceRejections(partition.rejected);

    // idsInCall：本次涉及的 id（含本来就在列表里的），按首次出现顺序去重。
    // newIds：真正新入列的，决定 added、后台回填与落库钩子。
    // enrichTasks：本批回填的任务，汇成 [ImportResult.enrichment] 交调用方收尾。
    final idsInCall = <String>[];
    final seen = <String>{};
    final newIds = <String>[];
    final enrichTasks = <Future<void>>[];
    for (final path in partition.accepted) {
      final id = localIdFor(path);
      final isNew = playlist.byId(id) == null;
      if (isNew) {
        final inserted = playlist.addAt(_buildTrack(path, id));
        if (inserted == null) continue; // 理论上不会：字段都是这里给的
        newIds.add(id);
        // 入列即可播；元数据不阻塞（见文件头第 1 条）。任务现在就开跑，
        // 但整批的完成信号交出去，由调用方落那第二次库。
        enrichTasks.add(_enrichQuiet(inserted));
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
      enrichment: _batchOf(enrichTasks),
    );
  }

  /// 拒绝提示：按名字去重、逐条点名，但总数封顶。
  ///
  /// 前 [_maxNamedRejections] 个名字各发一条横幅；剩下的（按去重后的名字数）
  /// 合成一条 error 级汇总句。于是无论拖进来多少文件，一次导入最多 3 条提示，
  /// 既不像原版只给一个数字（对不上是哪个文件），也不会 300 条把界面糊死。
  void _announceRejections(List<String> rejected) {
    final names = <String>[];
    final announced = <String>{};
    for (final path in rejected) {
      final name = _basename(path);
      // 同一批里重名的只提示一次：一次拖进 20 个同名非音频文件不该刷 20 条横幅。
      if (announced.add(name)) names.add(name);
    }

    final named = names.length < _maxNamedRejections
        ? names
        : names.sublist(0, _maxNamedRejections);
    for (final name in named) {
      toasts.show('不支持的文件格式，已跳过：$name', key: 'skip-$name');
    }
    final rest = names.length - named.length;
    if (rest > 0) toasts.error('另有 $rest 个文件不支持，已跳过');
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
    // 探时长排在标签之后、也排在整批完成信号之前：批次的落库收尾会连它一起落盘。
    final value = await probe(live.handle.pathish);
    // NaN / 0 / 负数 / 无穷都算「探不出来」：未知时长必须保持 NaN，不是 0。
    if (value.isFinite && value > 0) live.duration = value;
  }

  /// [_enrich] 的「绝不抛」外壳：失败只意味着这次没回填。
  ///
  /// 必须存在：批次的完成信号是 `Future.wait` 出来的，一条抛错会把整批的落库
  /// 收尾一起带走（终审 C1 要的就是那次收尾）。
  ///
  /// `finally` 里那一句是终审 R1 的核心：**不管这一条补上了什么、探到了什么、
  /// 还是整个文件都读不了**，都给它记一个持久的「已探测」标记。冷启动自愈
  /// 只认这个标记 —— 字段缺不缺不是「没回填过」的证据（见 [metadataIncomplete]），
  /// 不记就是每次启动把整个曲库重跑一遍。标记随那一次批次收尾 `persist()`
  /// 一起落盘；批次里任何一条都在这个外壳里，所以没有漏记的路径。
  Future<void> _enrichQuiet(Track live) async {
    try {
      await _enrich(live);
    } catch (_) {
      // 回填是增值项：导入已经成功，这里不许冒泡。
    } finally {
      // 记在**列表里的活对象**上（文件头第 2 条同一个理由：改到克隆副本上
      // 就等于没改，标记落不了盘）。
      (playlist.byId(live.id) ?? live).metadataProbed = true;
    }
  }

  /// 一批回填的完成信号；空批次给 null（调用方据此决定要不要再落一次库）。
  Future<void>? _batchOf(List<Future<void>> tasks) {
    if (tasks.isEmpty) return null;
    return Future.wait(tasks).then((_) {});
  }

  /// 冷启动还原的自愈回填：把**还没探测过**、且字段确实还缺的既有曲目重新
  /// 交给同一套补全。
  ///
  /// 为什么非要有：C1 修好之前存下的档案里就是「只有文件名、时长 NaN、无封面」，
  /// 只改导入路径救不了已经躺在文件仓里的旧记录；原版靠浏览器每次重读标签，
  /// 没有这个坑，所以必须在 Dart 端补这一遍。
  ///
  /// 为什么谓词是 [metadataIncomplete]（终审 R1）：判据的唯一支柱是落盘的探测
  /// 标记，**老档案第一次读到 false → 回填一次 → 之后永远不再重跑**；字段启发式
  /// 只用来省掉「没什么可补」的那次开文件。以前只看字段（还把「无封面」当成
  /// 没回填过）的后果是每次启动全库重跑。
  ///
  /// 返回本批的完成信号（没有要补的就返回 null），调用方在它完成后落一次库、
  /// 刷一次界面 —— 那一次落库同时把这一批新记上的探测标记带上盘。
  ///
  /// 与 [importPaths] 一样不挡首帧：曲目早就在列表里、也早就可播。
  Future<void>? rehydrateIncomplete() {
    final targets = [
      for (final track in playlist.tracks)
        if (metadataIncomplete(track)) track,
    ];
    return _batchOf([for (final track in targets) _enrichQuiet(track)]);
  }

  /// 文件名 → 曲目。歌手与曲名按原版规则拆（左侧歌手、右侧曲名），
  /// 拆不出就整串当曲名；时长未知（NaN），等探测回填。
  ///
  /// 名字一律走 [displayNameFor]：SAF 给的 `content://` 串里文件名是百分号
  /// 编码的路径段，直接切分隔符会把 `primary%3AMusic%2Fa` 当成标题。句柄本身
  /// 仍是 [FilePathHandle]（M1 不读 SAF 内容，T22 再接平台通道）。
  Track _buildTrack(String path, String id) {
    final displayName = displayNameFor(path);
    final split = splitArtistTitle(_stripExtension(displayName));
    return Track(
      id: id,
      src: path,
      title: split.title.isEmpty ? displayName : split.title,
      artist: split.artist,
      duration: double.nan,
      isLocal: true,
      handle: FilePathHandle(path),
    );
  }

  /// 来源字符串 → 展示用文件名。测试用的入口，规则见 [displayNameForSource]。
  @visibleForTesting
  String displayNameFor(String source) => displayNameForSource(source);

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

/// 来源字符串 → 展示用文件名（含扩展名）。
///
/// - 普通文件路径：取最后一段，Windows 反斜杠与 POSIX 斜杠都认；
/// - URI 形态（`content://…`）：解析后取最后一个路径段、百分号解码，再取
///   解码结果的 basename —— 解码后可能自带分隔符
///   （`primary%3AMusic%2Fa.flac` → `primary:Music/a.flac` → `a.flac`）；
///   解码成空串或解析失败就退回按路径切：名字难看可以忍，导入不许抛。
///
/// 顶层函数（而不是 [ImportService] 的私有方法）：还原自愈的判定
/// [metadataIncomplete] 也要按同一套规则算「文件名拆出来的猜测值」，
/// 两处必须一模一样，否则「看起来还是文件名」会判歪。
String displayNameForSource(String source) {
  if (!_uriSourcePattern.hasMatch(source)) return _basename(source);
  final String decoded;
  try {
    final path = Uri.parse(source).path;
    final cut = path.lastIndexOf('/');
    // 用未解码的 path 自己切最后一整段，保证只解码一次：
    // pathSegments 已经解过码，再解一次会把名字里的 `%` 文本吃掉。
    final raw = cut < 0 ? path : path.substring(cut + 1);
    decoded = Uri.decodeComponent(raw);
  } on FormatException {
    return _basename(source);
  } on ArgumentError {
    return _basename(source);
  }
  final name = _basename(decoded);
  if (name.isNotEmpty) return name;
  return decoded.isNotEmpty ? decoded : _basename(source);
}

/// 这条记录的元数据还缺不缺、需不需要**自愈回填**
/// （[ImportService.rehydrateIncomplete] 的判据）。
///
/// 终审 R1 的裁定：决定「还要不要去看一眼」的**唯一依据是那个落盘的探测标记**
/// `Track.metadataProbed`；字段启发式只回答「去看一眼有没有可赚的东西」。
///
/// 从前这里把「没有真封面」当成「没回填过」的证据。它不是：`cover` 只在文件
/// 真的内嵌封面时才有值，无封面的歌永远 `hasRealCover == false`；而
/// [_stillFileNameGuess] 对「`歌手 - 歌名` 命名 + 带标签」这批用户的真实曲目
/// 几乎恒为 true（标签标题本来就等于文件名右半段）。两条叠起来的后果是
/// **每次启动**都把整个曲库重开一遍文件、重解析一遍标签、再整库重写一次档案
/// —— 守护它的那条用例用的是「有封面 + 标题与文件名不同」的曲目，所以一直绿。
///
/// 标记为假时仍然要再看一眼字段：全都齐了就没必要开文件，于是老档案升级后
/// 只补跑一次、之后永远不再重跑（`metadataProbed` 与字段两道闸缺一即跳过）。
///
/// 只认本地文件：SAF / 远程来源在 M1 读不了字节，判成「缺」也只会白跑一遍。
bool metadataIncomplete(Track track) {
  if (!track.isLocal) return false;
  // 探测过的（包括「探不出东西」的）永远不再重跑 —— 这条才是回归的根治点。
  if (track.metadataProbed) return false;
  return _metadataFieldsMissing(track);
}

/// 字段层面还缺不缺：时长未知，或标题 / 歌手仍停在文件名猜出来的值上。
///
/// 第三种情况是 C1 那次事故的直接特征 —— 回填没落库，重启读回来的就是纯文件名
/// 拆分值。终审 R1 在这里**去掉了 `!hasRealCover`**：没有封面不是「没回填过」
/// 的证据，它只是这个文件没有图。
bool _metadataFieldsMissing(Track track) {
  if (!track.hasDuration) return true;
  return _stillFileNameGuess(track);
}

/// 标题 / 歌手是否还是文件名拆出来的那份猜测。
bool _stillFileNameGuess(Track track) {
  final guess = splitArtistTitle(
    _stripExtension(displayNameForSource(track.src)),
  );
  if (guess.title.isEmpty) return false;
  if (track.title == guess.title) return true;
  return guess.artist.isNotEmpty && track.artist == guess.artist;
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
