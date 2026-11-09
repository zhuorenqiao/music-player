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

    // stripExtension 的条件是 `dot > 0`（不是 `>= 0`）：首字符就是点的名字整串当
    // base。实现注释（manual_lyrics.dart:16-17）正是这么说的，但上面那条 `'.lrc'`
    // 用例分不出两种写法 —— `dot > 0` 得 base `.lrc`（对不上 → null），`dot >= 0`
    // 得 base `''`（提前 return null），两条路都是 null。
    // 只有「整串 base 恰好能配上」的输入才分得出来：曲名就叫 `.lrc` 时，
    // 正确实现（保留整串）命中 40 分，错误实现（切成空串）返回 null。
    test('stripExtension 的 dot > 0：首字符是点的名字整串保留', () {
      final dotted = [t('dot', title: '.lrc', src: '/m/dot.flac')];
      expect(matchLyricsTrack('.lrc', dotted)!.id, 'dot');
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

    // 上一条两侧的空白形态一致，所以「压缩空白」与「删空白」都能过 —— 它区分不出
    // 两种口径。这条用「压缩后不等」的输入把语义钉死：文件名 `a b` 压缩成 `a b`、
    // 曲名 `ab` 压缩成 `ab`，两者不等 → null；若实现写成「删空白」，两边都会变成
    // `ab` 而误配成同一首歌。brief 硬口径第 2 条点名这是**第四套**口径
    // （T9 删标点、T10 另一套、lrc_parser 再一套），别被复用到别的归一化里。
    test('空白是压缩不是删除：a b 与 ab 不是同一个名字', () {
      final only = [t('x', title: 'ab', src: '/m/x.flac')];
      expect(matchLyricsTrack('a b.lrc', only), isNull);
      // 对照组：曲名里空白**多一个**时仍能配上（两侧都压缩成同一个空格）。
      final spaced = [t('y', title: 'a  b', src: '/m/y.flac')];
      expect(matchLyricsTrack('a b.lrc', spaced)!.id, 'y');
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

    // 上一条用 ASCII，字节数 == 字符数，**区分不出**「按字节」与「按字符」：
    // 把实现改成 `text.length > kMaxLyricsBytes` 它照样绿。这条用中文内容把两种
    // 口径分开 —— 200000 个汉字按 UTF-8 是 600000 字节（该拒），但 `text.length`
    // 只有 200000（按字符会放行，然后在「没有时间轴」那关报另一句话）。
    // brief 硬口径第 4 条与实现注释（manual_lyrics.dart:27-28）都明写这是**字节**闸；
    // 真实链路上 GBK 歌词一个汉字两字节，写成字符数会把上限放宽约一倍。
    test('512KB 是字节闸：中文内容按 UTF-8 字节算，不按字符数', () async {
      final file = File('${dir.path}/cn.lrc')..writeAsStringSync('汉' * 200000);
      // 先确认这条用例的前提真的成立（免得将来换成别的编码后它变成恒真）。
      expect(file.lengthSync(), greaterThan(kMaxLyricsBytes));
      expect(file.readAsStringSync().length, lessThan(kMaxLyricsBytes));

      final read = await readLyricsFile(file.path, displayName: 'cn.lrc');
      expect(read.error, '歌词文件过大，已跳过：cn.lrc');
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
      // 逐字断言前两条的完整话术，不只断前缀 —— 后半句「同名的曲目，已拒绝替换」
      // 是用户唯一能看到的「为什么没换上」的说明，必须钉住。
      expect(messages[0], '未找到与「不存在0.lrc」同名的曲目，已拒绝替换');
      expect(messages[1], '未找到与「不存在1.lrc」同名的曲目，已拒绝替换');
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
