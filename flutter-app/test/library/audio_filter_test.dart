// test/library/audio_filter_test.dart
//
// 导入流程的前半段：白名单校验 + 文件夹扫描。
// 这里的顺序会变成播放列表顺序，所以排序与拒绝名单都是用户可见的，
// 每个用例都盯着「哪些进了」「顺序是什么」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/audio_filter.dart';

void main() {
  test('白名单外的一律拒绝，顺序不变', () {
    final input = ['/m/a.flac', '/m/b.txt', '/m/c.MP3', '/m/d.lrc', '/m/e.m4a'];
    final result = partitionByExtension(input);
    expect(result.accepted, ['/m/a.flac', '/m/c.MP3', '/m/e.m4a']);
    expect(result.rejected, ['/m/b.txt', '/m/d.lrc']);
    // filterSupported 与 accepted 必须是同一支，导入方两边都能用
    expect(filterSupported(input), result.accepted);
  });

  test('无扩展名与以点结尾都算拒绝', () {
    final result = partitionByExtension(['/m/README', '/m/x.']);
    expect(result.accepted, isEmpty);
    expect(result.rejected, ['/m/README', '/m/x.']);
  });

  test('自然排序按数值比数字段', () {
    expect(
      naturalSort(['/m/track-10.flac', '/m/track-2.flac', '/m/track-1.flac']),
      ['/m/track-1.flac', '/m/track-2.flac', '/m/track-10.flac'],
    );
    expect(naturalSort(['/m/第2首.flac', '/m/第10首.flac', '/m/第1首.flac']), [
      '/m/第1首.flac',
      '/m/第2首.flac',
      '/m/第10首.flac',
    ]);
    // 数字段超出 64 位也不能退化成字典序
    expect(
      naturalSort([
        '/m/99999999999999999999999.flac',
        '/m/9999999999999999999999.flac',
      ]),
      ['/m/9999999999999999999999.flac', '/m/99999999999999999999999.flac'],
    );
  });

  test('数字段同值（前导零）时按整串兜底，结果与输入顺序无关', () {
    const expected = ['/m/02.flac', '/m/2.flac'];
    expect(naturalSort(['/m/2.flac', '/m/02.flac']), expected);
    expect(naturalSort(['/m/02.flac', '/m/2.flac']), expected);
  });

  test('递归扫描只收白名单，隐藏目录跳过', () async {
    final dir = Directory.systemTemp.createTempSync('light-scan');
    File('${dir.path}/a.flac').writeAsStringSync('x');
    File('${dir.path}/b.txt').writeAsStringSync('x');
    Directory('${dir.path}/sub').createSync();
    File('${dir.path}/sub/c.mp3').writeAsStringSync('x');
    Directory('${dir.path}/.hidden').createSync();
    File('${dir.path}/.hidden/d.flac').writeAsStringSync('x');

    final found = await scanAudioDirectory(dir.path);
    expect(found.map((e) => e.name).toSet(), {'a.flac', 'c.mp3'});

    final flat = await scanAudioDirectory(dir.path, recursive: false);
    expect(flat.map((e) => e.name), ['a.flac']);
    dir.deleteSync(recursive: true);
  });

  test('名字以点开头的目录被跳过，同级可见目录照收', () async {
    final dir = Directory.systemTemp.createTempSync('light-scan-dotdir');
    Directory('${dir.path}/.cache').createSync();
    File('${dir.path}/.cache/buried.flac').writeAsStringSync('x');
    Directory('${dir.path}/cache').createSync();
    File('${dir.path}/cache/ok.mp3').writeAsStringSync('x');

    final found = await scanAudioDirectory(dir.path);
    expect(found.map((e) => e.name), ['ok.mp3']);
    dir.deleteSync(recursive: true);
  });

  test('maxFiles 截断', () async {
    final dir = Directory.systemTemp.createTempSync('light-scan-limit');
    for (var i = 0; i < 5; i++) {
      File('${dir.path}/$i.flac').writeAsStringSync('x');
    }
    final found = await scanAudioDirectory(dir.path, maxFiles: 3);
    expect(found.length, 3);
    dir.deleteSync(recursive: true);
  });

  test('不存在的目录返回空列表，不抛', () async {
    expect(await scanAudioDirectory('/no/such/dir/at/all'), isEmpty);
  });
}
