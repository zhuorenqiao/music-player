// lib/state/library_state.dart
//
// 曲库状态：对译原版 `state/library.tsx` 里 M1 需要的部分（导入 → 落库 →
// 冷启动还原），再加上播放列表面板的搜索关键词。
//
// 三条与原版一致的约束：
//   - **入列与落库解耦**：`ImportService` 负责入列，落库只在这里的 [persist]；
//   - **还原期间 `restoring` 为真**：界面据此画骨架而不是闪一帧空态；
//   - **搜索只匹配歌名**，关键词走 200ms 防抖（原版 App.tsx 的 applyKeyword），
//     输入框用即时值回显，过滤用 [filteredTracks] 里的生效值。
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_prefs.dart';
import '../core/storage_keys.dart';
import '../library/import_service.dart';
import '../library/library_repository.dart';
import '../playback/play_mode.dart';
import '../playback/playlist.dart';
import '../playback/track.dart';
import '../playback/transport_controller.dart' show ToastSink;

/// 搜索关键词的防抖窗口（毫秒）。与原版 `debounce(..., 200)` 同值。
const int kSearchDebounceMs = 200;

/// 曲库状态。
class LibraryState extends ChangeNotifier {
  LibraryState({
    required this.prefs,
    required this.repo,
    required this.importer,
    required this.toasts,
    this.onPlaylistChanged,
  });

  final AppPrefs prefs;
  final LibraryRepository repo;
  final ImportService importer;
  final ToastSink toasts;

  /// 播放列表被改动（还原 / 导入 / 删除 / 清空 / 换当前曲目）后的回调。
  ///
  /// 这些路径不经过播放编排，不会产生播放器事件；装配层把它接到
  /// `TransportController` 上，界面与系统通知栏的视图快照才不会停在旧值。
  ///
  /// [removedId] 只在删除时有值：装配层据此判断「删掉的是不是正在播的那首」
  /// （是就接着播下一首）。清空 / 删空没有单独的标记 —— 列表空了就该停播，
  /// 装配层看 `tracks.isEmpty` 即可。状态层只负责喊这一声，不认识播放编排。
  final void Function({String? removedId})? onPlaylistChanged;

  String _keyword = '';
  String _effectiveKeyword = '';
  bool _restoring = false;
  Timer? _searchDebounce;

  /// 搜索框的文本控制器（T28 面板用）。
  ///
  /// 输入框的即时值就是它自己的内容；[keyword] 被外部改写时（点清空按钮、
  /// 快捷键）这里也跟着同步，否则输入框会停在旧文字上。过滤一律走
  /// [filteredTracks]（防抖后的生效值），不要把控制器内容直接拿去过滤。
  final TextEditingController searchController = TextEditingController();

  /// 曲目列表与 `ImportService` 共用同一份（导入即入列，不需要二次同步）。
  Playlist get playlist => importer.playlist;

  /// 列表里的活对象（原地变更，不产生副本）。
  List<Track> get tracks => playlist.tracks;

  /// 输入框里的即时值。
  String get keyword => _keyword;

  /// 防抖之后真正参与过滤的关键词（`trim` + 小写）。
  ///
  /// 统计行用它判断「现在是不是过滤中」：拿 [keyword] 判断会让统计行比列表
  /// 早一拍跳变，200ms 里出现「找到 N 首」配着完整列表的矛盾画面。
  String get effectiveKeyword => _effectiveKeyword;

  /// 是否正在从文件仓还原。整个异步加载期间都为真。
  bool get restoring => _restoring;

  String? get currentId => playlist.current?.id;

  /// 总时长（秒，向下取整）。未知时长不参与累加（[Playlist.totalDuration]）。
  int get totalSeconds =>
      playlist.totalDuration.isNaN ? 0 : playlist.totalDuration.floor();

  /// 显示用的过滤结果：只匹配歌名（两个 tab 共用同一关键词，原版如此）。
  List<Track> get filteredTracks {
    if (_effectiveKeyword.isEmpty) return playlist.tracks;
    return playlist.tracks
        .where((t) => t.title.toLowerCase().contains(_effectiveKeyword))
        .toList();
  }

