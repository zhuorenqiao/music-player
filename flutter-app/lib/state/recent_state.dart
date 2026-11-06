// lib/state/recent_state.dart
//
// 「最近播放」的界面状态：只是 [RecentStore] 的薄包装。
// 排序、去重、截断、落盘全在 store 里（T16），这里只负责在语义变化后
// 通知一次订阅者，让面板重画。
//
// 通知只有一条来源：[RecentStore] 的变化回调（终审 C2）。记账的入口在
// `TransportController._recordIfAudible`，它不经过任何状态层，包装层自己
// 「在 refresh/clear 里 notifyListeners」永远漏掉它 —— 原版是 recent 状态
// 一变即重绘，这里靠回调把两侧接上，并在 [dispose] 干净解开。
import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../library/recent_store.dart';

/// 最近播放状态。
class RecentState extends ChangeNotifier {
  RecentState(this.store) {
    store.addChangeListener(_onStoreChanged);
  }

  final RecentStore store;

  bool _disposed = false;

  /// 不可变快照（最新在前）。
  List<RecentEntry> get entries => store.entries;

  /// 冷启动读档（委托 [RecentStore.restore]）。
  ///
  /// 读档本身不产生界面可见的变化（条目在首帧之前就位），所以这里不通知；
  /// 启动流程紧接着的 [refresh] 才负责把「已失效」标记刷给界面。
  Future<void> restore() => store.restore();

  /// 播放列表变化后校正失效标记（不在 [playlistIds] 里的显示为「已失效」）。
  ///
  /// 通知由 store 的回调发出，这里不再补一次 `notifyListeners`（否则同一次
  /// 变化重绘两遍）。
  Future<void> refresh(Set<String> playlistIds) =>
      store.markInPlaylist(playlistIds);

  /// 清空历史：同样只靠 store 回调通知（面板的「清空历史」按钮走这条）。
  Future<void> clear() => store.clear();

  void _onStoreChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    // 先解开回调再释放：store 之后被别的调用方改动也不该再喊到这里。
    _disposed = true;
    store.removeChangeListener(_onStoreChanged);
    super.dispose();
  }

  /// 无 IO 的测试构造（T28 的 PanelHarness 用）。
  @visibleForTesting
  RecentState.fake() : store = RecentStore(AppPrefs.inMemory()) {
    store.addChangeListener(_onStoreChanged);
  }
}
