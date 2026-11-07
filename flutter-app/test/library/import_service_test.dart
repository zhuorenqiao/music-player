// test/library/import_service_test.dart
//
// 导入流程：校验扩展名 → 立即入列（可播）→ 解析内嵌标签 → 探时长 → 落库钩子。
//
// 断言一律从 `playlist.tracks` 上取值：这条链最容易犯的错是「改到克隆副本上」
// （`Playlist.addAt` 会经 toJson/normalizeTrack 重建对象），盯着本地变量看不出来。
// 带标签的用例用 tag_fixtures 现造 ID3v2 字节写进临时文件，走的是真实的
// 「读文件 → 解析 → 回填」，不 mock 解析器。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/duration_probe.dart';
import 'package:light_music/library/import_service.dart';
import 'package:light_music/metadata/cover_image.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/track_handle.dart';
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

/// 落盘必失败的封面写入器：磁盘满 / 缓存目录只读这类真实故障的形状。
///
/// 真实的 `CoverImageWriter.write` 契约是「永不抛、只返回 null」，但端口对象是
/// 可替换的：任何一次实现替换 / 平台异常都可能让它抛出来（第 4 轮 I10 要钉住的
/// 是「封面这一抛不许把已经拿到的标签与时长一起带走」）。
class _FailingCoverWriter extends CoverImageWriter {
  const _FailingCoverWriter();

