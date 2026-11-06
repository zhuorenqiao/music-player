// test/library/import_service_test.dart
//
// 导入流程：校验扩展名 → 立即入列（可播）→ 解析内嵌标签 → 探时长 → 落库钩子。
//
// 断言一律从 `playlist.tracks` 上取值：这条链最容易犯的错是「改到克隆副本上」
// （`Playlist.addAt` 会经 toJson/normalizeTrack 重建对象），盯着本地变量看不出来。
// 带标签的用例用 tag_fixtures 现造 ID3v2 字节写进临时文件，走的是真实的
// 「读文件 → 解析 → 回填」，不 mock 解析器。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/metadata/cover_image.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/transport_controller.dart';

import '../metadata/tag_fixtures.dart';

/// 记下所有提示的假 ToastSink（T20 的真实现是 ToastState）。
class RecordingToasts implements ToastSink {
  final List<String> messages = [];

  /// 经 [error] 发出的那几条（拒绝汇总句要求是 error 级）。
  final List<String> errors = [];

  @override
  void show(String message, {String key = '', int durationMs = 3200}) =>
      messages.add(message);

  @override
  void info(String message) => show(message);

  @override
  void error(String message) {
    errors.add(message);
    show(message);
  }
}

/// 真实的 1×1 不透明 PNG（与 cover_image_test 同一常量）：内嵌封面的最小样本。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

