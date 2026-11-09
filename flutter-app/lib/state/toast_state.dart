// lib/state/toast_state.dart
//
// 轻提示状态：对译 src/state/toast.tsx。规则与 vanilla 版一致：
//   - 同屏最多 [kToastMaxVisible] 条，多出来的**排队等位**（不是挤掉最旧的一条）；
//   - 带 key 的提示只保留一条，再来时原地改文案 + 重新计时，不叠一条新的；
//   - 不传 key 的按 `text:<文案>` 去重，连点按钮不会挂出一串一样的弹框。
//
// 计时用真 `Timer`（测试用短时长 + [drainForTest] 推进），全部登记在
// [_timers] 里，[dispose] 时统一取消。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/transport_controller.dart' show ToastSink;

/// 提示类型：只影响宿主的底色（[info] / [success] 同一套，[error] 单独一套）。
enum ToastKind { info, success, error }

/// 一条提示。[id] 在实例内单调递增；同 key 重发时复用 id，不新增条目。
@immutable
class ToastItem {
  const ToastItem({
    required this.id,
    required this.message,
    required this.kind,
    required this.durationMs,
    required this.key,
    required this.createdAt,
  });

  final int id;
  final String message;
  final ToastKind kind;

  /// 停留时长（毫秒）。
  final int durationMs;

  /// 去重键：显式 [ToastState.show] 的 `key`，或 `text:<message>`。
  final String key;

  /// 最后一次「上屏 / 改文案」的时间；同 key 重发会往后拨。
  final DateTime createdAt;

  ToastItem copyWith({
    String? message,
    ToastKind? kind,
    int? durationMs,
    DateTime? createdAt,
  }) => ToastItem(
    id: id,
    message: message ?? this.message,
    kind: kind ?? this.kind,
    durationMs: durationMs ?? this.durationMs,
    key: key,
    createdAt: createdAt ?? this.createdAt,
  );
}

/// 同屏最多几条（再多就挡住控制区了，对齐 `toast.tsx` 的 MAX_VISIBLE）。
const int kToastMaxVisible = 3;

/// 默认停留时长（毫秒，对齐 `toast.tsx` 的 DEFAULT_DURATION）。
const int kToastDefaultDurationMs = 3200;

/// 不传 key 时用的去重前缀；加前缀是为了不和显式 key 撞车。
const String kToastTextKeyPrefix = 'text:';

