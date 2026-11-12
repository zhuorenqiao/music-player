// test/state/spectrum_state_test.dart
//
// D.3 实时频谱调度层的状态机。用可控的假源，不解码、不碰平台通道。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/track_handle.dart';
import 'package:light_music/state/spectrum_state.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';

/// 最小合法帧表（1 帧 × 64 band + 128 wave）。
SpectrumFrameTable _table() => SpectrumFrameTable(
      sampleRate: 44100,
      frameMs: 50,
      frameCount: 1,
      bands: Uint8List(64)..fillRange(0, 64, 100),
      wave: Int8List(128),
    );

Track _track(String id, {TrackHandle? handle}) => Track(
      id: id,
      src: '/music/$id.flac',
      title: id,
      handle: handle ?? FilePathHandle('/music/$id.flac'),
    );

/// 异步可控的假源：`cached` / `request` 的结果由测试用 Completer 给。
class _FakeSource implements SpectrumSource {
  final List<String> cachedCalls = <String>[];
  final List<String> requestCalls = <String>[];
  final List<Completer<SpectrumFrameTable?>> pending = [];
  SpectrumFrameTable? cachedResult;

  @override
  Future<SpectrumFrameTable?> cached(String trackKey, String audioPath) async {
    cachedCalls.add(trackKey);
    return cachedResult;
  }

  @override
  Future<SpectrumFrameTable?> request(
    String trackKey,
    String audioPath, {
    bool prioritize = false,
  }) {
    requestCalls.add(trackKey);
    final c = Completer<SpectrumFrameTable?>();
    pending.add(c);
    return c.future;
  }

  void complete(int index, SpectrumFrameTable? table) =>
      pending[index].complete(table);
}

/// 把异步链路的空转跑完（不排真 Timer）。
Future<void> _flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('懒启动', () {
    test('歌词页没打开：完全不碰解析源', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      await _flush();

      expect(src.cachedCalls, isEmpty);
      expect(src.requestCalls, isEmpty);
      expect(state.frameTable, isNull);
      expect(state.isLoading, isFalse);
    });

    test('打开歌词页才启动；先读缓存，miss 才 request', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();

      expect(src.cachedCalls, ['a']);
      expect(src.requestCalls, ['a']);
      expect(state.isLoading, isTrue);
    });

    test('缓存命中就不入队解码', () async {
      final src = _FakeSource()..cachedResult = _table();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();

      expect(src.cachedCalls, ['a']);
      expect(src.requestCalls, isEmpty);
      expect(state.frameTable, isNotNull);
      expect(state.frameTableFor('a'), same(state.frameTable));
      expect(state.frameTableFor('b'), isNull, reason: '换曲目不串表');
      expect(state.isFallback, isFalse);
    });
  });

  group('到货与降级', () {
    test('request 返回表 → 按曲目 id 可取，且通知一次', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();
      src.complete(0, _table());
      await _flush();

      expect(state.frameTableFor('a'), isNotNull);
      expect(state.isFallback, isFalse);
      expect(state.isLoading, isFalse);
      expect(notifications, 1);
    });

    test('request 返回 null → 显式降级，isFallback 为真', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();
      src.complete(0, null);
      await _flush();

      expect(state.frameTable, isNull);
      expect(state.isFallback, isTrue);
    });

    test('SAF/content:// 句柄：跳过解析，不排队白等', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(
        _track(
          'saf',
          handle: SafUriHandle('content://media/external/audio/42', 'a.flac'),
        ),
      );
      state.setVisible(true);
      await _flush();

      expect(src.cachedCalls, isEmpty);
      expect(src.requestCalls, isEmpty);
      expect(state.isFallback, isTrue);
    });
  });

  group('换曲作废在途结果', () {
    test('旧歌的解码结果回来时已换曲 → 不挂表', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();

      state.setCurrent(_track('b'));
      await _flush();
      expect(src.requestCalls, ['a', 'b']);

      // 旧歌的结果后回来：必须被 generation 挡掉。
      src.complete(0, _table());
      await _flush();
      expect(state.frameTable, isNull, reason: '旧歌的表不能挂到当前状态上');

      // 新歌的结果回来才生效。
      src.complete(1, _table());
      await _flush();
      expect(state.frameTableFor('b'), isNotNull);
      expect(state.frameTableFor('a'), isNull);
    });

    test('关页作废在途结果，重新打开会再走一遍缓存', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();
      state.setVisible(false);
      src.complete(0, _table());
      await _flush();
      expect(state.frameTable, isNull);

      state.setVisible(true);
      await _flush();
      expect(src.cachedCalls, ['a', 'a'], reason: '重新打开要重新判缓存');
    });

    test('换曲时立刻清掉已到货的表（不画上一首的频谱）', () async {
      final src = _FakeSource()..cachedResult = _table();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setCurrent(_track('a'));
      state.setVisible(true);
      await _flush();
      expect(state.frameTableFor('a'), isNotNull);

      state.setCurrent(_track('b'));
      expect(state.frameTableFor('a'), isNull);
      expect(state.frameTable, isNull);
    });
  });

  group('去重', () {
    test('同一首歌的语义快照重复推送不重复入队', () async {
      final src = _FakeSource();
      final state = SpectrumState(source: src);
      addTearDown(state.dispose);

      state.setVisible(true);
      state.setCurrent(_track('a'));
      state.setCurrent(_track('a')); // 同一个 id / 同一份路径
      await _flush();

      expect(src.requestCalls, ['a']);
    });
  });
}
