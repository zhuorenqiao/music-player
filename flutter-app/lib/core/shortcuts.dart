// lib/core/shortcuts.dart
//
// 桌面快捷键层：对译 `src/App.tsx:1582-1655` 的键盘 effect 与 README
// 「快捷键」表（空格播放/暂停、←→ 快退/快进 5 秒、↑↓ 音量 ±5%、M 静音、
// N 下一首、P 上一首 —— 后两个是终审 I5 补上的漏移植，原版在
// `src/App.tsx:1639-1645`）。
//
// 三层各管一件事，跟原版的分工一一对应：
//   1. [kLightMusicShortcuts] = 那张 switch 的「哪个键 → 哪个动作」；
//   2. [AppShortcuts] 里的 `Actions` = switch 体，动作在这里变成回调；
//   3. `Focus` 宿主 = 「document 上挂监听」的那一层：页面里没有任何控件抢到
//      焦点时，按键也得有人接，否则首帧之后按空格什么都不会发生。
//
// 原版三条「让位」规则的落地方式（都在 test/core/shortcuts_test.dart 里有用例）：
//   - **输入框聚焦时整套不触发**（`tag === 'INPUT' || 'TEXTAREA' || 'SELECT'`）：
//     用 `Action.isActionEnabled` 表达，而不是在 `onKeyEvent` 里抢着 return
//     `handled`。Flutter 的按键是从焦点节点**自下而上**传的，输入框自己先吃；
//     它没吃掉的才到这里，此时把 Action 关掉，`Shortcuts` 就返回 ignored ——
//     按键继续往上传给 app 层的文本编辑快捷键，打字与光标一个都不受影响。
//   - **滑块聚焦时方向键不双触发**（`isRange` 分支）：同样不用在这里判 ——
//     `Slider` 自己带了方向键处理，它在焦点链的更下游，先把手事件吃掉，
//     这一层根本收不到，自然不可能「滑一格 + 音量再 ±5%」。
//   - **空格不滚页面**：原版的 `event.preventDefault()` 在 Flutter 里等价于
//     「这一层把事件标成 handled」。`kLightMusicShortcuts` 里 Space 映射到
//     Intent 并被启用的 Action 消费，app 层的 `Space → ActivateIntent`（窄屏
//     档还会滚动一屏）就再也看不到这一下。
//
// 两件事**不在**这里做，别顺手加：
//   - `Play/Pause`、`NextTrack`、`PrevTrack` 这些媒体键由系统媒体会话进来
//     （T21/T22 的 `MediaSessionBridge` → `MediaSessionCoordinator`），键盘层
//     再注册一遍就是两个入口抢同一首歌；
//   - `L`（歌词页开关）与 `Escape`（关歌词页 / 关弹层）属歌词页，M2 落地时由
//     那一页自己注册；现在写进这张表只会让 M1 按 Esc 什么都不做还占住键位。
//   - 原版还有「列表弹层 / 放大层开着时只认 Esc」那条总闸：M1 只有底部弹层，
//     它自带模态焦点域（`showModalBottomSheet` 的 barrier 把按键挡在外面），
//     M2 的放大层再补这道闸。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 一次快退/快进的秒数（README：`←` / `→` = 5 秒）。
const double kSeekStep = 5;

/// 一次音量调整的幅度（README：`↑` / `↓` = 5%）。
const double kVolumeStep = 0.05;

/// 快捷键的动作名：[AppShortcuts] 往外报、界面层往 [PlayerState] 派。
///
/// 只有这六个字符串（`togglePlay` / `seekBy` / `volumeBy` / `toggleMute` /
/// `playNext` / `playPrev`），界面层的 switch 与测试的断言共用它们，
/// 别再新增第七个。
typedef ShortcutCallback = void Function(String name, [Object? arg]);

/// 播放 / 暂停。
class TogglePlayIntent extends Intent {
  const TogglePlayIntent();
}

/// 相对当前进度跳 [delta] 秒（正数快进，负数快退）。
class SeekByIntent extends Intent {
  const SeekByIntent(this.delta);

  final double delta;
}

/// 相对当前音量加 [delta]（0~1 的小数，正数变响）。
class VolumeByIntent extends Intent {
  const VolumeByIntent(this.delta);

  final double delta;
}

/// 静音 / 取消静音。
class ToggleMuteIntent extends Intent {
  const ToggleMuteIntent();
}

/// 下一首（终审 I5，原版 `case 'KeyN': playNext()`）。
class PlayNextIntent extends Intent {
  const PlayNextIntent();
}

/// 上一首（终审 I5，原版 `case 'KeyP': playPrev()`）。
class PlayPrevIntent extends Intent {
  const PlayPrevIntent();
}

const Map<ShortcutActivator, Intent> _kLightMusicShortcutMap =
    <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.space): TogglePlayIntent(),
      SingleActivator(LogicalKeyboardKey.arrowLeft): SeekByIntent(-kSeekStep),
      SingleActivator(LogicalKeyboardKey.arrowRight): SeekByIntent(kSeekStep),
      SingleActivator(LogicalKeyboardKey.arrowUp): VolumeByIntent(kVolumeStep),
      SingleActivator(LogicalKeyboardKey.arrowDown): VolumeByIntent(-kVolumeStep),
      SingleActivator(LogicalKeyboardKey.keyM): ToggleMuteIntent(),
      // N / P：与 M 不冲突，也不与系统媒体键冲突（上下曲由 MediaSessionBridge 管）。
      SingleActivator(LogicalKeyboardKey.keyN): PlayNextIntent(),
      SingleActivator(LogicalKeyboardKey.keyP): PlayPrevIntent(),
      // L（歌词页）/ Escape（关歌词页）留给 M2，见文件头。
    };

