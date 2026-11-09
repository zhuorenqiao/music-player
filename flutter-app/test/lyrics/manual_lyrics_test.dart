// test/lyrics/manual_lyrics_test.dart
//
// T12 手动 .lrc：按文件名配对（src/state/lyrics-file.ts:17-99）与
// applyLyricsFiles（src/state/library.tsx:69-108）。
//
// 四条打分线各有一个**鉴别性**用例（不是只断言「能配上」）：
//   * 50：「歌手 - 歌名」组合名一致；
//   * 45：拆出的歌名 + 歌手都对，但组合名与文件名不同（用 U+2013 的 `–` 分隔，
//     组合名只认半角 `-`，于是 45 能压过另一首 40 分的曲目 —— 写成 30 就会选错）；
//   * 40：曲名完全一致，并且能压过同时命中的 30 分候选；
//   * 30：只有拆出的歌名一致。
// 另有一条钉住占位歌手（「本地文件」/「未知歌手」）拿不到 50 分。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/manual_lyrics.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart' show ToastSink;

/// 记下 (文案, 停留时长) 的假 ToastSink：本任务只改时长，故必须连时长一起记。
class RecordingToasts implements ToastSink {
  final List<(String, int)> items = [];

  @override
  void show(String message, {String key = '', int durationMs = 3200}) =>
      items.add((message, durationMs));

  @override
  void info(String message) => items.add((message, 3200));

  @override
  void error(String message, {int durationMs = 3200}) =>
      items.add((message, durationMs));
}

Track t(
  String id, {
  required String title,
  String artist = '',
  String src = '',
}) => Track(
  id: id,
  src: src.isEmpty ? '/m/$title.flac' : src,
  title: title,
  artist: artist,
  isLocal: true,
);