/// `ToastSink` 的实现：可见列表 + 等待队列 + 每条一个计时器。
///
/// 对外只暴露不可变快照 [items] / [queued]；每次语义变化（新增、替换文案、
/// 到期、手动关闭、补位）都恰好 [notifyListeners] 一次。
class ToastState extends ChangeNotifier implements ToastSink {
  ToastState({int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowMs;

  final List<ToastItem> _visible = <ToastItem>[];
  final List<ToastItem> _queued = <ToastItem>[];
  final Map<int, Timer> _timers = <int, Timer>{};

  int _seq = 0;
  int _lastStampMs = 0;

  /// 正在显示的提示，按上屏顺序。
  List<ToastItem> get items => List<ToastItem>.unmodifiable(_visible);

  /// 等位的提示，按排队顺序。
  List<ToastItem> get queued => List<ToastItem>.unmodifiable(_queued);

  /// 同屏上限。
  int get maxVisible => kToastMaxVisible;

  @override
  void show(
    String message, {
    String key = '',
    int durationMs = kToastDefaultDurationMs,
  }) => _emit(message, _kindOf(message), key: key, durationMs: durationMs);

  @override
  void info(String message) => _emit(message, ToastKind.info);

  /// 失败类提示：固定带 `error:<文案>` 的 key，同一条错误不会叠多行。
  ///
  /// [durationMs] 是 T12 加的可选时长（手动 `.lrc` 链路在原版里传 6000）；
  /// 默认 3200 保住既有调用点。
  @override
  void error(String message, {int durationMs = kToastDefaultDurationMs}) =>
      _emit(message, ToastKind.error, key: 'error:$message', durationMs: durationMs);

  void success(String message) => _emit(message, ToastKind.success);

  /// 手动关闭（宿主里点卡片）。空出一个位子就从队列补一条。
  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    final visibleIndex = _visible.indexWhere((e) => e.id == id);
    final queuedIndex = _queued.indexWhere((e) => e.id == id);
    if (visibleIndex < 0 && queuedIndex < 0) return;
    if (visibleIndex >= 0) {
      _visible.removeAt(visibleIndex);
    } else {
      _queued.removeAt(queuedIndex);
    }
    _promote();
    notifyListeners();
  }

  /// 测试用：立刻让最早的一条到期，跳过等待（并照常从队列补位）。
  @visibleForTesting
  void drainForTest() {
    if (_visible.isEmpty) return;
    _expire(_visible.first.id);
  }

  /// 上屏 / 排队的总入口：所有变化只在这里发生，通知也只在这里发一次。
  void _emit(
    String message,
    ToastKind kind, {
    String key = '',
    int durationMs = kToastDefaultDurationMs,
  }) {
    if (message.isEmpty) return;
    final dedupeKey = key.isEmpty ? '$kToastTextKeyPrefix$message' : key;

    // 已经挂在屏幕上（同 key 或同文案）：换文案 + 重新计时，不新增一条。
    final existing = _visible.indexWhere(
      (e) => e.key == dedupeKey || e.message == message,
    );
    if (existing >= 0) {
      final current = _visible[existing];
      _visible[existing] = current.copyWith(
        message: message,
        kind: kind,
        durationMs: durationMs,
        createdAt: _stamp(),
      );
      _schedule(current.id, durationMs);
      notifyListeners();
      return;
    }

    final item = ToastItem(
      id: ++_seq,
      message: message,
      kind: kind,
      durationMs: durationMs,
      key: dedupeKey,
      createdAt: _stamp(),
    );
    if (_visible.length >= kToastMaxVisible) {
      _queued.add(item);
    } else {
      _visible.add(item);
      _schedule(item.id, durationMs);
    }
    notifyListeners();
  }

  /// 同 key 重发要「重新计时」，[createdAt] 也随之往后拨。
  ///
  /// 取 max(时钟, 上次 + 1)：系统时钟只有毫秒精度，同一毫秒内连发两条时
  /// 也不会出现两个相同的 createdAt（测试可据此刻画「刷没刷新」）。
  DateTime _stamp() {
    final now = _nowMs();
    _lastStampMs = now > _lastStampMs ? now : _lastStampMs + 1;
    return DateTime.fromMillisecondsSinceEpoch(_lastStampMs);
  }

  /// 按文案猜类型：`ToastSink.show` 没有 kind 参数，而原版里「失败 / 不支持 /
  /// 无法 …」这几类调用都传的是 `error`，这里按关键词归到 [ToastKind.error]。
  ToastKind _kindOf(String message) {
    const markers = <String>['失败', '不支持', '无法'];
    return markers.any(message.contains) ? ToastKind.error : ToastKind.info;
  }

  /// 排 / 重排一条计时器。已有同 id 的先取消（重新计时就是走到这里）。
  void _schedule(int id, int durationMs) {
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(Duration(milliseconds: durationMs), () => _expire(id));
  }

  /// 一条到期：移出可见列表、补位、通知一次。
  void _expire(int id) {
    _timers.remove(id)?.cancel();
    final index = _visible.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _visible.removeAt(index);
    _promote();
    notifyListeners();
  }

  /// 有空位就从队列头部补进来（补几条算几条），不负责通知。
  void _promote() {
    while (_visible.length < kToastMaxVisible && _queued.isNotEmpty) {
      final next = _queued.removeAt(0);
      _visible.add(next);
      _schedule(next.id, next.durationMs);
    }
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
