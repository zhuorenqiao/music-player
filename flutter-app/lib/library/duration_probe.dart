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
/// 实现自己负责释放资源（`MediaKitDurationOpener` 内部同样带截止并 stop）。
typedef DurationOpener = Future<double> Function(String source);

/// 排队 + 超时 + 归一：把「一个能开媒体的 opener」变成「导入服务要的探针」。
class DurationProbe {
  DurationProbe(this._open, {int timeoutMs = kDurationProbeTimeoutMs})
    : _timeout = Duration(milliseconds: timeoutMs);

  final DurationOpener _open;
  final Duration _timeout;

  /// 串行队列的尾巴：新任务排在它后面，永远只有一个 `_open` 在飞。
  Future<void> _tail = Future<void>.value();

  /// 同时在飞的最多个数（正常恒为 1）。测试用它钉住「不许雪崩」。
  int get peakConcurrency => _peak;

  int _inFlight = 0;
  int _peak = 0;

  /// 探测一次。可以直接当函数值递给 `ImportService.durationProbe`。
  Future<double> call(String source) {
    // 排到队尾再跑：`_tail` 只在上一个**真正结束**（含清理）之后才 complete，
    // 所以这里能保证一次只开一个媒体。
    final next = _tail.then((_) => _probeOne(source));
    // 队列本身不能被一次失败卡住：留一个永不抛的尾巴给下一个任务排。
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
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
