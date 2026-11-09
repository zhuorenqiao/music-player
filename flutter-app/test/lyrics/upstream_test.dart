import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/upstream.dart';

class FakeClient implements HttpJsonClient {
  FakeClient(this.handler);
  final Future<JsonOutcome> Function(Uri url) handler;
  final List<Uri> calls = [];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) {
    calls.add(url);
    return handler(url);
  }
}

/// 按调用次数依次返回预设结果。
FakeClient sequence(List<JsonOutcome> outcomes) {
  var i = 0;
  return FakeClient(
    (_) async => outcomes[i < outcomes.length ? i++ : outcomes.length - 1],
  );
}

void main() {
  final url = Uri.parse('https://example.test/get?track_name=x');
  UpstreamFailure classify(JsonOutcome o) => classifyOutcome(o, '歌词库');

  group('客户端策略', () {
    test('200 直接返回 JSON，不重试', () async {
      final client = sequence([
        const JsonOk({'ok': true}),
      ]);
      final result = await requestJsonClientPolicy(
        client,
        url,
        timeout: const Duration(seconds: 1),
        classify: classify,
        sleep: (_) async {},
      );
      expect(result, {'ok': true});
      expect(client.calls.length, 1);
    });

    test('404 返回 null、不重试、清掉冷却', () async {
      final now = DateTime(2026, 1, 1);
      final gate = RateLimitGate(now: () => now)..note(60);
      expect(gate.isLimited, isTrue);
      final client = sequence([const JsonStatus(404)]);
      final result = await requestJsonClientPolicy(
        client,
        url,
        timeout: const Duration(seconds: 1),
        classify: classify,
        gate: gate,
        sleep: (_) async {},
      );
      expect(result, isNull);
      expect(client.calls.length, 1);
      expect(gate.isLimited, isFalse);
    });

    test('500 重试一次，仍失败则抛 upstream，且不记冷却', () async {
      final gate = RateLimitGate();
      final slept = <Duration>[];
      final client = sequence([const JsonStatus(500), const JsonStatus(500)]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          gate: gate,
          sleep: (d) async => slept.add(d),
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.upstream,
          ),
        ),
      );
      expect(client.calls.length, 2);
      expect(slept, [const Duration(milliseconds: 700)]);
      expect(gate.isLimited, isFalse);
    });

    test('429 记冷却，并按 Retry-After 退避（上限 6s）', () async {
      final gate = RateLimitGate();
      final slept = <Duration>[];
      final client = sequence([
        const JsonStatus(429, retryAfterSeconds: 3),
        const JsonStatus(429, retryAfterSeconds: 3),
      ]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          gate: gate,
          sleep: (d) async => slept.add(d),
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.rateLimit,
          ),
        ),
      );
      expect(slept, [const Duration(seconds: 3)]);
      expect(gate.isLimited, isTrue);
      // 冷却窗口夹在 [10s, 60s]：3s 的建议值被抬到 10s
      expect(gate.isLimited, isTrue);
    });

    test('Retry-After 超过 6s 时退避截到 6s', () async {
      final slept = <Duration>[];
      final client = sequence([
        const JsonStatus(429, retryAfterSeconds: 120),
        const JsonStatus(429),
      ]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          sleep: (d) async => slept.add(d),
        ),
        throwsA(isA<UpstreamFailure>()),
      );
      expect(slept, [const Duration(seconds: 6)]);
    });

    test('400 不重试（不在可重试集合里）', () async {
      final client = sequence([const JsonStatus(400), const JsonOk(null)]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          sleep: (_) async {},
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.upstream,
          ),
        ),
      );
      expect(client.calls.length, 1);
    });

    test('超时重试后抛 timeout', () async {
      final client = sequence([const JsonTimeout(), const JsonTimeout()]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          sleep: (_) async {},
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.timeout,
          ),
        ),
      );
      expect(client.calls.length, 2);
    });

    test('网络错误重试后抛 unreachable', () async {
      final client = sequence([const JsonNetwork(), const JsonNetwork()]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          sleep: (_) async {},
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.unreachable,
          ),
        ),
      );
    });

    test('取消后抛 RequestAborted，不再发第二次', () async {
      final token = CancelToken();
      final client = FakeClient((_) async {
        token.cancel();
        return const JsonTimeout();
      });
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          classify: classify,
          cancel: token,
          sleep: (_) async {},
        ),
        throwsA(isA<RequestAborted>()),
      );
      expect(client.calls.length, 1);
    });

    test('attempts: 1 时只请求一次', () async {
      final client = sequence([const JsonStatus(503)]);
      await expectLater(
        requestJsonClientPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          attempts: 1,
          classify: classify,
          sleep: (_) async {},
        ),
        throwsA(isA<UpstreamFailure>()),
      );
      expect(client.calls.length, 1);
    });
  });

  group('代理策略（译文用）', () {
    test('500 直接抛，不重试', () async {
      final client = sequence([const JsonStatus(500), const JsonOk(null)]);
      await expectLater(
        requestJsonProxyPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          attempts: 2,
          classify: (o) => classifyOutcome(o, '译文库'),
          sleep: (_) async {},
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.upstream,
          ),
        ),
      );
      expect(client.calls.length, 1);
    });

    test('429 直接抛，不重试', () async {
      final client = sequence([const JsonStatus(429), const JsonOk(null)]);
      await expectLater(
        requestJsonProxyPolicy(
          client,
          url,
          timeout: const Duration(seconds: 1),
          attempts: 2,
          classify: (o) => classifyOutcome(o, '译文库'),
          sleep: (_) async {},
        ),
        throwsA(
          isA<UpstreamFailure>().having(
            (f) => f.reason,
            'reason',
            UpstreamReason.rateLimit,
          ),
        ),
      );
      expect(client.calls.length, 1);
    });

    test('超时按 400ms 固定退避重试', () async {
      final slept = <Duration>[];
      final client = sequence([
        const JsonTimeout(),
        const JsonOk({'x': 1}),
      ]);
      final result = await requestJsonProxyPolicy(
        client,
        url,
        timeout: const Duration(seconds: 1),
        attempts: 2,
        classify: (o) => classifyOutcome(o, '译文库'),
        sleep: (d) async => slept.add(d),
      );
      expect(result, {'x': 1});
      expect(slept, [const Duration(milliseconds: 400)]);
    });

    test('JSON 解析失败算 unreachable，会被重试', () async {
      final client = sequence([const JsonBadPayload(), const JsonOk(null)]);
      final result = await requestJsonProxyPolicy(
        client,
        url,
        timeout: const Duration(seconds: 1),
        attempts: 2,
        classify: (o) => classifyOutcome(o, '译文库'),
        sleep: (_) async {},
      );
      expect(result, isNull);
      expect(client.calls.length, 2);
    });
  });

  group('classifyOutcome', () {
    test('四类消息逐字', () {
      expect(
        classifyOutcome(const JsonTimeout(), '歌词库').message,
        '连接歌词库超时（本机到该站点较慢，稍等会自动重试）',
      );
      expect(
        classifyOutcome(const JsonNetwork(), '歌词库').message,
        '连不上歌词库，请检查网络或代理设置',
      );
      expect(
        classifyOutcome(const JsonStatus(429), '歌词库').message,
        '歌词库正在限流（HTTP 429）',
      );
      expect(
        classifyOutcome(const JsonStatus(500), '歌词库').message,
        '服务暂时不可用（HTTP 500）',
      );
      expect(
        classifyOutcome(const JsonStatus(400), '歌词库').message,
        '返回异常（HTTP 400）',
      );
      expect(
        classifyOutcome(const JsonStatus(429), '译文库').message,
        '译文库正在限流（HTTP 429）',
      );
    });

    test('503 也是 rate-limit', () {
      expect(
        classifyOutcome(const JsonStatus(503), '歌词库').reason,
        UpstreamReason.rateLimit,
      );
    });
  });

  group('worstFailure', () {
    test('优先级 rate-limit > timeout > unreachable > upstream', () {
      final list = [
        const UpstreamFailure(UpstreamReason.upstream, 'u'),
        const UpstreamFailure(UpstreamReason.unreachable, 'n'),
        const UpstreamFailure(UpstreamReason.timeout, 't'),
        const UpstreamFailure(UpstreamReason.rateLimit, 'r'),
      ];
      expect(worstFailure(list).reason, UpstreamReason.rateLimit);
      expect(worstFailure(list.sublist(0, 3)).reason, UpstreamReason.timeout);
      expect(
        worstFailure(list.sublist(0, 2)).reason,
        UpstreamReason.unreachable,
      );
      expect(worstFailure(list.sublist(0, 1)).reason, UpstreamReason.upstream);
    });

    test('同级取数组里第一个', () {
      final list = [
        const UpstreamFailure(UpstreamReason.timeout, 'first'),
        const UpstreamFailure(UpstreamReason.timeout, 'second'),
      ];
      expect(worstFailure(list).message, 'first');
    });
  });

  group('RateLimitGate', () {
    test('无建议值 60s，建议值抬到至少 10s、截到至多 60s', () {
      var now = DateTime(2026, 1, 1);
      final gate = RateLimitGate(now: () => now);
      gate.note(0);
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(gate.isLimited, isFalse);

      now = DateTime(2026, 1, 1);
      gate.note(3); // 3s → 抬到 10s
      now = now.add(const Duration(seconds: 9));
      expect(gate.isLimited, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(gate.isLimited, isFalse);
    });

    test('clear 立刻解除', () {
      final gate = RateLimitGate()..note(60);
      gate.clear();
      expect(gate.isLimited, isFalse);
    });
  });

  group('reasonId', () {
    test('四个字符串固定', () {
      expect(reasonId(UpstreamReason.rateLimit), 'rate-limit');
      expect(reasonId(UpstreamReason.timeout), 'timeout');
      expect(reasonId(UpstreamReason.unreachable), 'unreachable');
      expect(reasonId(UpstreamReason.upstream), 'upstream');
    });
  });
}