/// 快捷键表：八个键，一组一个动作。
///
/// 表里**刻意没有**修饰键组合：原版第一件事就是 `if (altKey || ctrlKey ||
/// metaKey) return;`，`SingleActivator` 的四个修饰位默认全要求松开，同一件事。
Map<ShortcutActivator, Intent> get kLightMusicShortcuts =>
    _kLightMusicShortcutMap;

/// 焦点是不是落在文本输入上（TextField / EditableText / Dropdown 的搜索框）。
bool _hasTextEditingFocus() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 焦点是不是落在一颗真的能按下的按钮上。
///
/// 对应原版 `case 'Space': if (tag === 'BUTTON' || tag === 'A') return;` ——
/// 焦点在按钮上时空格属于那颗按钮（原生 `ActivateIntent`），不该被快捷键抢走。
/// 空格之外的动作没有这条豁免，与原版一致。
bool _hasButtonFocus() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.findAncestorWidgetOfExactType<InkWell>()?.onTap != null) {
    return true;
  }
  // TextButton / FilledButton（「清空历史」「继续播放」这些）不走 InkWell
  return context.findAncestorWidgetOfExactType<ButtonStyleButton>() != null;
}

/// 一个「触发前再问一次要不要让位」的 Action。
///
/// `isActionEnabled` 为 false 时，`Shortcuts` 不会 invoke、也不会把这一下按键
/// 标成已处理（见 `_ShortcutManager.handleKeypress` 的注释），事件按原路继续
/// 往上传 —— 这正是「让位」该有的效果。
class _LightMusicAction<T extends Intent> extends CallbackAction<T> {
  _LightMusicAction({required super.onInvoke, required this.enabled});

  final bool Function() enabled;

  @override
  bool get isActionEnabled => enabled();
}

/// 把八个键接成回调的宿主层。
///
/// [onAction] 收到的名字是 `togglePlay` / `seekBy` / `volumeBy` / `toggleMute`
/// / `playNext` / `playPrev`，其中 `seekBy`、`volumeBy` 带 `double` 参数
/// （增量，不是绝对值）。界面层负责把它落到播放器上，
/// core 层不认识 [PlayerState]，方向依赖不反过来。
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({
    required this.child,
    required this.onAction,
    super.key,
  });

  final Widget child;
  final ShortcutCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: kLightMusicShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          TogglePlayIntent: _LightMusicAction<TogglePlayIntent>(
            enabled: () => !_hasTextEditingFocus() && !_hasButtonFocus(),
            onInvoke: (TogglePlayIntent intent) {
              onAction('togglePlay');
              return null;
            },
          ),
          SeekByIntent: _LightMusicAction<SeekByIntent>(
            enabled: () => !_hasTextEditingFocus(),
            onInvoke: (SeekByIntent intent) {
              onAction('seekBy', intent.delta);
              return null;
            },
          ),
          VolumeByIntent: _LightMusicAction<VolumeByIntent>(
            enabled: () => !_hasTextEditingFocus(),
            onInvoke: (VolumeByIntent intent) {
              onAction('volumeBy', intent.delta);
              return null;
            },
          ),
          ToggleMuteIntent: _LightMusicAction<ToggleMuteIntent>(
            enabled: () => !_hasTextEditingFocus(),
            onInvoke: (ToggleMuteIntent intent) {
              onAction('toggleMute');
              return null;
            },
          ),
          // N / P 的「输入框让位」不是可选项：面板搜索框里打 n 本该只进文字，
          // 原版靠 INPUT 自己吃掉 keydown，这里靠同一个 `_hasTextEditingFocus`。
          PlayNextIntent: _LightMusicAction<PlayNextIntent>(
            enabled: () => !_hasTextEditingFocus(),
            onInvoke: (PlayNextIntent intent) {
              onAction('playNext');
              return null;
            },
          ),
          PlayPrevIntent: _LightMusicAction<PlayPrevIntent>(
            enabled: () => !_hasTextEditingFocus(),
            onInvoke: (PlayPrevIntent intent) {
              onAction('playPrev');
              return null;
            },
          ),
        },
        // 焦点宿主：页面里没落任何控件焦点时，按键由这里交给上面的 Shortcuts。
        // `skipTraversal` 让它不进 Tab 序列（读屏用户不会 Tab 到一个看不见的节点），
        // `autofocus` 让它只在「确实没人聚焦」时才拿初始焦点。
        child: Focus(
          debugLabel: 'light-music-shortcuts-host',
          autofocus: true,
          skipTraversal: true,
          canRequestFocus: true,
          child: child,
        ),
      ),
    );
  }
}

/// [AppShortcuts] 的函数式写法（计划里给出的对外名字）。
Widget withAppShortcuts({
  required Widget child,
  required ShortcutCallback playerCallback,
}) => AppShortcuts(onAction: playerCallback, child: child);