void main() {
  group('matchLyricsTrack', () {
    final tracks = [
      t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac'),
      t('2', title: '孤勇者', artist: '陈奕迅', src: '/m/孤勇者.flac'),
      t(
        '3',
        title: 'Yesterday',
        artist: 'The Beatles',
        src: '/m/The Beatles - Yesterday.flac',
      ),
    ];

    test('「歌手 - 歌名」组合名一致 → 50', () {
      expect(matchLyricsTrack('陈奕迅 - 十年.lrc', tracks)!.id, '1');
    });

    test('拆出歌名且歌手一致 → 45（压过另一首的 40）', () {
      // 文件名用 en dash（U+2013）分隔：splitArtistTitle 照样拆得出，
      // 但「歌手 - 歌名」组合名只认半角 `-`，故 50 那条不成立，只剩 45。
      // 后半条是鉴别项：若错写成 30，40 分的那首会反超。
      final only = [
        t('2b', title: '孤勇者', artist: '陈奕迅', src: '/m/x.flac'),
        t('z', title: '陈奕迅 – 孤勇者', src: '/m/y.flac'),
      ];
      expect(matchLyricsTrack('陈奕迅 – 孤勇者.lrc', only)!.id, '2b');
    });

    test('曲名完全一致 → 40', () {
      expect(matchLyricsTrack('孤勇者.lrc', tracks)!.id, '2');
    });

    test('40 压过同时命中的 30', () {
      // 对 a 来说只命中「拆出的歌名」（30）；b 的曲名就是文件名（40）→ b 该赢。
      final both = [
        t('a', title: '十年', artist: '陈奕迅', src: '/m/a.flac'),
        t('b', title: '别人 - 十年', src: '/m/b.flac'),
      ];
      expect(matchLyricsTrack('别人 - 十年.lrc', both)!.id, 'b');
    });

    test('只有拆出的歌名一致 → 30', () {
      expect(matchLyricsTrack('别人 - 十年.lrc', tracks)!.id, '1');
    });

    test('对不上 → null（不兜底到任何曲目）', () {
      expect(matchLyricsTrack('完全不存在的歌.lrc', tracks), isNull);
    });

    test('空文件名 → null', () {
      expect(matchLyricsTrack('.lrc', tracks), isNull);
    });

    test('同分取靠前的', () {
      final dup = [t('a', title: '十年'), t('b', title: '十年')];
      expect(matchLyricsTrack('十年.lrc', dup)!.id, 'a');
    });

    test('占位歌手不算 real artist，拿不到 50 分', () {
      // 文件名拼出来的组合名正好等于这条曲目的 `artist - title`：占位歌手若也
      // 算 real artist，这里就会拿到 50 分把真正该赢的 40 分候选挤掉。
      // React 的实际行为：占位歌手 → 只剩「拆出的歌名」30 分，40 分的那首赢。
      final ph = [
        t('p', title: '十年', artist: '本地文件', src: '/m/x.flac'),
        t('q', title: '本地文件 - 十年', src: '/m/q.flac'),
      ];
      expect(matchLyricsTrack('本地文件 - 十年.lrc', ph)!.id, 'q');
      // 曲名一致那条路照旧可用（40 分不依赖歌手）。
      expect(matchLyricsTrack('十年.lrc', ph)!.id, 'p');
    });

    test('大小写与多余空白不影响', () {
      expect(
        matchLyricsTrack('the   beatles - yesterday.LRC', tracks)!.id,
        '3',
      );
    });
  });

  group('readLyricsFile', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('lrc-'));
    tearDown(() => dir.delete(recursive: true));

    test('正常 LRC 返回文本与行数', () async {
      final file = File('${dir.path}/a.lrc')
        ..writeAsStringSync('[00:01]甲\n[00:02]乙');
      final read = await readLyricsFile(file.path, displayName: 'a.lrc');
      expect(read.isError, isFalse);
      expect(read.lineCount, 2);
      expect(read.text, '[00:01]甲\n[00:02]乙');
    });

    test('没有时间轴 → 拒绝', () async {
      final file = File('${dir.path}/a.lrc')..writeAsStringSync('一行没有时间轴的歌词');
      final read = await readLyricsFile(file.path, displayName: 'a.lrc');
      expect(read.error, '「a.lrc」里没有可识别的时间轴歌词，已跳过');
    });

    test('超过 512KB → 拒绝', () async {
      final file = File('${dir.path}/big.lrc')
        ..writeAsStringSync('x' * (kMaxLyricsBytes + 1));
      final read = await readLyricsFile(file.path, displayName: 'big.lrc');
      expect(read.error, '歌词文件过大，已跳过：big.lrc');
    });

    test('读不了 → 拒绝', () async {
      final read = await readLyricsFile(
        '${dir.path}/missing.lrc',
        displayName: 'missing.lrc',
      );
      expect(read.error, '读取歌词失败：missing.lrc');
    });

    test('GBK 字节按 UTF-8 替换解码后多半没有时间轴 → 拒绝而不是抛', () async {
      final file = File('${dir.path}/gbk.lrc')
        ..writeAsBytesSync([0xB8, 0xE8, 0xB4, 0xCA]); // GBK「歌词」
      final read = await readLyricsFile(file.path, displayName: 'gbk.lrc');
      expect(read.isError, isTrue);
    });
  });

  group('apply', () {
    test('命中：写回活对象、标 manual、清 plain、提示 6000ms', () async {
      final playlist = Playlist(
        tracks: [t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac')],
      );
      // Playlist 只要非空就有一首「当前曲目」（React 同样 currentIndex=0），
      // 而这条用例要钉的是**非当前曲目**那一句文案，所以先清掉光标。
      playlist.clearCurrent();
      final toasts = RecordingToasts();
      final manual = ManualLyrics(playlist: playlist, toasts: toasts);
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/陈奕迅 - 十年.lrc')
        ..writeAsStringSync('[00:01]甲\n[00:02]乙');

      final result = await manual.apply([file.path]);
      expect(result.matched, 1);
      expect(result.unmatched, 0);
      final track = playlist.byId('1')!;
      expect(track.lyrics, '[00:01]甲\n[00:02]乙');
      expect(track.lyricsPlain, '');
      expect(track.lyricsSource, 'manual');
      expect(toasts.items.last.$2, 6000);
      expect(toasts.items.last.$1, '已为「十年」配好 2 行歌词，切到这首即可查看');
    });

    test('当前曲目 → 「加载」文案', () async {
      final playlist = Playlist(
        tracks: [t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac')],
      );
      playlist.setCurrentById('1');
      final toasts = RecordingToasts();
      final manual = ManualLyrics(playlist: playlist, toasts: toasts);
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/陈奕迅 - 十年.lrc')
        ..writeAsStringSync('[00:01]甲');

      await manual.apply([file.path]);
      expect(playlist.byId('1')!.lyrics, '[00:01]甲');
      expect(toasts.items.last.$1, '已为「十年」加载 1 行歌词');
      expect(toasts.items.last.$2, 6000);
    });

    test('前 2 个对不上逐条提示，其余汇总，且不改任何曲目', () async {
      final playlist = Playlist(tracks: [t('1', title: '十年')]);
      final toasts = RecordingToasts();
      final manual = ManualLyrics(playlist: playlist, toasts: toasts);
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final paths = <String>[];
      for (var i = 0; i < 4; i++) {
        final f = File('${dir.path}/不存在$i.lrc')..writeAsStringSync('[00:01]甲');
        paths.add(f.path);
      }

      final result = await manual.apply(paths);
      expect(result.unmatched, 4);
      expect(playlist.byId('1')!.lyrics, '');
      final messages = toasts.items.map((e) => e.$1).toList();
      expect(messages.where((m) => m.startsWith('未找到与')).length, 2);
      expect(messages.last, '另有 2 个歌词文件没有找到对应曲目');
      // 配对失败与汇总都是 info 级、6000ms（React 传的是 'info'）。
      expect(toasts.items.last.$2, 6000);
    });

    test('坏文件不影响后面的好文件', () async {
      final playlist = Playlist(
        tracks: [
          t('1', title: '十年', artist: '陈奕迅', src: '/m/陈奕迅 - 十年.flac'),
          t('2', title: '孤勇者', artist: '陈奕迅', src: '/m/陈奕迅 - 孤勇者.flac'),
        ],
      );
      final manual = ManualLyrics(
        playlist: playlist,
        toasts: RecordingToasts(),
      );
      final dir = await Directory.systemTemp.createTemp('lrc-');
      addTearDown(() => dir.delete(recursive: true));
      final bad = File('${dir.path}/坏.lrc')..writeAsStringSync('没有时间轴');
      final good = File('${dir.path}/陈奕迅 - 孤勇者.lrc')
        ..writeAsStringSync('[00:01]甲');

      final result = await manual.apply([bad.path, good.path]);
      expect(result.matched, 1);
      expect(playlist.byId('2')!.lyricsSource, 'manual');
    });
  });
}
