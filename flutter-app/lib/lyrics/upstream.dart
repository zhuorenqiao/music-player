// lib/lyrics/upstream.dart
//
// 上游 JSON 底座：直连，无代理。React 版的 Vite 中间件（src/server/music-api.ts）
// 不移植，所以两侧策略都由 Dart 自己实现，共用一套 JsonOutcome / 分类器 / 取消语义：
// * 客户端策略 requestJsonClientPolicy —— 对译 src/lib/lyrics-source.js:283-368
//   （requestJson + requestJsonRetry）与冷却闸 noteRateLimit/clearRateLimit（58-77）；
// * 代理策略 requestJsonProxyPolicy —— 对译 src/server/music-api.ts:106-139
//   （fetchJson + fetchJsonWithRetry），译文（网易云）链路逐字照抄这一侧。
// 两种策略放一个文件：它们是同一问题的两半，拆开会让两边各写一份分类器。
// 纯 Dart + package:http，无 Flutter 依赖；IO 经 HttpJsonClient 接缝注入，便于测试。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/upstream_test.dart）：
// * 客户端退避 index == 0 ? 700 : 1800：1800 那一支在当前 attempts（≤2）下不可达，
//   但照原版写出，将来调大 attempts 行为才对得上（不简化成常量 700）；
// * Retry-After 只认秒数：double.tryParse 有限且 >0 才用，HTTP-date → null → 0，上限 6s；
// * 404 与成功同一支：清冷却、返回 null，不重试也不算错误；
// * 只有 429 / 503 记冷却，500/502/504/超时/网络都不记；冷却窗口夹在 [10s, 60s]，
//   无建议值时 60s，且 retryAfterSeconds > 0 判的是秒不是毫秒；
// * 代理侧 JSON 解析失败等价 unreachable（会被重试），HTTP 错误一律 upstream（不重试），
//   只有 429/503 是 rate-limit；代理只重试 timeout/unreachable，固定 400ms，不读 Retry-After。
import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:http/http.dart' as http;

/// 值得重试的 HTTP 状态（lyrics-source.js:42）。
const _retryableStatus = <int>{429, 500, 502, 503, 504};

/// 单次退避上限（毫秒），避免被异常大的 Retry-After 卡死（lyrics-source.js:45）。
const _maxRetryAfterMs = 6000;

/// 冷却窗口下限 / 上限（毫秒）（lyrics-source.js:48,60）。
const _cooldownMinMs = 10000;
const _cooldownMaxMs = 60000;

/// 两条链路共用的上游请求头（music-api.ts:62-65）：不带 Referer / Cookie / 浏览器 UA。
const _upstreamHeaders = <String, String>{
  'Accept': 'application/json',
  'User-Agent': 'light-music-react/1.0 (+vite dev middleware)',
};

/// 四类失败原因。直连实现永不产出 React 的 unavailable 档，故枚举里没有它。
enum UpstreamReason { rateLimit, timeout, unreachable, upstream }

/// 固定的 reason 字符串（与 React 的 UpstreamReason 字面量逐字对齐）。
String reasonId(UpstreamReason reason) => switch (reason) {
  UpstreamReason.rateLimit => 'rate-limit',
  UpstreamReason.timeout => 'timeout',
  UpstreamReason.unreachable => 'unreachable',
  UpstreamReason.upstream => 'upstream',
};

/// 上游失败的统一表示：reason 给调用方决定措辞，message 是给人看的中文。
class UpstreamFailure implements Exception {
  const UpstreamFailure(
    this.reason,
    this.message, {
    this.retryAfterSeconds = 0,
  });

  final UpstreamReason reason;
  final String message;
  final double retryAfterSeconds;
}

/// 外部主动取消：原样抛出，让上层静默丢弃（对译 requestJson 的 signal.aborted 分支）。
class RequestAborted implements Exception {
  const RequestAborted();
}

/// 一次 getJson 的结果。成功 / 状态码 / 超时 / 网络 / 坏 payload 五态，
/// 让两套策略与分类器共用同一套词汇，而不各自 catch 异常。
sealed class JsonOutcome {
  const JsonOutcome();
}

class JsonOk extends JsonOutcome {
  const JsonOk(this.json);
  final Object? json;
}

class JsonStatus extends JsonOutcome {
  const JsonStatus(this.status, {this.retryAfterSeconds = 0});
  final int status;
  final double retryAfterSeconds;
}

