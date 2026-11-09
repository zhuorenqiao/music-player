// test/lyrics/lyrics_cache_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_cache.dart';

void main() {
  const hit = LyricsRecord(
    status: 'ok',
    synced: '[00:01]a',
    plain: 'a',
    source: 'LRCLIB',
  );
  const miss = LyricsRecord(status: 'not-found');

  group('索引缓存', () {
    late AppPrefs prefs;
    late LyricsIndexCache cache;
    late DateTime now;

    setUp(() {
      prefs = AppPrefs.inMemory();
      now = DateTime(2026, 1, 1);
      cache = LyricsIndexCache(prefs, now: () => now);
    });

    test('命中往返：synced / plain / source', () async {
      await cache.write('k', hit);
      final read = await cache.read('k');
      expect(read!.isOk, isTrue);
      expect(read.synced, '[00:01]a');
      expect(read.plain, 'a');
      expect(read.source, 'LRCLIB');
    });

    test('未命中往返：source 是「缓存」', () async {
      await cache.write('k', miss);
      final read = await cache.read('k');
      expect(read!.status, 'not-found');
      expect(read.source, '缓存');
    });

    test('命中 TTL 30 天：第 30 天仍命中，第 31 天失效', () async {
      await cache.write('k', hit);
      now = now.add(const Duration(days: 30));
      expect(await cache.read('k'), isNotNull);
      now = now.add(const Duration(days: 1, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('未命中 TTL 3 天', () async {
      await cache.write('k', miss);
      now = now.add(const Duration(days: 3));
      expect(await cache.read('k'), isNotNull);
      now = now.add(const Duration(days: 1, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('条目形状与 React 一致：命中 {s,p,src,at}、未命中 {miss,at}', () async {
      await cache.write('a', hit);
      await cache.write('b', miss);
      final raw = jsonDecode(
        (await prefs.readString(LyricsIndexCache.prefsKey))!,
      ) as Map;
      expect(raw['a'], {
        's': '[00:01]a',
        'p': 'a',
        'src': 'LRCLIB',
        'at': now.millisecondsSinceEpoch,
      });
      expect(raw['b'], {'miss': true, 'at': now.millisecondsSinceEpoch});
    });

    test('只写 ok / not-found，error 不落盘', () async {
      await cache.write('k', const LyricsRecord(status: 'error'));
      expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
    });

    test('超过 120 条按 at 淘汰最旧的，结果正好 120 条', () async {
      for (var i = 0; i < 130; i++) {
        now = DateTime(2026, 1, 1).add(Duration(seconds: i));
        await cache.write('k$i', hit);
      }
      final raw = jsonDecode(
        (await prefs.readString(LyricsIndexCache.prefsKey))!,
      ) as Map;
      expect(raw.length, 120);
      expect(raw.containsKey('k0'), isFalse);
      expect(raw.containsKey('k9'), isFalse);
      expect(raw.containsKey('k10'), isTrue);
      expect(raw.containsKey('k129'), isTrue);
    });

    test('脏 JSON 当空表，不抛', () async {
      await prefs.writeString(LyricsIndexCache.prefsKey, '{not json');
      expect(await cache.read('k'), isNull);
      await cache.write('k', hit);
      expect((await cache.read('k'))!.isOk, isTrue);
    });

    test('数组形态的脏数据当空表', () async {
      await prefs.writeString(LyricsIndexCache.prefsKey, '[]');
      expect(await cache.read('k'), isNull);
    });

    test('条目形状不对当没有缓存：at 不是数字 / 条目不是对象', () async {
      await prefs.writeString(
        LyricsIndexCache.prefsKey,
        '{"k":{"s":"x","p":"y","src":"LRCLIB","at":"oops"}}',
      );
      expect(await cache.read('k'), isNull);
      await prefs.writeString(LyricsIndexCache.prefsKey, '{"k":"x"}');
      expect(await cache.read('k'), isNull);
    });

    test('clear 清空整张表', () async {
      await cache.write('k', hit);
      await cache.clear();
      expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
      expect(await cache.read('k'), isNull);
    });
  });

  group('磁盘缓存', () {
    late Directory dir;
    late LyricsDiskCache disk;
    late DateTime now;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lyrics-cache-');
      addTearDown(() => dir.delete(recursive: true));
      now = DateTime(2026, 1, 1);
      disk = LyricsDiskCache(directory: dir.path, now: () => now);
    });

    test('keyFor 是 sha1(原文)，不 lowercase', () {
      final a = LyricsDiskCache.keyFor('Hello', 'Adele', '300');
      final b = LyricsDiskCache.keyFor('hello', 'adele', '300');
      expect(a, isNot(b));
      expect(a.length, 40);
      expect(a, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('keyFor 与 Node 的 sha1 逐字节一致（中文按 UTF-8）', () {
      // 黄金值由 node 生成：
      // node -e "const c=require('crypto');const h=s=>c.createHash('sha1').update(s).digest('hex');
      //   console.log(h('十年|陈奕迅|300'), h('陈奕迅|十年|300'), h('|十年|300'))"
      expect(
        LyricsDiskCache.keyFor('十年', '陈奕迅', '300'),
        '05ff7fb0ff22b44b7ed284e4f8fe813d64064e9c',
      );
      expect(
        LyricsDiskCache.keyFor('陈奕迅', '十年', '300'),
        '0ec702c6637fefe74524b6a075b12ea0e8a9346f',
      );
      // artist 为空时的对调 key：原版不特判，于是多写一条 "|<trackName>|<duration>"
      // 的垃圾条目 —— 原版怪癖，钉住它，别「顺手修好」。
      expect(
        LyricsDiskCache.keyFor('', '十年', '300'),
        '48b52668a4ec50f493e5dc2d1e4891ba1872dd31',
      );
    });

    test('往返 + 文件扩展名 .json', () async {
      final key = LyricsDiskCache.keyFor('十年', '陈奕迅', '300');
      await disk.write(key, hit);
      expect(File('${dir.path}/$key.json').existsSync(), isTrue);
      final read = await disk.read(key);
      expect(read!.synced, '[00:01]a');
      expect(read.source, 'LRCLIB');
    });

    // brief 原写「setLastModifiedSync(DateTime.now() …)」，与 set-up 里注入的
    // 2026-01-01 时钟不一致：读侧按注入时钟算差，31 天前的真实 mtime 会落在
    // 「未来」，任何正确实现都读回命中。这里把 mtime 也按注入时钟表达。
    test('TTL 按 mtime：命中 30 天、未命中 3 天', () async {
      final okKey = LyricsDiskCache.keyFor('a', 'b', '1');
      final missKey = LyricsDiskCache.keyFor('c', 'd', '2');
      await disk.write(okKey, hit);
      await disk.write(missKey, miss);
      final okFile = File('${dir.path}/$okKey.json');
      final missFile = File('${dir.path}/$missKey.json');
      okFile.setLastModifiedSync(now.subtract(const Duration(days: 31)));
      missFile.setLastModifiedSync(now.subtract(const Duration(days: 4)));
      expect(await disk.read(okKey), isNull);
      expect(await disk.read(missKey), isNull);
    });

    test('allowStale 跳过 TTL，过期的命中也能读回', () async {
      final key = LyricsDiskCache.keyFor('a', 'b', '1');
      await disk.write(key, hit);
      File('${dir.path}/$key.json')
          .setLastModifiedSync(now.subtract(const Duration(days: 400)));
      expect(await disk.read(key), isNull);
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.synced, '[00:01]a');
    });

    test('过期的 not-found 在 allowStale 下也能读回', () async {
      final key = LyricsDiskCache.keyFor('a', 'b', '1');
      await disk.write(key, miss);
      File('${dir.path}/$key.json')
          .setLastModifiedSync(now.subtract(const Duration(days: 400)));
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.status, 'not-found');
    });

    test('文件不存在 / 解析失败 → null', () async {
      expect(await disk.read('deadbeef'), isNull);
      File('${dir.path}/bad.json').writeAsStringSync('{oops');
      expect(await disk.read('bad'), isNull);
    });

    test('磁盘 JSON 用长字段名：命中四个字段、未命中只有 status', () async {
      final okKey = LyricsDiskCache.keyFor('a', 'b', '1');
      final missKey = LyricsDiskCache.keyFor('c', 'd', '2');
      await disk.write(okKey, hit);
      await disk.write(missKey, miss);
      expect(jsonDecode(File('${dir.path}/$okKey.json').readAsStringSync()), {
        'status': 'ok',
        'syncedLyrics': '[00:01]a',
        'plainLyrics': 'a',
        'source': 'LRCLIB',
      });
      expect(jsonDecode(File('${dir.path}/$missKey.json').readAsStringSync()), {
        'status': 'not-found',
      });
    });

    test('writeDual 写两份；两 key 相同时只写一份（内容相同）', () async {
      const record = LyricsRecord(status: 'ok', synced: 's', plain: 'p');
      await disk.writeDual('k1', 'k2', record);
      final first = File('${dir.path}/k1.json');
      final second = File('${dir.path}/k2.json');
      expect(first.existsSync(), isTrue);
      expect(second.existsSync(), isTrue);
      expect(first.readAsStringSync(), second.readAsStringSync());
      // 两 key 相同时「只写一份」在文件层面与写两次不可区分（同路径同内容），
      // 只能钉住「文件在」这一条。
      await disk.writeDual('k3', 'k3', record);
      expect(File('${dir.path}/k3.json').existsSync(), isTrue);
    });

    test('目录不可写时写失败被吞掉，不抛', () async {
      // brief 原用含 \u0000 的目录路径，实测 Dart 在该路径上 create() 并不抛
      // （截断后落到已存在的目录），用例恒真、根本走不到 catch。改成「目录位置
      // 被同名文件占住」：create 必抛 PathExistsException，才真的验到吞异常。
      final blocker = File('${dir.path}/blocked')
        ..writeAsStringSync('occupied');
      final broken = LyricsDiskCache(directory: blocker.path);
      await expectLater(broken.write('k', hit), completes);
      expect(File('${blocker.path}/k.json').existsSync(), isFalse);
    });
  });
}
