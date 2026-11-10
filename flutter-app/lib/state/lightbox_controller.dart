// lib/state/lightbox_controller.dart
//
// 封面放大层（灯箱）的开合状态（M2b T9 建、T11 消费）。
//
// 对译 React 版 `src/App.tsx:1486-1503` 的 `lightbox` setState 家族：
// `openLightbox(trigger?)`（曲目区封面 / 歌词页右栏两个入口）、
// `closeLightbox()`（遮罩空白点击 / 关闭按钮 / Esc 三路）。React 用
// `useState<boolean>`；Dart 侧一个 ChangeNotifier 就够 —— 封面热区
// `lightbox.open()`、灯箱本体 `lightbox.close()`，三方读同一个 flag。
//
// 层叠关系（App.tsx:1581-1591）：灯箱叠在歌词页**之上** —— 灯箱开着时
// Esc 只关灯箱；`app.dart` 的 `closeOverlay` 分支按「谁在最上面谁响应」
// 处理，本控制器不感知歌词页。
//
// 为什么独立成控制器、而不是塞进 CoverState：灯箱是纯界面态，与封面
// 数据无关；歌词页（LyricsPageController）同款裁定的直接翻版。
import 'package:flutter/foundation.dart';

/// 封面放大层的开合开关（M2b T9）。
///
/// 仿 [LyricsPageController]：单 bool、幂等 —— 重复 [open] / [close]
/// 不通知、不重建。界面用 `context.watch<LightboxController>()` 读 [isOpen]。
class LightboxController extends ChangeNotifier {
  bool _open = false;

  /// 灯箱是否开着。
  bool get isOpen => _open;

  /// 打开灯箱（用户点了曲目区 / 歌词页右栏的封面）。已经开着时什么都不做。
  void open() => _set(true);

  /// 关闭灯箱（遮罩空白点击 / 关闭按钮 / Esc）。
  void close() => _set(false);

  /// 开 ↔ 关翻转（预留；快捷键层目前只走 [close]）。
  void toggle() => _set(!_open);

  /// 同值不通知：与 [LyricsPageController] 同一条理由 —— 调用点里有
  /// 「连点封面热区」这类可能重复触发的地方。
  void _set(bool value) {
    if (_open == value) return;
    _open = value;
    notifyListeners();
  }
}