class JsonTimeout extends JsonOutcome {
  const JsonTimeout();
}

class JsonNetwork extends JsonOutcome {
  const JsonNetwork();
}

class JsonBadPayload extends JsonOutcome {
  const JsonBadPayload();
}

/// 只发 GET、把响应归一成 JsonOutcome 的接缝；测试用假实现注入，不碰真网络。
abstract class HttpJsonClient {
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  });
}

/// 生产实现：package:http 直连，单程 timeout 到点归 JsonTimeout，其它异常归 JsonNetwork。
class HttpJsonClientImpl implements HttpJsonClient {
  // `http.Client()` 在构造时就会开一个真 HttpClient。组合根装配（T15）在
  // `buildBootstrap` 里建它，而 testWidgets 跑在 TestWidgetsFlutterBinding 下：
  // 哪怕一整个测试都注入了假 matcher / fetcher、根本不会发请求，光是构造就
  // 会触发「provide your own HttpClient implementation」警告，并让框架把所有
  // 请求统一回 400。所以把真实内核**懒建到第一次 getJson**：生产行为不变
  //（第一次请求照样开），启动装配与测试则一个 socket 都不碰。
  HttpJsonClientImpl({http.Client? inner}) : _explicitInner = inner;

  final http.Client? _explicitInner;
  http.Client? _lazyInner;

  http.Client get _inner => _explicitInner ?? (_lazyInner ??= http.Client());

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    try {
      final response = await _inner.get(url, headers: headers).timeout(timeout);
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        return JsonStatus(
          status,
          retryAfterSeconds: _retryAfterSeconds(
            response.headers['retry-after'],
          ),
        );
      }
      try {
        return JsonOk(jsonDecode(utf8.decode(response.bodyBytes)));
      } catch (_) {
        return const JsonBadPayload();
      }
    } on TimeoutException {
      return const JsonTimeout();
    } catch (_) {
      return const JsonNetwork();
    }
  }
}

/// Retry-After 只认秒数：有限且 >0 才用，HTTP-date / 空 / 非正一律 0（lyrics-source.js:307-312）。
double _retryAfterSeconds(String? raw) {
  final n = double.tryParse(raw?.trim() ?? '');
  return n != null && n.isFinite && n > 0 ? n : 0;
}

Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

/// 限流冷却闸（lyrics-source.js:50-77）。now 可注入，便于测试推进时钟。
class RateLimitGate {
  RateLimitGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _limitedUntil;

  bool get isLimited {
    final until = _limitedUntil;
    return until != null && _now().isBefore(until);
  }

  /// 记一次冷却：base = 秒 >0 ? 秒*1000 : 60s，再夹到 [10s, 60s]。
  void note(double retryAfterSeconds) {
    final baseMs = retryAfterSeconds > 0
        ? retryAfterSeconds * 1000
        : _cooldownMaxMs;
    final clampedMs = baseMs.clamp(_cooldownMinMs, _cooldownMaxMs).round();
    _limitedUntil = _now().add(Duration(milliseconds: clampedMs));
  }

  void clear() {
    _limitedUntil = null;
  }
}

/// 取消令牌：每轮请求开头查一次，已取消就抛 RequestAborted、不再发下一次。
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

/// 多路都失败时挑最能说明问题的一条（music-api.ts:97-100）。
///
/// 优先级 rate-limit(0) < timeout(1) < unreachable(2) < upstream(3)；同级取数组里
/// 第一个 —— 原版用稳定排序后取 [0]，这里用严格 < 保住首条。
UpstreamFailure worstFailure(List<UpstreamFailure> failures) {
  const order = <UpstreamReason, int>{
    UpstreamReason.rateLimit: 0,
    UpstreamReason.timeout: 1,
    UpstreamReason.unreachable: 2,
    UpstreamReason.upstream: 3,
  };
  var best = failures.first;
  for (final failure in failures.skip(1)) {
    if (order[failure.reason]! < order[best.reason]!) {
      best = failure;
    }
  }
  return best;
}