  @override
  Future<String?> write(
    Uint8List bytes,
    String mime, {
    required String directory,
    String id = '',
  }) async {
    throw const FileSystemException('covers 目录写不进去');
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

  /// 终审 R7：SAF 的 `content://` 句柄**不许进时长探针**。
  ///
  /// `MediaKitDurationOpener` 把来源一律包成 `Media(FilePathHandle(source).uri)`，
  /// 而 M1 没有 ContentResolver 通道 —— 这类句柄根本开不了，结果是每首白等满
  /// 3000ms 预算再换一个 NaN（还正好和 R1 的「没探到」叠成反复重跑）。
  /// 判据放在句柄自己身上：能开文件才值得排队探测。
  test('content:// 曲目不触达时长探针', () async {
    const safSource =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMusic%2Fa.flac';
    final probed = <String>[];
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (path) async {
        probed.add(path);
        return const DurationProbeOutcome(187.5);
      },
    );

    final result = await service.importPaths([safSource, '/m/b.flac']);
    await result.enrichment;

    expect(
      probed,
      ['/m/b.flac'],
      reason: '只有真文件进探针；content:// 一次也不许（白等 3 秒换 NaN）',
    );
    expect(playlist.tracks.first.hasDuration, isFalse);
    expect(playlist.tracks.last.duration, 187.5);
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
      // 异步签名：真探测要等原生内核回报时长（I1），假的也得是同一个形态。
      durationProbe: (path) async {
        probed.add(path);
        return DurationProbeOutcome(path.contains('slow') ? double.nan : 187.5);
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

  // -- 第 3 轮 C1 / I1：探测标记只能记给「真的看过这个文件」的那几条路 --------
  //
  // 第 2 轮 R1 把「要不要再补跑一次」全押在落盘的 `metadataProbed` 上，方向是对的；
  // 但置位点写在外壳的 `finally` 里，于是**整条管路什么都没干**的那一支（文件根本
  // 没打开、时长探针被超时掐断）也照样记上了「已探测」。重复导入同一个路径是
  // no-op，谓词此后恒为 false —— 除了改档案格式之外没有任何自愈路径，一次
  // 暂时的「盘没挂上」就被冻结成永久降级（歌手/歌名猜反、时长 `--:--` 永远留着）。
  // 这一组用例钉的就是「标记只记给结论，不记给失败」。

  Track restoredFromArchive(String path, {String title = '白玫瑰', TrackHandle? handle}) => Track(
        id: localIdFor(path),
        src: path,
        title: title,
        artist: '陈奕迅',
        duration: double.nan,
        isLocal: true,
        handle: handle,
      );

  test('文件暂时打不开时不记探测标记，插回硬盘后下次启动补得回来', () async {
    // 档案里早就有这条记录，文件这一次没挂上（U 盘 / 网盘尚未就位、或被别的进程占用）。
    final path = '${root.path}${Platform.pathSeparator}陈奕迅 - 白玫瑰.mp3';
    final playlist = Playlist(tracks: const []);
    playlist.replaceAll([restoredFromArchive(path)]);
    var probes = 0;
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      // 与真内核同一个脾气：文件不在就是探不出（不是超时，是「这次没有结果」）。
      durationProbe: (source) async {
        probes += 1;
        return File(source).existsSync()
            ? const DurationProbeOutcome(187.5)
            : const DurationProbeOutcome(double.nan);
      },
    );

    await service.rehydrateIncomplete();

    expect(
      playlist.tracks.single.metadataProbed,
      isFalse,
      reason: '什么都没读到的这一次不算结论，记了标记就再也没人来看第二眼',
    );
    expect(
      metadataIncomplete(playlist.tracks.single),
      isTrue,
      reason: '自愈通路还活着：这条仍然在下一次的候选里',
    );
    expect(playlist.tracks.single.duration.isNaN, isTrue);

    // 盘插回来了：同一条记录、同一个服务，第二次启动必须把标签与时长补上。
    File(path).writeAsBytesSync(withId3([
      textFrame('TIT2', '红玫瑰'),
      textFrame('TPE1', '陈奕迅'),
    ]));
    await service.rehydrateIncomplete();

    final healed = playlist.tracks.single;
    expect(healed.title, '红玫瑰', reason: '补跑必须真的把标签回填上');
    expect(healed.duration, 187.5, reason: '时长也一样补上');
    expect(healed.metadataProbed, isTrue, reason: '这次真的看过文件，才许记账');
    expect(probes, 2, reason: '一次启动最多重试一次，两条都在这一次的份额里');
  });

  test('时长探针超时的曲目不记探测标记', () async {
    // 文件在盘上、标签读得出来（hydrate 这一路是成功的），只有内核在预算里没回话：
    // 大 FLAC 首次打开、媒体线程排队都会这样。这跟「这文件真的没有时长」不是一回事。
    final file = writeFile(
      '慢文件.flac',
      withId3([textFrame('TIT2', '甲'), textFrame('TPE1', '陈奕迅')]),
    );
    final never = Completer<double>();
    final probe = DurationProbe((source) => never.future, timeoutMs: 5);
    addTearDown(probe.close);

    final playlist = Playlist(tracks: const []);
    playlist.replaceAll([restoredFromArchive(file.path)]);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      // 走**真探针**而不是假函数：装配层那条线接错（交成 `probe.call`）也要被这条抓住。
      durationProbe: probe.probeOutcome,
    );

    await service.rehydrateIncomplete();

    expect(
      playlist.tracks.single.metadataProbed,
      isFalse,
      reason: '超时是暂时的失败；记上标记就等于把这一个人永久冻在 --:--',
    );
    expect(playlist.tracks.single.title, '甲', reason: '标签那半截是真读到的，照样留下');
    expect(
      metadataIncomplete(playlist.tracks.single),
      isTrue,
      reason: '下一次启动还要再探一次（标题已不是文件名猜值，靠时长这一条撑住）',
    );
  });

  test('打开了但确实没标签的曲目只治一次', () async {
    // 守 R1 的正向结论别被 C1 这次改回去：文件能打开、里面确实什么标签都没有、
    // 时长也确实探不出来（**不是**超时）—— 这就是结论，第二次启动不许再开文件。
    final file = writeFile('空壳.mp3');
    final playlist = Playlist(tracks: const []);
    playlist.replaceAll([restoredFromArchive(file.path, title: '空壳')]);
    var probes = 0;
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (source) async {
        probes += 1;
        return const DurationProbeOutcome(double.nan);
      },
    );

    await service.rehydrateIncomplete();

    expect(probes, 1);
    expect(
      playlist.tracks.single.metadataProbed,
      isTrue,
      reason: '看过了、确实什么都没有 —— 这就是 R1 要止住的那次反复重跑',
    );
    expect(metadataIncomplete(playlist.tracks.single), isFalse);

    probes = 0;
    expect(
      service.rehydrateIncomplete(),
      isNull,
      reason: '第二次启动连队列都不该进（没有要补的），更不该再探一次',
    );
    expect(probes, 0);
  });

