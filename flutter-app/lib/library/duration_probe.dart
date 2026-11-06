// lib/library/duration_probe.dart
//
// 时长探测的纯逻辑接缝（终审 I1）。
//
// 为什么单独成一个文件：`ImportService.durationProbe` 要的只是一句
// 「这个来源能播出多长」，而真正能干这件事的是原生内核（media_kit）。把
// 「怎么排队、超时多少、失败怎么收场」抽成纯逻辑放在这里，media_kit 那份
// 就只剩一个薄适配器（`MediaKitDurationOpener`），`flutter test` 因此能覆盖
// 到全部失败分支 —— 原生库在测试环境里根本起不来，不可测的部分越少越好。
//
// 三条硬约束（对齐原版 `src/state/duration.ts`）：
//   1. **超时上限 3000ms**（`DURATION_PROBE_TIMEOUT`）：探不到就是探不到，
//      绝不许把导入或回填扣在那里；
//   2. **绝不抛**：抛出去会顺着 `Future.wait` 把整批回填的落库收尾一起带走；
//      失败一律是 NaN（「未知时长」），不是 0；
//   3. **串行，一次只开一首**：原版注释就写了「几十个 Audio 元素同时解码会抢
//      媒体线程，反而更慢」，这里同理 —— 十几个 `Player` 同时 open 只会把解码
//      与文件句柄打满。
import 'dart:async';

/// 时长探测的超时预算：与原版 `constants.ts` 的 `DURATION_PROBE_TIMEOUT` 同值。
const int kDurationProbeTimeoutMs = 3000;

/// 探一个来源的时长（秒）。
///
/// 契约：在调用方给的预算之内返回；探不到返回任意非有限值 / 非正数。
/// 单次调用自己负责收尾（`MediaKitDurationOpener` 内部带截止并 `stop`），
/// 但**不**负责释放内核本身 —— 那台懒建的 `Player` 归 [DurationProbe.close]
/// 经 `closeOpener` 关（终审 A2）。
typedef DurationOpener = Future<double> Function(String source);

/// 排队 + 超时 + 归一：把「一个能开媒体的 opener」变成「导入服务要的探针」。
///
/// [close] 是它持有原生资源的唯一释放点（终审 A2）：`MediaKitDurationOpener`
/// 里那台懒建的 `Player` 从前从不 `dispose()`，装配层也没地方能关掉它。现在
/// opener 的释放函数由构造时交进来（`closeOpener`），`AppBootstrap.dispose()`
/// 调 [close]，退出时原生内核就有了明确的归宿。
class DurationProbe {
  DurationProbe(
    this._open, {
    int timeoutMs = kDurationProbeTimeoutMs,
    this.closeOpener,
  }) : _timeout = Duration(milliseconds: timeoutMs);

  final DurationOpener _open;
  final Duration _timeout;

  /// opener 的释放函数（null = 这个探针背后没有原生资源，比如测试里的假 opener）。
  final Future<void> Function()? closeOpener;

  /// 串行队列的尾巴：新任务排在它后面，永远只有一个 `_open` 在飞。
  Future<void> _tail = Future<void>.value();

  bool _closed = false;

  /// 是否已经关掉（关完之后每次探测都直接给 NaN，不再碰原生内核）。
  bool get isClosed => _closed;

  /// 同时在飞的最多个数（正常恒为 1）。测试用它钉住「不许雪崩」。
  int get peakConcurrency => _peak;

  int _inFlight = 0;
  int _peak = 0;

  /// 探测一次。可以直接当函数值递给 `ImportService.durationProbe`。
  ///
  /// 「关掉之后不再探」这条判定在**入列那一刻**就做（[call] 自己），而不是等
  /// 队列真跑到它时才看标记：否则一次 [close] 会把已经排在前面的那一首
  /// 悄悄变成 NaN，而它其实正要被排队等它结果的调用方当作「这一首的时长」。
  Future<double> call(String source) {
    if (_closed) return Future<double>.value(double.nan);
    // 排到队尾再跑：`_tail` 只在上一个**真正结束**（含清理）之后才 complete，
    // 所以这里能保证一次只开一个媒体。
    final next = _tail.then((_) => _probeOne(source));
    // 队列本身不能被一次失败卡住：留一个永不抛的尾巴给下一个任务排。
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// 释放底层内核：先排在队列尾部（让已入队的探测连它自己的 `stop` 一起跑完），
  /// 再调 opener 的释放函数。幂等，且绝不抛 —— 退出收尾不该被原生异常打断。
  Future<void> close() => _closing ??= _closeNow();
  Future<void>? _closing;

  Future<void> _closeNow() async {
    _closed = true;
    // 先排空：close 之前已经入队的探测照常跑完（它们各自带超时与清理），
    // 否则「关掉正在被使用的 Player」会变成一堆半截的探测。
    await _tail.catchError((Object _) {});
    try {
      await closeOpener?.call();
    } catch (_) {
      // opener 自己释放失败（原生库已经没了）没有可操作的东西
    }
  }

  Future<double> _probeOne(String source) async {
    _inFlight += 1;
    if (_inFlight > _peak) _peak = _inFlight;
    try {
      final value = await _open(source).timeout(_timeout);
      // 非有限 / 0 / 负数统统算「没探到」：未知时长必须保持 NaN。
      if (!value.isFinite || value <= 0) return double.nan;
      return value;
    } catch (_) {
      // 超时、平台异常、opener 自己抛 —— 一律按「未知」处理，绝不冒泡。
      return double.nan;
    } finally {
      _inFlight -= 1;
    }
  }
}
