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
import '../lyrics/manual_lyrics.dart';
import '../playback/play_error.dart' show extensionOf, isLyricsExtension;
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/track_handle.dart';
import '../playback/transport_controller.dart' show ToastSink;
import 'audio_filter.dart';
import 'duration_probe.dart';

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
  ///
  /// 值 = **这一批有没有学到东西**（任何一条记上了探测标记就为真，第 4 轮 I9）：
  /// 一条都没学到时调用方不该再整库重写一遍档案 —— 那是每次启动白写一次盘。
  final Future<bool>? enrichment;
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
    this.manualLyrics,
  });

  final Playlist playlist;
  final ToastSink toasts;

  /// 手动 `.lrc` 的应用器（T12）。没给就退回「`.lrc` 与其它非音频一样被拒绝」。
  ///
  /// 由装配层（`main.dart` 的 `buildBootstrap`，T15）构造并传入，**不要**在本类
  /// 里自己 new 一个：调用方（`LibraryState.applyLyricsFiles`）也要用它，两边
  /// 必须**同一个实例**，否则「谁改了哪个对象」分不清。
  final ManualLyrics? manualLyrics;

  /// 内嵌封面落盘器。与 [coverDirectory] 同时给了才会写。
  final CoverImageWriter? covers;

  /// 封面落盘目录（应用缓存目录下的 covers/）。
  final String? coverDirectory;

  /// 时长探测：来源 → 结论（[DurationProbeOutcome]，含「是不是被超时掐掉的」）。
  ///
  /// 注入而不是在这里引播放器：导入属于数据层，探时长是平台能力，由装配层
  /// （`main.dart`）把内核那侧递进来 —— 生产上是 `DurationProbe` 包着的
  /// media_kit opener（终审 I1：这条线以前根本没接，ID3v1-only / FLAC 无
  /// Vorbis comment 的曲目就永远没有时长，进度条一直是 `--:--`）。
  ///
  /// 异步签名：真探测要等原生内核回报时长，同步版只能靠阻塞读，而那会冻住
  ///  isolate。实现必须在自己的预算内返回且绝不抛（排队 / 超时见
  /// `library/duration_probe.dart`）。
  ///
  /// 返回值为什么不是裸 `double`（第 3 轮 C1）：探测标记 `metadataProbed`
  /// 只在「这个文件真的没有时长」时才许记，而**超时**是暂时的失败、记了就
  /// 等于把这一个人永久冻结在降级状态。两路从前都只给 NaN，分不开。
  /// 生产上接的是 `DurationProbe.probeOutcome`。
  final Future<DurationProbeOutcome> Function(String source)? durationProbe;

  /// 新曲目入列后回调（落库用）。fire-and-forget，出错不影响导入结果。
  final Future<void> Function(List<String> ids)? onImported;

  /// 导入一批路径。
  ///
  /// 空输入直接返回零结果、不发提示（拖了个空文件夹不该弹「已跳过 0 个」）。
  /// 白名单外的一律拒绝**并点名**（有上限，见 [_maxNamedRejections]），
  /// 其余立刻入列；标签 / 时长在后台补。
  /// 同一个文件重复导入不会变成两条记录：已在列表里的只交回 id，不重建。
  ///
  /// `.lrc` 在分区**之前**就被挑出去交给 [manualLyrics]（`src/state/library.tsx:116-117`
  /// 的 `lyricsFiles` / `mediaFiles` 两分）：它们既不算拒绝、也不算新增，
  /// 不进 `ImportResult` 的任何计数 —— 歌词文件不是「不支持的音频」，
  /// 也不是「加进来的曲目」。挑出去这一步必须早于 [partitionByExtension]，
  /// 否则 `.lrc` 会先落进 `rejected`、再被 `_announceRejections` 报一句
  /// 「不支持的文件格式」，而那正是 T12 要消掉的误报。
  ///
  /// **挂歌词排在音频入列之后**，对齐 `library.tsx:170-181`。原版那句注释写得很
  /// 明白：`.lrc` 要放在音频入列（并纠正名字）之后再挂，「否则同名歌词配不到刚
  /// 加进来的曲目上」。反过来（先挂歌词）就会让同一批里的音频永远配不上自己的
  /// 歌词文件。
  ///
  /// 没有配 [manualLyrics] 时（本任务之前的装配、若干测试）`.lrc` 退回原样：
  /// 仍算拒绝，行为与从前一字不差。
  Future<ImportResult> importPaths(List<String> paths) async {
    if (paths.isEmpty) return const ImportResult();
    final manual = manualLyrics;
    if (manual == null) return _importMedia(paths);
    final lyricsPaths = <String>[];
    final mediaPaths = <String>[];
    for (final path in paths) {
      (isLyricsExtension(extensionOf(path)) ? lyricsPaths : mediaPaths)
          .add(path);
    }
    // 音频那半照原流程走（含拒绝提示与入列），歌词那半等到它之后。
    final result = mediaPaths.isEmpty
        ? const ImportResult()
        : await _importMedia(mediaPaths);
    // 只拖了歌词文件时也要挂（原版 `library.tsx:123-129`：不该被当成
    // 「没有可导入的文件」）；一批只有音频时这里自然什么都不做。
    if (lyricsPaths.isNotEmpty) await manual.apply(lyricsPaths);
    return result;
  }

  /// 音频那半的导入流程（[importPaths] 分流之后的正体）。
  Future<ImportResult> _importMedia(List<String> paths) async {
    if (paths.isEmpty) return const ImportResult();
    final partition = partitionByExtension(paths);
    _announceRejections(partition.rejected);

    // idsInCall：本次涉及的 id（含本来就在列表里的），按首次出现顺序去重。
    // newIds：真正新入列的，决定 added、后台回填与落库钩子。
    // enrichTasks：本批回填的任务，汇成 [ImportResult.enrichment] 交调用方收尾。
    final idsInCall = <String>[];
    final seen = <String>{};
    final newIds = <String>[];
    final enrichTasks = <Future<bool>>[];
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
  ///
  /// 返回值是**这次到底有没有打开文件、读到过字节**（第 3 轮 C1）：调用方
  /// （[_enrichQuiet]）用它决定要不要记那个持久的探测标记。false 只代表
  /// 「什么都没看到」，绝不代表「这文件没标签」—— 两者混起来的代价见 [_enrichQuiet]。
  Future<bool> hydrateMetadata(Track track) async {
    final live = playlist.byId(track.id) ?? track;
    final path = live.handle.pathish;
    final head = await _prefetchHead(path);
    // null 的含义按 [_prefetchHead] 自己的注释就是「文件不存在 / 打不开 /
    // SAF URI 用不了 dart:io」，不是「标签为空」——所以这里如实报「没打开」。
    if (head == null) return false;
    final source = ByteSource.fromFile(path, prefetched: head);
    final tags = await readAudioTags(source, fileName: live.handle.displayName);
    // 打开了、也确实什么标签都没有：这是**结论**，同样报「打开了」。
    if (!tags.hasAnyText && !tags.hasPicture) return true;

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
      return true;
    }
    // 第 4 轮 I10：封面落盘是「增值里的增值」——写不进去只影响 `cover` 字段。
    // 从前这一句抛出去会冒到 `_enrichQuiet` 的 catch，把**已经拿到的**标签
    // （上面那三行已经写进活对象）与时长结论一起判成「这次没回填」，标记不记、
    // 下次启动重来一遍，白读一遍字节。
    final saved = await _writeCoverQuietly(
      writer,
      picture,
      tags.pictureMime,
      directory,
      live.id,
    );
    if (saved != null) live.cover = saved;
    return true;
  }

  /// 写封面，任何失败都只意味着「这张图没落上」（返回 null），绝不外抛。
  Future<String?> _writeCoverQuietly(
    CoverImageWriter writer,
    Uint8List picture,
    String mime,
    String directory,
    String id,
  ) async {
    try {
      return await writer.write(picture, mime, directory: directory, id: id);
    } catch (_) {
      // 磁盘满 / 目录只读 / 编码器内部异常：都不该带走同一次回填的其余结论。
      return null;
    }
  }

  /// 入列后的后台补全：标签 → 时长。
  ///
  /// 标签先跑，是为了让「文件名猜反了」的曲目在探时长之前就拿到正确的词
  /// （与原版 tagging.ts 的顺序一致）。时长只填空缺：已经有时长的不重探。
  ///
  /// 返回值 = 「这一条可以记探测标记」（第 3 轮 C1，第 4 轮 C8/I9 补齐两处）：
  ///   1. 时长探针**真的问过**、没被预算掐掉、途中也没被 `close()` 关掉
  ///      （`DurationProbeOutcome.isConclusive`，C8）；
  ///   2. 而且这一次**确实有见证**：要么读到了文件字节（`opened`，标签那一路），
  ///      要么探到了时长（`outcome.isKnown`，I9 —— mpv 打得开而 dart:io 打不开的
  ///      文件，Windows 共享冲突下就是这个形状）。
  /// 「打开了、也确实没标签没时长」同样算可以记 —— 那是文件给的结论，R1 要的
  /// 正是结论落一次盘就不再重跑。
  Future<bool> _enrich(Track live) async {
    // 这一路唯一的失败形状是「文件没打开」（打不开时 hydrate 什么都没读到）。
    final opened = await hydrateMetadata(live);
    final probe = durationProbe;
    if (probe == null || live.hasDuration) return opened;
    // 终审 R7：句柄自己说「能不能探」。SAF 的 `content://` 在 M1 开不了，
    // 让它进队列就是每首白等满 3000ms 预算换一个 NaN —— 而且这个 NaN 正好
    // 会和 R1 的「探不出」叠成反复重跑。标签那条照旧尽力（读不了就是读不了）。
    // 第 3 轮 I1 之后这条是**双保险**：谓词 `metadataIncomplete` 已经按同一个
    // 能力位把这类曲目挡在队列外，挡不住的路径（导入那一条）仍然归这里兜。
    if (!live.handle.canProbeDuration) return opened;
    // 探时长排在标签之后、也排在整批完成信号之前：批次的落库收尾会连它一起落盘。
    final outcome = await probe(live.handle.pathish);
    // 能填就填：NaN / 0 / 负数 / 无穷都算「探不出来」，未知时长必须保持 NaN，
    // 不是 0；拿到了正数就写进活对象 —— 哪怕这次不算结论（下面那支），界面也
    // 该早一点有进度条（第 4 轮 C8 的要求：别把已拿到的东西一起丢掉）。
    if (outcome.isKnown) live.duration = outcome.seconds;
    // 结论只认「真的问过内核、没被预算掐掉、途中也没被关掉」这一种（第 3 轮 C1 +
    // 第 4 轮 C8）：超时是暂时的失败（大文件、盘没挂稳、媒体线程排队），探针在
    // 途中被关掉（退出时正在跑自愈回填）是整批被丢弃的尝试 —— 两者记上标记就
    // 等于把这批曲目永久冻在 `--:--`，一点自愈都不剩。
    if (!outcome.isConclusive) return false;
    // 第 4 轮 I9：**探到了时长本身就是一次见证**。mpv 打得开而 dart:io 打不开的
    // 文件（Windows 共享冲突 / 正被另一个进程独占）标签一个字节也读不到，但时长
    // 是真的；从前只认 `opened`，这类曲目永远不记账 —— 每次启动重开文件、重探
    // 一遍，再由批次收尾把整库档案重写一遍（`library_state.dart` 的收尾落库）。
    return opened || outcome.isKnown;
  }

  /// [_enrich] 的「绝不抛」外壳：失败只意味着这次没回填。
  ///
  /// 必须存在：批次的完成信号是 `Future.wait` 出来的，一条抛错会把整批的落库
  /// 收尾一起带走（终审 C1 要的就是那次收尾）。
  ///
  /// 标记这一记是终审 R1 的**根治点**，也是第 3 轮 C1 改的那一刀：从前这里
  /// 写在 `finally` 里、无条件置位，于是「文件根本没打开」「探针被超时掐了」
  /// 这两支什么都没干成的路也照样记上「已探测」。**第 4 轮 C8 又补上第三支**：
  /// 探针在探测途中被 `close()` 关掉（退出时正在跑自愈回填）同样是「没探成」，
  /// 它从前返回一个与「文件没有时长」完全同形的 NaN。重复导入同一个路径是 no-op
  /// （`isNew == false`），谓词此后恒为 false —— 除了改档案格式之外没有任何
  /// 自愈路径，一次暂时的失败就被冻结成永久降级（歌手/歌名猜反、时长永远
  /// `--:--`）。现在只有 [_enrich] 明确回报「看到了结论」才记账，抛错同样不记。
  ///
  /// **接受那一侧的代价，别改回旧写法**：真的永久拔掉的盘会每次启动都重试
  /// 一次。这不是回到 R1 之前那种整库重跑 —— 谓词里 `!metadataProbed` 那道
  /// 闸还在，每条曲目**一次启动最多重试一次**、失败即不置位，也不会波及库里
  /// 任何一条已经记上标记的曲目；探针本身还是串行的，预算封顶 3000ms/首。
  /// 换来的是「插回硬盘的下次启动就能自愈」，这笔账是划算的。
  ///
  /// 标记随那一次批次收尾 `persist()` 一起落盘。
  ///
  /// 返回值 = 这一次有没有真的记上标记（第 4 轮 I9）：整批都没记上就说明这一批
  /// 什么也没学到，调用方据此跳过那次「整库重写档案」的收尾。
  Future<bool> _enrichQuiet(Track live) async {
    var settled = false;
    try {
      settled = await _enrich(live);
    } catch (_) {
      // 回填是增值项：导入已经成功，这里不许冒泡。
      // 抛错也**不记账**（第 3 轮 C1）：什么都没看到，就还是欠着一次重试。
      settled = false;
    }
    if (!settled) return false;
    // 记在**列表里的活对象**上（文件头第 2 条同一个理由：改到克隆副本上
    // 就等于没改，标记落不了盘）。
    (playlist.byId(live.id) ?? live).metadataProbed = true;
    return true;
  }

  /// 一批回填的完成信号；空批次给 null（调用方据此决定要不要再落一次库）。
  ///
  /// 值 = 「这一批有没有学到东西」（任何一条记上了就为真，第 4 轮 I9）：
  /// 一条都没学到时不该再整库重写一遍档案，那是每次启动白写一次盘。
  Future<bool>? _batchOf(List<Future<bool>> tasks) {
    if (tasks.isEmpty) return null;
    return Future.wait(tasks).then(
      (results) => results.any((learned) => learned),
    );
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
  /// 返回本批的完成信号（没有要补的就返回 null；值是「这一批有没有学到东西」，
  /// 第 4 轮 I9），调用方在它完成后落一次库、刷一次界面 —— 那一次落库同时把
  /// 这一批新记上的探测标记带上盘。一条都没学到时调用方不该再整库重写档案。
  ///
  /// 与 [importPaths] 一样不挡首帧：曲目早就在列表里、也早就可播。
  Future<bool>? rehydrateIncomplete() {
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
/// 准入条件为什么是**能力位**而不是 `isLocal`（第 3 轮 I1）：SAF 的
/// `content://` 在 M1 既开不了字节也探不了时长，判成「缺」就是每次启动白跑
/// 一遍；更关键的是它**也不该被记上探测标记**（[_enrichQuiet] 那一刀），否则
/// M2 真接上 SAF 读取之后，这批曲目在谓词眼里永远是「已经管过了」，新能力
/// 对它们隐形。用句柄自己报的能力位，M2 把 `canProbeDuration` 翻成真值的那一刻，
/// 这些曲目自动回到未探测状态、自愈管路自动接上。
///
/// 与从前 `!isLocal` 的**外延并不相同**（别按「换了写法、判定没变」去理解）：
/// 能力位只问「这条来源能不能开」，不问那条记录标没标自己本地。于是老档案里
/// `isLocal` 缺省成 false 的纯路径记录（`Track.fromJson` 用 `map['isLocal'] == true`，
/// 缺字段即 false）**开始进队列了** —— 该进，路径是真能开的；`app_bootstrap_test`
/// 里那条「旧档案里残留的 volume / muted 不参与还原」就记着这个形状。
/// 远程 URL 仍被挡在门外，因为 `FilePathHandle` 的 `canProbeDuration` 对
/// `http(s)://` 同样给 false（来源根本不是文件）。
bool metadataIncomplete(Track track) {
  // 能力判断：句柄自己说「这条来源我到底能不能读」。
  if (!track.handle.canProbeDuration) return false;
  // 探测过的（包括「打开了、确实什么也没有」的）永远不再重跑 —— 这条才是
  // 反复重跑的根治点。**没打开过 / 探针超时** 的不在这里（第 3 轮 C1：
  // 那种一次什么都没干成的尝试不许记账），于是下次启动还会再看一眼。
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