/// 等后台回填落地。
///
/// 导入刻意不 await 元数据（先可播），所以「入列」与「标签到位」是两个时刻；
/// 断言后者必须等它跑完，不能用固定 sleep 撞运气。
Future<void> waitUntil(bool Function() done, {required String reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // 封面用例要引擎的图像编解码（dart:ui），与 cover_image_test 一样先初始化绑定；
  // 其余用例都是普通 test()，走真实异步，不被 FakeAsync 卡住。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('light-import');
  });

  tearDown(() async {
    // 后台回填可能还攥着文件句柄（Windows 上会给删除加锁），删不掉就稍等重试；
    // 一直删不掉说明句柄真的漏了 —— 那时让用例失败，别把临时目录留在磁盘上。
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    fail('临时目录删不掉（可能有句柄泄漏）：${root.path}');
  });

  File writeFile(String name, [List<int>? bytes]) {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes ?? const [0x78]);
    return file;
  }

  /// 带 ID3v2.3 标签的文件：标签之后补一段 MPEG 帧，像真音频。
  List<int> withId3(List<List<int>> frames) => [
    ...id3v2(frames),
    ...mpegFrame(),
  ];

  test('非白名单文件点名两个后汇总，一次导入最多三条提示', () async {
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);

    final result = await service.importPaths([
      '/m/a.flac',
      '/m/b.txt',
      '/m/c.lrc',
      '/m/d.log',
      '/m/e.json',
      '/m/f.yaml',
    ]);

    expect(result.added, 1);
    expect(result.rejected, 5);
    // rejectedNames 照旧逐条记录（不去重），只有提示文案受上限约束
    expect(result.rejectedNames, [
      'b.txt',
      'c.lrc',
      'd.log',
      'e.json',
      'f.yaml',
    ]);
    expect(playlist.size, 1);
    // 前两个名字逐条点名，其余合成一句；一次导入恒定 ≤ 3 条横幅
    // （300 个 .lrc 也不会把界面刷屏）
    expect(toasts.messages, [
      '不支持的文件格式，已跳过：b.txt',
      '不支持的文件格式，已跳过：c.lrc',
      '另有 3 个文件不支持，已跳过',
    ]);
    // 汇总句是 error 级；前两条仍是普通横幅
    expect(toasts.errors, ['另有 3 个文件不支持，已跳过']);
  });

  test('同名拒绝只提示一次，没超过上限就不汇总', () async {
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);

    final result = await service.importPaths([
      '/m/a.flac',
      '/m/b.txt',
      '/m/c.lrc',
      '/m/b.txt',
    ]);

    expect(result.added, 1);
    expect(result.rejected, 3);
    expect(result.rejectedNames, ['b.txt', 'c.lrc', 'b.txt']);
    expect(playlist.size, 1);
    // 提示里给的是文件名而不是整条路径，且同一个名字只提示一次；
    // 去重后只有两个名字，够得上「逐条点名」，不该再补汇总句
    expect(toasts.messages, ['不支持的文件格式，已跳过：b.txt', '不支持的文件格式，已跳过：c.lrc']);
    expect(toasts.errors, isEmpty);
  });

  test('同一文件重复导入得到同一 id，且不重复入列', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    final first = await service.importPaths(['/m/a.flac']);
    final second = await service.importPaths(['/m/a.flac']);

    // 重复导入照样交回同一个 id（调用方靠它知道「这个文件已经在列表里」）
    expect(first.addedIds.single, second.addedIds.single);
    expect(first.addedIds.single, localIdFor('/m/a.flac'));
    expect(playlist.size, 1);
    expect(second.added, 0);
    expect(second.rejected, 0);
    // id 由来源字符串派生：local: + 16 个十六进制字符
    expect(localIdFor('/m/a.flac'), matches(RegExp(r'^local:[0-9a-f]{16}$')));
    expect(localIdFor('/m/a.flac'), isNot(localIdFor('/m/b.flac')));
  });

  test('新增曲目通过 onImported 交给上层落库，重复导入不再回调', () async {
    final batches = <List<String>>[];
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      onImported: (ids) async => batches.add(ids),
    );

    await service.importPaths(['/m/a.flac', '/m/b.flac']);
    await waitUntil(() => batches.isNotEmpty, reason: 'onImported 未回调');
    expect(batches.single, [localIdFor('/m/a.flac'), localIdFor('/m/b.flac')]);

    // 重复导入什么都没新增，不该再触发落库
    await service.importPaths(['/m/a.flac']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(batches.length, 1);
  });

  test('落库钩子抛错不影响导入结果', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      onImported: (_) async => throw StateError('落库失败'),
    );

    final result = await service.importPaths(['/m/a.flac']);
    expect(result.added, 1);
    expect(playlist.size, 1);
    // 等一等：没被吞掉的异常会在这里被测试框架记成未捕获错误
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('文件名拆分兜底：无标签时按「歌手 - 歌名」', () async {
    final file = writeFile('陈奕迅 - 十年.flac');
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    await service.importPaths([file.path]);

    final track = playlist.tracks.single;
    expect(track.title, '十年');
    expect(track.artist, '陈奕迅');
    expect(track.isLocal, isTrue);
    expect(track.hasDuration, isFalse);
    expect(track.handle.displayName, '陈奕迅 - 十年.flac');
  });

  test('普通文件路径的显示名仍是 basename，按反斜杠拆分不回归', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );
    const source = r'C:\m\陈奕迅 - 十年.flac';

    expect(service.displayNameFor(source), '陈奕迅 - 十年.flac');

    await service.importPaths([source]);

    final track = playlist.tracks.single;
    expect(track.title, '十年');
    expect(track.artist, '陈奕迅');
  });

  test('SAF 来源的显示名按解码后的真实文件名取，标题不带 %3A 垃圾', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );
    const source =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMusic%2Fa.flac';

    // 直接切分隔符只会得到 `primary%3AMusic%2Fa`；这里要的是 `a.flac`
    expect(service.displayNameFor(source), 'a.flac');

    await service.importPaths([source]);

    // 入列照旧（能播由播放错误那条路判定），只是标题必须来自 a.flac
    final track = playlist.tracks.single;
    expect(track.title, 'a');
    expect(track.title, isNot(contains('%3A')));
    // M1 不读 SAF 内容：没有标签也没有时长，但不许抛错
    expect(track.hasDuration, isFalse);
    expect(track.duration.isNaN, isTrue);
  });

  test('两侧都有的写法「歌名 - 歌手」先按原版规则猜，等标签纠正', () async {
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    await service.importPaths(['/m/孤勇者 - 陈奕迅.flac']);

    // 文件名分不清哪侧是歌手，原版一律先当「歌手 - 歌名」；
    // 猜反的那一半由内嵌标签纠正（见「标签优先」用例）。
    final track = playlist.tracks.single;
    expect(track.artist, '孤勇者');
    expect(track.title, '陈奕迅');
  });

  test('时长探测成功则填，探不出保持未知', () async {
    final probed = <String>[];
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (path) {
        probed.add(path);
        return path.contains('slow') ? double.nan : 187.5;
      },
    );

    await service.importPaths(['/m/fast.flac']);
    await waitUntil(
      () => playlist.tracks.single.hasDuration,
      reason: '快文件时长未回填',
    );
    expect(playlist.tracks.single.duration, 187.5);

    await service.importPaths(['/m/slow.flac']);
    await waitUntil(
      () => probed.any((path) => path.contains('slow')),
      reason: '慢文件未被探测',
    );
    // 探不出就是 NaN，绝不退成 0（0 会把「未知时长」显示成「零秒」）
    expect(playlist.tracks.last.duration.isNaN, isTrue);
    expect(playlist.tracks.last.hasDuration, isFalse);
  });

  test('标签回填写回列表里的活对象，不是传进去的那份副本', () async {
    final file = writeFile(
      '陈奕迅 - 十年.mp3',
      withId3([
        textFrame('TIT2', '白玫瑰'),
        textFrame('TPE1', '陈奕迅'),
        textFrame('TALB', '认了吧'),
      ]),
    );
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    await service.importPaths([file.path]);
    final live = playlist.tracks.single;
    // 模拟 addAt 的克隆产物：同 id、内容过时的副本
    final stale = live.copy()..title = '旧标题';

    await service.hydrateMetadata(stale);

    expect(identical(playlist.tracks.single, live), isTrue);
    expect(live.title, '白玫瑰');
    expect(live.artist, '陈奕迅');
    expect(live.album, '认了吧');
    expect(stale.title, '旧标题'); // 副本没有被写
  });

  test('标签优先：文件名拆出来的歌手与歌名被标签纠正', () async {
    final file = writeFile(
      '旧歌手 - 旧歌名.mp3',
      withId3([textFrame('TIT2', '白玫瑰'), textFrame('TPE1', '陈奕迅')]),
    );
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    await service.importPaths([file.path]);
    // 入列先按文件名（可播优先），标签稍后回填
    expect(playlist.tracks.single.title, '旧歌名');

    await waitUntil(
      () => playlist.tracks.single.title == '白玫瑰',
      reason: '标签未纠正曲名',
    );
    expect(playlist.tracks.single.artist, '陈奕迅');
  });

  test('标签只给了曲名时，歌手仍走文件名兜底', () async {
    final file = writeFile('陈奕迅 - 十年.mp3', withId3([textFrame('TIT2', '白玫瑰')]));
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
    );

    await service.importPaths([file.path]);
    await service.hydrateMetadata(playlist.tracks.single);

    expect(playlist.tracks.single.title, '白玫瑰');
    expect(playlist.tracks.single.artist, '陈奕迅');
  });

  test('内嵌封面落盘后把路径写回 cover', () async {
    final file = writeFile(
      'a.mp3',
      withId3([textFrame('TIT2', '白玫瑰'), apicFrame('image/png', onePixelPng)]),
    );
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      covers: const CoverImageWriter(),
      coverDirectory: '${root.path}${Platform.pathSeparator}covers',
    );

    await service.importPaths([file.path]);
    await service.hydrateMetadata(playlist.tracks.single);

    final live = playlist.tracks.single;
    expect(live.hasRealCover, isTrue);
    // 文件名沿用原版的 .jpg，内容其实是 PNG（见 cover_image.dart 的约定）
    expect(live.cover, endsWith('.jpg'));
    expect(File(live.cover).existsSync(), isTrue);
  });

  test('目录导入按自然顺序入列', () async {
    writeFile('track-2.flac');
    writeFile('track-10.flac');
    writeFile('track-1.flac');
    writeFile('note.txt');
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);

    final result = await service.importDirectory(root.path);

    expect(result.added, 3);
    // 扫描阶段就按白名单过滤了，非音频文件不该走到「拒绝」这一步
    expect(result.rejected, 0);
    expect(toasts.messages, isEmpty);
    expect(playlist.tracks.map((t) => t.handle.displayName).toList(), [
      'track-1.flac',
      'track-2.flac',
      'track-10.flac',
    ]);
  });

  test('目录里没有音频时只提示一句', () async {
    final empty = Directory('${root.path}${Platform.pathSeparator}empty')
      ..createSync();
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);

    final result = await service.importDirectory(empty.path);

    expect(result.added, 0);
    expect(playlist.size, 0);
    expect(toasts.messages, ['这个目录里没有可播放的音频文件']);
  });

  test('空输入什么都不做，也不弹提示', () async {
    final playlist = Playlist(tracks: const []);
    final toasts = RecordingToasts();
    final service = ImportService(playlist: playlist, toasts: toasts);

    final result = await service.importPaths(const []);

    expect(result.added, 0);
    expect(result.rejected, 0);
    expect(result.addedIds, isEmpty);
    expect(result.rejectedNames, isEmpty);
    expect(toasts.messages, isEmpty);
    expect(playlist.size, 0);
  });
}