  // -- 第 4 轮 C8：探针「已关闭」不是「这文件没有时长」 -----------------------

  test('探针关掉后没跑到的曲目不记探测标记', () async {
    // 真实路径：首次冷启动的自愈回填刚排上队，用户在 Android 上按了返回键 ——
    // `lib/app.dart` 的 `unawaited(bootstrap.dispose())` → `probe.close()`。
    // close() 会把已入队的探测照常排空（这是对的），但排空期间 `_closed` 已为真：
    // 从前每一条都落成「探了一趟、结论是没时长」，毫秒级跑完，标记照记 ——
    // 这批曲目从此永远 `--:--` 且没有自愈路径（第 2 轮 C1 的冻结换个入口回来）。
    final files = [
      writeFile('a.mp3', withId3([textFrame('TIT2', '甲')])),
      writeFile('b.mp3', withId3([textFrame('TIT2', '乙')])),
      writeFile('c.mp3', withId3([textFrame('TIT2', '丙')])),
    ];
    var calls = 0;
    final first = Completer<double>();
    final probe = DurationProbe((source) {
      calls += 1;
      // 第一条真的在飞（等我们放行），后面几条「秒回」：这样两种关闭时机都会被
      // 走到 —— 已入队但还没轮到（收尾时才发现已关）与关闭之后才入队（根本没探）。
      if (calls == 1) return first.future;
      return Future<double>.value(187.5);
    }, timeoutMs: 200);
    addTearDown(probe.close);

    final playlist = Playlist(tracks: const []);
    playlist.replaceAll([
      for (final file in files) restoredFromArchive(file.path),
    ]);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      // 走**真探针**：`probeOutcome` 把「关闭」丢掉的那条路也要被这条抓住。
      durationProbe: probe.probeOutcome,
    );

    final batch = service.rehydrateIncomplete();
    await waitUntil(() => calls == 1, reason: '第一条探测没开始');
    // 用户按了返回键：探针关闭，队列开始排空
    final closing = probe.close();
    first.complete(187.5); // 正在飞的那条照常收尾（close 要等它跑完）
    await closing;
    await batch;

    expect(
      playlist.tracks.every((track) => !track.metadataProbed),
      isTrue,
      reason: '关闭期间跑完的探测不是这个文件自己的结论；记上就是永久冻结',
    );
    expect(
      playlist.tracks.any((track) => track.hasDuration),
      isTrue,
      reason: '数已经拿到就照填（能填就填），只是不许记账',
    );
  });

  // -- 第 4 轮 I9：探针的成功本身就是一次见证 ---------------------------------

  test('标签读不出但时长探到的曲目也算治过', () async {
    // Windows 共享冲突那种形状：mpv 打得开（能探到时长），dart:io 打不开
    // （标签一个字节也读不到）。这条曲目的时长就是真结论 —— 只看 `opened`
    // 的写法会让它永远不记账：每次启动重开文件、重探一遍，再把整库档案重写一遍。
    final path = '${root.path}${Platform.pathSeparator}正在被占用的文件.flac';
    final playlist = Playlist(tracks: const []);
    playlist.replaceAll([restoredFromArchive(path)]);
    var probes = 0;
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (source) async {
        probes += 1;
        return const DurationProbeOutcome(187.5);
      },
    );

    await service.rehydrateIncomplete();

    final live = playlist.tracks.single;
    expect(probes, 1);
    expect(live.duration, 187.5, reason: '探到的时长照填');
    expect(
      live.metadataProbed,
      isTrue,
      reason: '探到了时长就是一次见证：标签读不出不代表这一次什么都没看见',
    );
    expect(metadataIncomplete(live), isFalse);
    expect(
      service.rehydrateIncomplete(),
      isNull,
      reason: '治过的曲目下次启动不许再重开文件、重探、整库重写',
    );
    expect(probes, 1);
  });

  // -- 第 4 轮 I10：封面落盘失败只影响封面 -------------------------------------

  test('封面落盘失败仍记探测标记', () async {
    // 磁盘满 / 缓存目录只读：封面写不进去。但索引区已经读完、title/artist/album
    // 也已经写进活对象、时长探针也好好的 —— 这些是结论。从前封面那一抛会冒到
    // `_enrichQuiet` 的 catch，把整条结论一起丢掉。
    final file = writeFile(
      'a.mp3',
      withId3([
        textFrame('TIT2', '白玫瑰'),
        textFrame('TPE1', '陈奕迅'),
        apicFrame('image/png', onePixelPng),
      ]),
    );
    final playlist = Playlist(tracks: const []);
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      covers: const _FailingCoverWriter(),
      coverDirectory: '${root.path}${Platform.pathSeparator}covers',
      durationProbe: (source) async => const DurationProbeOutcome(187.5),
    );

    final result = await service.importPaths([file.path]);
    await result.enrichment;

    final live = playlist.tracks.single;
    expect(live.title, '白玫瑰', reason: '标签已经读到了，不许因为封面没落上就回退');
    expect(live.artist, '陈奕迅');
    expect(live.duration, 187.5, reason: '时长也探到了');
    expect(live.hasRealCover, isFalse, reason: '失败只影响 cover 字段');
    expect(
      live.metadataProbed,
      isTrue,
      reason: '封面写盘失败不许把已经拿到的结论一起带走',
    );
  });

  test('content:// 曲目不记探测标记（M2 接上 SAF 后要能自愈）', () async {
    const safSource =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMusic%2Fa.flac';
    final playlist = Playlist(tracks: const []);
    var probes = 0;
    final service = ImportService(
      playlist: playlist,
      toasts: RecordingToasts(),
      durationProbe: (source) async {
        probes += 1;
        return const DurationProbeOutcome(200);
      },
    );

    // 导入侧：M1 把 SAF 串存成 FilePathHandle（T22 才换 SafUriHandle），
    // 这条路上 dart:io 永远开不了它 —— 一个字都没读到，就没有资格记账。
    final result = await service.importPaths([safSource]);
    await result.enrichment;
    expect(
      playlist.tracks.single.metadataProbed,
      isFalse,
      reason: '记上就是替 M2 宣布「这条不用管」，将来接上 SAF 读取也看不见',
    );

    // 谓词侧：准入条件换成能力位之后，这类曲目**不进回填队列**（也就每次启动白跑一次都没有）。
    playlist.replaceAll([
      restoredFromArchive(safSource, handle: SafUriHandle(safSource, 'a.flac')),
    ]);
    expect(
      service.rehydrateIncomplete(),
      isNull,
      reason: '句柄自己说不能探 → 整个回填都不排这一条',
    );
    expect(
      metadataIncomplete(playlist.tracks.single),
      isFalse,
      reason: '谓词按能力位排除（第 2 轮 R7 的探针守卫仍在，双保险）',
    );
    expect(playlist.tracks.single.metadataProbed, isFalse);
    expect(
      probes,
      0,
      reason: '两条路都挡在探针之前（R7 的守卫 + I1 的谓词），一次也不许白等 3 秒',
    );
  });
}