  /// 设置搜索关键词。
  ///
  /// 生效值（`trim` + 小写）走 200ms 防抖：输入法打一个词会连发好几次 change，
  /// 逐键重建整张列表没必要。**删到空立刻生效** —— 清空时用户要马上看到完整
  /// 列表，原版 clearSearch 里那句 `applyKeyword.cancel()` 就是这条。
  set keyword(String next) {
    if (_keyword == next) return;
    _keyword = next;
    _syncSearchText(next);
    _searchDebounce?.cancel();
    _searchDebounce = null;
    final normalized = next.trim().toLowerCase();
    if (normalized.isEmpty) {
      _effectiveKeyword = '';
      notifyListeners();
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: kSearchDebounceMs), () {
      _effectiveKeyword = normalized;
      notifyListeners();
    });
    notifyListeners();
  }

  /// 把 [keyword] 的新值同步回输入框。文本没变就不动 —— 重新赋 `value` 会
  /// 把光标挪到末尾，用户正在中间插字时不该被打断。
  void _syncSearchText(String next) {
    if (searchController.text == next) return;
    searchController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  /// 点了「最近播放」里已经不在列表中的条目：只提示，不假装播放。
  ///
  /// 同 key 的提示只留一条（连点不会叠一串），与原版 `show(..., 'info')` 一致。
  void toastMissingInPlaylist() =>
      toasts.show('这首歌已经不在播放列表里了', key: 'recent-missing');

  /// 冷启动还原：读存档 → 按存档顺序整体替换列表 → 恢复模式与当前曲目。
  ///
  /// **三条不同的优先级**（终审 I4 已裁定顺序与光标，终审 R6 补上模式；
  /// 规则见 [_restoreCursor] 与 [_restoreMode]）：
  ///   - **顺序**永远以文件仓为准 —— prefs 里那份 `order` 陈旧也不参与列表重建，
  ///     还原末尾还会被 [_syncPrefsTrace] 纠正回来；
  ///   - **光标**在「现场自洽」时以 prefs 的 `currentId` 为准：播放推进只经
  ///     `PlayerState.flushPersist()` 写 prefs、不重写文件仓，所以 prefs 才是
  ///     最后一次如实写入的光标；两份 order 逐位一致就是「这份现场没跨代过期」
  ///     的闸门。自洽而**键缺失**是否定断言（用户停过播放，终审 R2），不许再
  ///     回落到档案值；矛盾（或缺 order）时整份现场按陈旧处理，退回文件仓的
  ///     `currentId`。**两边都给不出有效光标时落到列表第一首**（终审 R4，
  ///     原版 `src/state/player.tsx:556`），只有空列表才是空舞台。矛盾（或缺
  ///     `order`）时整份按陈旧处理、退回档案的 `currentId`，但「痕迹写过而
  ///     `currentId` 缺失」这句否定断言**照旧算数**（第 3 轮 M3），否则走
  ///     `.bak` 回退时会把用户停过的那一首重新扶正。
  ///   - **模式**同权：prefs 写过 `mode` 就以它为准（`PlayerState.cycleMode`
  ///     只写这一处，档案里那份要等下一次 `persist()` 才跟上），没写过才回落
  ///     `snap.mode`（终审 R6，见 [_restoreMode]）。
  ///
  /// [restoring] 覆盖整个异步加载（首帧就画骨架），结束无论成败都置回 false。
  /// 脏存档绝不外抛：仓储自己会退回空快照，这里再兜一层，启动流程不许因此中断。
  ///
  /// 还原末尾还要补一遍**自愈回填**（终审 C1）：早于回填落库修复存下的档案里
  /// 就是「只有文件名、时长 NaN、无封面」，不补这一刀，用户升级后看到的还是
  /// 空标题无封面 —— 原版靠浏览器每次重读标签，没有这个坑，只能在这里补。
  ///
  /// 判据是 `Track.metadataProbed` 这个**落盘的探测标记**（终审 R1）：老档案
  /// 第一次启动补跑一遍、把标记随批次收尾一起落盘，之后永远不再重跑。从前
  /// 这里按字段猜（「没有封面」「标题还等于文件名猜的值」），对真实曲库形状
  /// 几乎恒真，于是每次启动把整个曲库重开文件重解析一遍、再整库重写一次档案。
  Future<void> restore() async {
    _restoring = true;
    notifyListeners();
    try {
      final snap = await repo.load();
      // 终审 R8：档案损坏（回退过 `.bak`、或两份都读不出来退回空快照）时，
      // 还原流程**只读痕迹、不写痕迹**。那份快照本身什么也没说——按它写下去
      // 就是把 prefs 里最后一条可读记录覆盖成 `[]`，用户连「停过哪一首」这条
      // 线索都没了。只有真正拿到过一次健康档案才允许改写现场。
      final traceWritable = !snap.corrupted;
      if (snap.tracks.isEmpty) {
        playlist.clear();
        if (traceWritable) await _syncPrefsTrace();
        return;
      }
      final byId = {for (final track in snap.tracks) track.id: track};
      final ordered = [
        for (final id in snap.order)
          if (byId.containsKey(id)) byId[id]!,
      ];
      final mode = await _restoreMode(snap);
      playlist.replaceAll(ordered);
      playlist.setMode(mode);
      // 顺序的权威一律是文件仓（上面 `ordered` 只由 snap.order 构造，prefs 里
      // 那份陈旧 order 参与不了顺序）；光标按 [_restoreCursor] 的优先级定。
      await _restoreCursor(snap);
      // 痕迹要跟真相一致：纠正 prefs 的那份 order，并把 R4 落定的光标补写回去
      //（终审 I4 + R4）。损坏的那一份不动它（R8）。
      if (traceWritable) await _syncPrefsTrace();
      _flushAfterEnrichment(importer.rehydrateIncomplete());
    } catch (_) {
      // 理论上到不了这里（仓储是总函数），留作最后一道闸：启动不许炸
      playlist.clear();
    } finally {
      _restoring = false;
      _changed();
    }
  }

  /// 还原时当前指针的判定（终审 I4 + R4，方案 (a)+(b) 的混合：prefs 既写**也读**，
  /// 并且如实清除）。
  ///
  /// `prefs` 的 [StorageKeys.currentId] 与 [StorageKeys.order] 是**一对现场快照**，
  /// 要信就整份信，怀疑就整份怀疑：
  ///   1. 快照自洽（它的 order 与文件仓顺序逐位相同）时，[StorageKeys.currentId]
  ///      就是最后一次如实写入的光标 —— 播放推进只经 `PlayerState.flushPersist`
  ///      更新 prefs，并不会重写文件仓，此时 prefs 比存档里的 `currentId` 更新；
  ///      它仍指向列表里的曲目就用它。**这个键缺失**在同一前提下是一句
  ///      **否定断言**（用户停过播放 / 当前曲目被删空过，两边都把它如实清了，
  ///      终审 R2），于是候选是空集：绝不回落到 `snap.currentId` —— 那正是
  ///      停止之前那次 persist 写下的旧值，回落它就是把停掉的歌复活。
  ///   2. 快照自相矛盾（order 与文件仓不一致）或缺失时，整份按过期处理，
  ///      退回文件仓快照的 `currentId` —— 顺序与曲目以文件仓为权威。
  ///      **唯一的例外**是那句否定断言（第 3 轮 M3）：痕迹里的 `order` 写过、
  ///      而 `currentId` 不在，那不管是哪一代都在说「没有光标」，此时候选是空集，
  ///      档案里那份 `currentId` 也不许打头。
  ///   3. 两边都指不到列表里的曲目（光标被删 / 键被清）时**落到列表第一首**，
  ///      保持暂停、不自动播（终审 R4）：原版
  ///      `src/state/player.tsx:556` 写的是
  ///      `storedId && playlist.indexOfId(storedId) >= 0 ? indexOfId(storedId) : 0`
  ///      —— 任何一次非空启动都落得到一个光标，只有空列表才是空舞台。第 1 轮
  ///      移植在这里调了 `clearCurrent()`（「没有有效 id 就没有光标」），界面
  ///      于是停在「未选择曲目」的假空舞台上。随后的 [_syncPrefsTrace] 会把
  ///      prefs 的 `currentId` 补写成这一首（原版每次 persist 都跟着列表重写，
  ///      `player.tsx:243-249`），不留「界面指第一首、存档指幽灵」两份真相。
  ///
  /// 原版同一优先级（`src/state/player.tsx:555`：`storedId` 仍在列表里就
  /// `setCurrentIndex(indexOfId(storedId))`），只是它的曲目档案与顺序同在
  /// `localStorage.playlist` 一份里、没有「文件仓 vs prefs」这对矛盾。
  Future<void> _restoreCursor(LibrarySnapshot snap) async {
    final traceId = await prefs.readString(StorageKeys.currentId);
    final traceOrder = await prefs.readJson(StorageKeys.order);
    final traceIsCurrent = _sameIds(
      traceOrder,
      playlist.tracks.map((track) => track.id).toList(),
    );
    // 「现场自洽」时键缺失＝否定断言（R2），键在就用它；「现场过期」时整份
    // prefs 都不作数，才轮到文件仓的 `currentId` 打头。
    //
    // 但**这句否定断言本身不以「自洽」为前提**（第 3 轮 M3）：只要 prefs 那份
    // 痕迹写过（`order` 键在盘上），而 `currentId` 不在，就是「用户停过播放 /
    // 当前曲目被删空过」一次如实清除。从前它只在痕迹自洽时才生效，于是
    // R8 × R2 的双故障组合（走 `.bak` 回退 → 天生带着上一代的陈旧 order）里
    // 候选变成 `[snap.currentId, traceId]`，第一顺位正是停止之前那次 persist
    // 留下的旧值 —— 停过的歌照样复活。痕迹新不新鲜决定的是「要不要信它指的
    // 那一首」，不是「要不要信它说没有光标」。
    //
    // 反过来，连 `order` 都没有（首次使用 / 老版本从没写过痕迹）时就真的没有
    // 任何陈述，仍按原规则让档案说话。
    final traceWasWritten = prefs.containsKey(StorageKeys.order);
    final stopDeclared =
        traceWasWritten && !prefs.containsKey(StorageKeys.currentId);
    final candidates = stopDeclared
        ? const <String?>[]
        : !traceIsCurrent
        ? <String?>[snap.currentId, traceId]
        : <String?>[traceId];
    for (final id in candidates) {
      if (id != null && playlist.indexOfId(id) >= 0) {
        playlist.setCurrentById(id);
        return;
      }
    }
    // 没有任何有效光标：与原版一致落到第一首（暂停，不自动播）。
    // 列表在这里必定非空（`restore()` 对空列表提前返回），但仍按 size 兜一层，
    // 免得将来有人在别处复用这条判据时凭空造出一个「第 0 首」。
    if (playlist.size > 0) {
      playlist.setCurrentIndex(0);
    } else {
      playlist.clearCurrent();
    }
  }

  /// 还原时播放模式的判定（终审 R6）：**prefs 是更新的陈述，档案只是兜底**。
  ///
  /// 与光标那一条同源同权：`PlayerState.cycleMode` 改完模式只写 prefs
  /// （`lib/state/player_state.dart`），文件仓里那份 `mode` 只在列表变化时才
  /// 跟着重写。第 1 轮把 `currentId` 升级成「prefs 优先」时漏了 mode，于是
  /// 「随机播放听了一半直接退出重开」会被档案里的旧模式盖回去。
  ///
  /// 原版的优先级更硬：模式只存在 localStorage 的 `mode` 一个键里
  /// （`src/state/player.tsx:343` 写、`:567` 读回，缺省 `PLAY_MODES.LIST`），
  /// 曲目档案里压根没有模式这一项 —— 我们多一份档案只是多一层兜底。
  ///
  /// 判定读的是 `readString`，与 `PlayerState._loadPersistedPrefs` 那一条完全同一个
  /// 取法：读到值就用（脏值由 [playModeFromId] 归成列表循环，与原版
  /// `Storage.read(mode, PLAY_MODES.LIST)` 的缺省同一处理），读不到（键没写过，
  /// 或值不是字符串）才轮到档案 —— 两处判据不一样就会「ready 读回 A、restore
  /// 改成 B」，那是两份真相。
  Future<PlayMode> _restoreMode(LibrarySnapshot snap) async {
    final raw = await prefs.readString(StorageKeys.mode);
    if (raw != null) return playModeFromId(raw);
    return snap.mode;
  }

  /// prefs 里那份 `order` 是不是与真相逐位相同（不是 List、长度不符、有非字符串
  /// 都算「不一致」，按过期现场处理）。
  bool _sameIds(Object? raw, List<String> truth) {
    if (raw is! List || raw.length != truth.length) return false;
    for (var i = 0; i < truth.length; i++) {
      if (raw[i] != truth[i]) return false;
    }
    return true;
  }

  /// 导入一批文件；有新入列就落库并提示，回填批次收尾时再落一次。
  Future<int> importPaths(List<String> paths) async {
    final result = await importer.importPaths(paths);
    if (result.added > 0) {
      toasts.show('已添加 ${result.added} 首', key: 'import');
      await persist();
      _changed();
    }
    // 回填没补上任何东西（result.added == 0 / 全是重复导入）时 null，不多落库。
    _flushAfterEnrichment(result.enrichment);
    return result.added;
  }

  /// 扫一个目录再导入（桌面「添加整个文件夹」）。
  Future<int> importDirectory(String root) async {
    final result = await importer.importDirectory(root);
    if (result.added > 0) {
      toasts.show('已从文件夹添加 ${result.added} 首', key: 'import');
      await persist();
      _changed();
    }
    _flushAfterEnrichment(result.enrichment);
    return result.added;
  }

  /// 只换当前曲目（不自动播放，播放与否归 PlayerState）。
  Future<void> setCurrent(String id) async {
    playlist.setCurrentById(id);
    await persist();
    _changed();
  }

  /// 从列表与文件仓里一起删掉一首。
  ///
  /// 删的是当前曲目时，[Playlist.removeById] 的索引保持不动 —— 也就是自动落到
  /// 接续的那一首；删空之后 `currentId` 自然变 null。
  Future<void> removeTrack(String id) async {
    final track = playlist.byId(id);
    if (track == null) return;
    playlist.removeById(id);
    await repo.deleteTracks([id]);
    toasts.show('已移除《${track.title}》', key: 'remove');
    await persist();
    _changed(removedId: id);
  }

  /// 清空播放列表：内存、文件仓与两份 prefs 键一起清。
  Future<void> clearPlaylist() async {
    final ids = playlist.tracks.map((t) => t.id).toList();
    playlist.clear();
    await repo.deleteTracks(ids);
    // 顺序与当前曲目是 PlayerState 的存档键，清空时一并作废，
    // 否则下次启动会拿着一张指向空列表的 currentId。
    await prefs.remove(StorageKeys.currentId);
    await prefs.remove(StorageKeys.order);
    toasts.info('播放列表已清空');
    _changed();
  }

  /// 落库：曲目元数据 + 顺序 + 当前曲目 + 模式。
  ///
  /// **音量与静音不在这里**（终审 minor 4 / A1）：原版只有 localStorage 的
  /// `volume` / `muted` 两个键（`src/state/player.tsx:333` / `:338`），Dart 侧
  /// 就是 `AppPrefs` 那两个键，写读全在 `PlayerState`。文件仓里那份是只写不读的
  /// 死字段，已删 —— 留两份真相迟早出现「仓储重建后音量悄悄回 0.7」。
  ///
  /// 顺序与当前曲目同时各写一份到 prefs（[StorageKeys.order] /
  /// [StorageKeys.currentId]）：曲目与顺序以文件仓为权威，prefs 那份是
  /// 「最后一次现场」。既然是现场就必须如实 —— 光标没了（删空 / 停止播放）
  /// 或指向一首已知坏掉的曲目时要把键删掉，只写不删就会在重启后复活一个
  /// 不该再播的 currentId（终审 I4）。光标本身的读回优先级见 [restore]。
  /// 同一条规则在 `PlayerState.flushPersist` 里也有一份，两边必须一致。
  Future<void> persist() async {
    final ids = playlist.tracks.map((t) => t.id).toList();
    await repo.save(
      LibrarySnapshot(
        tracks: playlist.tracks,
        order: ids,
        currentId: playlist.current?.id,
        mode: playlist.mode,
      ),
    );
    await _syncPrefsTrace();
  }

  /// prefs 的两份痕迹（`order` + `currentId`）按当前列表对齐。
  ///
  /// 落库与还原都走这一条：痕迹要么与真相一致，要么就没有 —— 留一份陈旧的
  /// 反序 order 或一个指向已删曲目的 currentId，比不写更容易在「文件仓不可用」
  /// 时把现场读歪（终审 I4）。
  Future<void> _syncPrefsTrace() async {
    await prefs.writeJson(
      StorageKeys.order,
      playlist.tracks.map((t) => t.id).toList(),
    );
    final current = playlist.current;
    if (current == null || current.broken) {
      await prefs.remove(StorageKeys.currentId);
    } else {
      await prefs.writeString(StorageKeys.currentId, current.id);
    }
  }

  /// 列表改动后的统一收尾：先喊装配层（补推播放器视图 / 接着播下一首 / 停播），
  /// 再通知界面。
  ///
  /// 同一帧里界面重建时会同时读到新的列表与新视图，不会出现
  /// 「列表有这首歌、舞台还写着未选择曲目」的中间态。
  void _changed({String? removedId}) {
    onPlaylistChanged?.call(removedId: removedId);
    notifyListeners();
  }

  /// 等一批后台回填收尾用的队列（同一时间只有一个在落库）。
  Future<void> _enrichmentQueue = Future<void>.value();

  /// 一批回填的完成信号（含它那一次落库）；空闲时立即完成。
  ///
  /// 界面不等它 —— 首帧体验那条硬约束在这儿同样成立。但「加完歌马上退出」的
  /// 收尾、以及测试要的确定性（同一个文件仓被两个实例共用时，不让后台那次
  /// 落库踩在别人的写入之后）都该 await 它。
  Future<void> get enrichmentSettled => _enrichmentQueue;

  /// 一批回填完成后的第二次收尾：**再落一次库、再刷一次界面**（终审 C1）。
  ///
  /// 为什么是两次落库：第一次保证「歌加了」这件事立刻落盘（应用马上被杀掉也不丢），
  /// 第二次保证「标签 / 封面 / 时长也补上了」落盘。回填本身改的是内存里的活对象，
  /// 少了这一下，文件仓里存的永远是只有文件名的记录，重启就永久降级。
  ///
  /// 一个批次只落一次（几百首歌不能写几百遍），也**不挡导入返回**：这条链是
  /// 后台跑的，调用方 await `importPaths` 时只等到第一次落库。多条批次排队串行，
  /// 避免两次 persist 交错写文件仓。
  ///
  /// 第 4 轮 I9：批次**什么都没学到**（值为 false：文件全打不开、探针全没结论）
  /// 时直接收工 —— 没有新结论就没有要落盘的东西，再整库重写一遍档案只是每次
  /// 启动白写一次盘，而 R1 想止住的正是这个开销。
  void _flushAfterEnrichment(Future<bool>? enrichment) {
    if (enrichment == null) return;
    _enrichmentQueue = _enrichmentQueue.then((_) async {
      final learned = await enrichment;
      if (!learned) return;
      await persist();
      _changed();
    }).catchError((Object _) {
      // 收尾失败只当这次没落上：下一批照样继续，绝不把异常冒到界面层。
    });
  }

  /// 无 IO 的测试构造（T28 的 PanelHarness 用）：只读列表，不落盘。
  @visibleForTesting
  factory LibraryState.fake(Playlist playlist) {
    const silent = _SilentToasts();
    return LibraryState(
      prefs: AppPrefs.inMemory(),
      repo: LibraryRepository(directory: '.'),
      importer: ImportService(playlist: playlist, toasts: silent),
      toasts: silent,
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchController.dispose();
    super.dispose();
  }
}

/// 测试替身用：吞掉全部提示（fake 构造里不弹任何东西）。
class _SilentToasts implements ToastSink {
  const _SilentToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message) {}
}
