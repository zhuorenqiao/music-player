// lib/state/recent_state.dart
//
// 「最近播放」的界面状态：只是 [RecentStore] 的薄包装。
// 排序、去重、截断、落盘全在 store 里（T16），这里只负责在语义变化后
// 通知一次订阅者，让面板重画。
import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../library/recent_store.dart';

/// 最近播放状态。
class RecentState extends ChangeNotifier {
  RecentState(this.store);

  final RecentStore store;

  /// 不可变快照（最新在前）。
  List<RecentEntry> get entries => store.entries;

  /// 冷启动读档（委托 [RecentStore.restore]）。
  ///
  /// 读档本身不产生界面可见的变化（条目在首帧之前就位），所以这里不通知；
  /// 启动流程紧接着的 [refresh] 才负责把「已失效」标记刷给界面。
  Future<void> restore() => store.restore();

  /// 播放列表变化后校正失效标记（不在 [playlistIds] 里的显示为「已失效」）。
  Future<void> refresh(Set<String> playlistIds) async {
    await store.markInPlaylist(playlistIds);
    notifyListeners();
  }

  Future<void> clear() async {
    await store.clear();
    notifyListeners();
  }

  /// 无 IO 的测试构造（T28 的 PanelHarness 用）。
  @visibleForTesting
  RecentState.fake() : store = RecentStore(AppPrefs.inMemory());
}
