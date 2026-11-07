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

/// 一次探测的结论：**多少秒** + **这个结论是怎么来的**（第 3 轮 C1）。
///
/// 为什么不能只给一个 `double`：从前超时也被归成 NaN，于是调用方拿到
/// 「探不出」这同一个形状，却分不清背后是两种完全不同的事 ——
///   * [timedOut] = 内核在预算内**没来得及回话**（U 盘还没挂上、大 FLAC 首次
///     打开慢、媒体线程排队）。这是暂时的，下次启动该再看一眼；
///   * `seconds` 非有限 / 非正而 `timedOut` 为假 = 文件**确实没有时长可报**
///     （或压根没有这个容器信息）。这是结论，重复探测一万次也是这个结论。
/// 探测标记 `Track.metadataProbed` 只能记给后者：把前者也记上，就是把一次
/// 暂时的失败冻结成永久降级，整条自愈管路再也不看它第二眼（C1 的 Critical
/// 正在这里）。两种情况返回值统统是 NaN，所以必须把「为什么是 NaN」单独带出来。
class DurationProbeOutcome {
  /// 探到的秒数（非有限 / 0 / 负数统统算「这个文件没有时长」）。
  const DurationProbeOutcome(this.seconds) : timedOut = false;

  /// 预算内 opener 没回话：值一定是「未知」，但**原因**是超时。
  const DurationProbeOutcome.timedOut()
    : seconds = double.nan,
      timedOut = true;

  final double seconds;
  final bool timedOut;

  /// 真的探到了一个可用时长。
  bool get isKnown => seconds.isFinite && seconds > 0;
}

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

  /// 探测一次，只要秒数（NaN = 未知）。
  ///
  /// 「关掉之后不再探」这条判定在**入列那一刻**就做（[probeOutcome] 自己），而不是等
  /// 队列真跑到它时才看标记：否则一次 [close] 会把已经排在前面的那一首
  /// 悄悄变成 NaN，而它其实正要被排队等它结果的调用方当作「这一首的时长」。
  ///
  /// 需要分清「超时」与「这个文件真的没有时长」的调用方（`ImportService` 记
  /// 探测标记那条路，第 3 轮 C1）请用 [probeOutcome]。
  Future<double> call(String source) =>
      probeOutcome(source).then((outcome) => outcome.seconds);

  /// 探测一次并带上结论的**来路**（探到 / 探不出 / 被超时掐掉）。
  Future<DurationProbeOutcome> probeOutcome(String source) {
    // 关完之后：未知，但**不是超时**（没有内核可等，谈不上预算）。
    if (_closed) return Future.value(const DurationProbeOutcome(double.nan));
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

  Future<DurationProbeOutcome> _probeOne(String source) async {
    _inFlight += 1;
    if (_inFlight > _peak) _peak = _inFlight;
    try {
      final value = await _open(source).timeout(_timeout);
      // 非有限 / 0 / 负数统统算「没探到」：未知时长必须保持 NaN。
      // 这是**文件的结论**，不是暂时的失败 —— 所以 timedOut 为假。
      if (!value.isFinite || value <= 0) {
        return const DurationProbeOutcome(double.nan);
      }
      return DurationProbeOutcome(value);
    } on TimeoutException {
      // 超时单独归队（第 3 轮 C1）：以前它和下面那条 `catch` 共用一个 NaN，
      // 调用方拿到「探不出」这个形状时分不清该不该再来一次，于是探测标记
      // 要么记早了（永久冻结一次暂时失败）、要么记晚了（每启动重跑整库）。
      return const DurationProbeOutcome.timedOut();
    } catch (_) {
      // 平台异常、opener 自己抛 —— 一律按「未知」处理，绝不冒泡。
      // 注意这里**不算超时**：内核明明白白回了话（「这条不行」），
      // 再来一遍也是同样的答案，所以调用方可以记标记。
      return const DurationProbeOutcome(double.nan);
    } finally {
      _inFlight -= 1;
    }
  }
}
