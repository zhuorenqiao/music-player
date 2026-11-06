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
  /// [restoring] 覆盖整个异步加载（首帧就画骨架），结束无论成败都置回 false。
  /// 脏存档绝不外抛：仓储自己会退回空快照，这里再兜一层，启动流程不许因此中断。
  Future<void> restore() async {
    _restoring = true;
    notifyListeners();
    try {
      final snap = await repo.load();
      if (snap.tracks.isEmpty) {
        playlist.clear();
        return;
      }
      final byId = {for (final track in snap.tracks) track.id: track};
      final ordered = [
        for (final id in snap.order)
          if (byId.containsKey(id)) byId[id]!,
      ];
      playlist
        ..replaceAll(ordered)
        ..setMode(snap.mode);
      final savedId = snap.currentId;
      if (savedId != null) playlist.setCurrentById(savedId);
    } catch (_) {
      // 理论上到不了这里（仓储是总函数），留作最后一道闸：启动不许炸
      playlist.clear();
    } finally {
      _restoring = false;
      _changed();
    }
  }

  /// 导入一批文件；有新入列就落库并提示。
  Future<int> importPaths(List<String> paths) async {
    final result = await importer.importPaths(paths);
    if (result.added > 0) {
      toasts.show('已添加 ${result.added} 首', key: 'import');
      await persist();
      _changed();
    }
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
  /// 顺序同时写一份到 prefs（[StorageKeys.order]），与原版一致：文件仓是权威，
  /// prefs 那份给「仓储不可用」的场景留个可读的痕迹。
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
    await prefs.writeJson(StorageKeys.order, ids);
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
