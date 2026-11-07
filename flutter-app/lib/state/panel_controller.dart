// lib/state/panel_controller.dart
//
// 面板的界面状态：当前选中哪个 tab。
//
// 只放「换个 tab」这一件事 —— 搜索关键词归 [LibraryState]（两个 tab 共用，
// 且过滤值要防抖），列表与最近记录归各自的状态层。T29 的弹层复用同一个面板，
// 也复用这一份选中态（原版里面板在侧栏与弹层中是同一实例）。
import 'package:flutter/foundation.dart';

/// 面板的两个标签页。顺序即界面顺序（播放列表在左，最近在右）。
enum PanelTab { playlist, recent }

/// 面板界面状态。
class PanelController extends ChangeNotifier {
  PanelTab _tab = PanelTab.playlist;

  /// 当前标签页，默认播放列表。
  PanelTab get tab => _tab;

  set tab(PanelTab next) {
    if (_tab == next) return;
    _tab = next;
    notifyListeners();
  }
}
