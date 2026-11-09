// lib/state/lyrics_page_controller.dart
//
// 全屏歌词页的开合状态（T18 建、T19 消费）。
//
// 对译 React 版 `src/App.tsx` 里那个 `lyricsPageOpen` 的 setState 家族：
// `:410-421` 的 `onStageClick`（点曲目区任意留白 → `app:open-lyrics-page`）、
// 监听该事件的 effect、以及歌词页自己的关闭按钮与 Esc。React 用
// `useState<boolean>` + 自定义事件把「谁让页面打开」解耦；Dart 侧用一个
// ChangeNotifier 就够 —— 播放卡 `page.open()`、页面本体 `page.close()`，
// 快捷键 / 返回键再调 `toggle()`，三方读同一个 flag。
//
// 为什么要独立成控制器、而不是塞进 LyricsState 或 Stage 自己的 State：
//   * Stage 在窄屏 / 宽屏两档布局里各挂一次，State 会各持一份 flag；
//   * T19 的页面本体与 `app.dart` 的 overlay 槽、以及快捷键层，都需要读写它。
//   * T18 先建（Stage 要用它打开页面），T19 再接页面本体 —— 中间态是
//     「flag 会开、界面上什么都不出现」，这是计划允许的中间态。
import 'package:flutter/foundation.dart';

/// 全屏歌词页的开合开关。
///
/// 三个方法都是**幂等**的：重复 [open] / [close] 不通知、不重建。
/// 界面用 `context.watch<LyricsPageController>()` 读 [isOpen]。
class LyricsPageController extends ChangeNotifier {
  bool _open = false;

  /// 歌词页是否开着。
  bool get isOpen => _open;

  /// 打开歌词页（用户点了播放卡的曲目区）。已经开着时什么都不做。
  void open() => _set(true);

  /// 关闭歌词页（页面自己的关闭按钮 / Esc / 返回键）。
  void close() => _set(false);

  /// 开 ↔ 关翻转（快捷键 T19 用）。
  void toggle() => _set(!_open);

  /// 同值不通知：`notifyListeners` 一次就是一次整页重建，而本控制器的调用点
  /// 里有「点热区」「按 Esc」这类可能重复触发的地方。
  void _set(bool value) {
    if (_open == value) return;
    _open = value;
    notifyListeners();
  }
}
