// test/library/large_folder_import_test.dart
//
// 「添加大文件夹」的回归用例：批量导入不许把回填任务一次性全部放出去。
//
// 故障形状（安卓真机上的崩溃）：选中几百 / 上千首的文件夹后，导入会把每一首
// 的回填任务同时启动 —— 每条都开文件、读最多 8MB 标签区（含内嵌封面），带
// 封面的还要解码成图。几百条并发就足以把移动端内存 / 文件句柄打满，表现为
// 「卡死几秒后 App 被系统杀掉」。修复是给回填加一条实例级闸门（默认 4 条）。
//
// 这里用「假探针的并发峰值」来观察闸门：`_enrich` 一定先读标签、再探时长，
// 而闸门包住的是整条 `_enrichOnce`，所以峰值等于回填并发度本身。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/duration_probe.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/transport_controller.dart' show ToastSink;

class _SilentToasts implements ToastSink {
  const _SilentToasts();

  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}

  @override
  void info(String message) {}

  @override
  void error(String message, {int durationMs = 3200}) {}
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('light-large-import');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void writeTracks(int count) {
    for (var i = 0; i < count; i++) {
      File('${root.path}${Platform.pathSeparator}track-$i.mp3')
          .writeAsStringSync('x');
    }
  }

  test('一次导入 200 首时回填并发不超过闸门上限', () async {
    writeTracks(200);

    var inFlight = 0;
    var peak = 0;
    Future<DurationProbeOutcome> probe(String source) async {
      inFlight += 1;
      if (inFlight > peak) peak = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      inFlight -= 1;
      return const DurationProbeOutcome(1.0);
    }

    final service = ImportService(
      playlist: Playlist(tracks: const []),
      toasts: const _SilentToasts(),
      durationProbe: probe,
    );

    final result = await service.importDirectory(root.path);
    // 入列本身不等回填（文件头第 1 条硬约束），所以这里先拿到 added。
    expect(result.added, 200);
    await result.enrichment;

    expect(peak, kMaxConcurrentEnrichments);
    expect(service.peakEnrichmentConcurrency, kMaxConcurrentEnrichments);
  });

  test('两批先后导入共用同一份额度，不叠加', () async {
    writeTracks(200);
    var inFlight = 0;
    var peak = 0;
    Future<DurationProbeOutcome> probe(String source) async {
      inFlight += 1;
      if (inFlight > peak) peak = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      inFlight -= 1;
      return const DurationProbeOutcome(1.0);
    }

    final service = ImportService(
      playlist: Playlist(tracks: const []),
      toasts: const _SilentToasts(),
      durationProbe: probe,
    );

    final first = await service.importDirectory(root.path);
    // 第一批回填还没收敛就开第二批：闸门是实例级的，两个批次合起来也只许 4 条。
    final second = await service.importDirectory(root.path);
    // 第二批全是重复路径（id 相同），不会新建；这里只关心并发。
    expect(second.added, 0);
    await first.enrichment;
    await second.enrichment;

    expect(peak, kMaxConcurrentEnrichments);
  });
}