/// 统一分类器：消息里的「歌词库 / 译文库」由 [sourceLabel] 决定，括号用全角。
UpstreamFailure classifyOutcome(JsonOutcome outcome, String sourceLabel) {
  switch (outcome) {
    case JsonTimeout():
      return UpstreamFailure(
        UpstreamReason.timeout,
        '连接$sourceLabel超时（本机到该站点较慢，稍等会自动重试）',
      );
    case JsonNetwork():
    case JsonBadPayload():
      return UpstreamFailure(
        UpstreamReason.unreachable,
        '连不上$sourceLabel，请检查网络或代理设置',
      );
    case JsonStatus(:final status, :final retryAfterSeconds):
      if (status == 429 || status == 503) {
        return UpstreamFailure(
          UpstreamReason.rateLimit,
          '$sourceLabel正在限流（HTTP $status）',
          retryAfterSeconds: retryAfterSeconds,
        );
      }
      return UpstreamFailure(
        UpstreamReason.upstream,
        '${status >= 500 ? '服务暂时不可用' : '返回异常'}（HTTP $status）',
      );
    case JsonOk():
      throw StateError('classifyOutcome 不该收到成功结果 JsonOk');
  }
}

/// spec §11 客户端策略：可重试 {429,500,502,503,504}，700ms 或 Retry-After（≤6s），
/// 429/503 记冷却，404 清冷却并返回 null。
Future<Object?> requestJsonClientPolicy(
  HttpJsonClient client,
  Uri url, {
  required Duration timeout,
  int attempts = 2,
  required UpstreamFailure Function(JsonOutcome) classify,
  RateLimitGate? gate,
  CancelToken? cancel,
  Future<void> Function(Duration)? sleep,
}) async {
  final doSleep = sleep ?? _defaultSleep;
  JsonOutcome? lastOutcome;
  for (var index = 0; index < attempts; index += 1) {
    if (cancel?.isCancelled ?? false) {
      throw const RequestAborted();
    }
    final outcome = await client.getJson(
      url,
      timeout: timeout,
      headers: _upstreamHeaders,
    );
    lastOutcome = outcome;
    if (outcome is JsonOk) {
      gate?.clear();
      return outcome.json;
    }
    // 404 与成功同一支：清冷却、返回 null（不重试、不算错误）。
    if (outcome is JsonStatus && outcome.status == 404) {
      gate?.clear();
      return null;
    }
    final retryable = outcome is JsonStatus
        ? _retryableStatus.contains(outcome.status)
        : true; // 超时 / 网络 / 坏 payload 都可重试
    if (!retryable) {
      throw classify(outcome);
    }
    // 只有 429 / 503 记冷却；500/502/504 与超时 / 网络都不记。
    if (outcome is JsonStatus &&
        (outcome.status == 429 || outcome.status == 503)) {
      gate?.note(outcome.retryAfterSeconds);
    }
    if (index < attempts - 1) {
      final retryAfterSeconds = outcome is JsonStatus
          ? outcome.retryAfterSeconds
          : 0.0;
      // 1800ms 那一支当前 attempts（≤2）走不到，但照原版写出，调大 attempts 才对得上。
      final waitMs = retryAfterSeconds > 0
          ? min(_maxRetryAfterMs, retryAfterSeconds * 1000).round()
          : (index == 0 ? 700 : 1800);
      await doSleep(Duration(milliseconds: waitMs));
    }
  }
  throw classify(lastOutcome ?? const JsonNetwork());
}

/// React 代理策略：只重试 timeout / unreachable，固定 400ms，404 → null。
Future<Object?> requestJsonProxyPolicy(
  HttpJsonClient client,
  Uri url, {
  required Duration timeout,
  int attempts = 1,
  required UpstreamFailure Function(JsonOutcome) classify,
  CancelToken? cancel,
  Future<void> Function(Duration)? sleep,
}) async {
  final doSleep = sleep ?? _defaultSleep;
  JsonOutcome? lastOutcome;
  for (var index = 0; index < attempts; index += 1) {
    if (cancel?.isCancelled ?? false) {
      throw const RequestAborted();
    }
    final outcome = await client.getJson(
      url,
      timeout: timeout,
      headers: _upstreamHeaders,
    );
    lastOutcome = outcome;
    if (outcome is JsonOk) {
      return outcome.json;
    }
    if (outcome is JsonStatus && outcome.status == 404) {
      return null;
    }
    final failure = classify(outcome);
    // 限流与上游错误直接抛，不重试（music-api.ts:130）；只有 timeout/unreachable 才退避重发。
    if (failure.reason == UpstreamReason.rateLimit ||
        failure.reason == UpstreamReason.upstream) {
      throw failure;
    }
    if (index < attempts - 1) {
      await doSleep(const Duration(milliseconds: 400));
    }
  }
  throw classify(lastOutcome ?? const JsonNetwork());
}
