// test/lyrics/translate_cache_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/translate_cache.dart';

void main() {
  const ok = TranslationRecord(
    status: 'ok',
    translated: '[00:01]A',
    original: '[00:01]a',
    source: '网易云译文库（人工翻译）',
  );
  const none = TranslationRecord(status: 'not-found', reason: 'no-translation');

  group('索引缓存', () {
    late AppPrefs prefs;
    late TranslationIndexCache cache;
    late DateTime now;

    setUp(() {
      prefs = AppPrefs.inMemory();
      now = DateTime(2026, 1, 1);
      cache = TranslationIndexCache(prefs, now: () => now);
    });

    test('命中往返，source 默认「网易云译文库」', () async {
      await cache.write(
        'k',
        const TranslationRecord(status: 'ok', translated: 't', original: 'o'),
      );
      final read = await cache.read('k');
      expect(read!.status, 'ok');
      expect(read.translated, 't');
      expect(read.original, 'o');
      expect(read.source, '网易云译文库');
    });

    test('未命中往返，reason 默认 song-not-matched，message 不落盘', () async {
      await cache.write('k', const TranslationRecord(status: 'not-found'));
      final read = await cache.read('k');
      expect(read!.status, 'not-found');
      expect(read.reason, 'song-not-matched');
      final raw = jsonDecode(
        (await prefs.readString(TranslationIndexCache.prefsKey))!,
      ) as Map<String, Object?>;
      expect((raw['k'] as Map).containsKey('message'), isFalse);
    });

    test('条目形状：命中 {status,t,o,src,at}、未命中 {status,reason,at}', () async {
      await cache.write('a', ok);
      await cache.write('b', none);
      final raw = jsonDecode(
        (await prefs.readString(TranslationIndexCache.prefsKey))!,
      ) as Map<String, Object?>;
      expect((raw['a'] as Map)['status'], 'ok');
      expect((raw['a'] as Map)['t'], '[00:01]A');
      expect((raw['a'] as Map)['o'], '[00:01]a');
      expect((raw['a'] as Map)['src'], '网易云译文库（人工翻译）');
      expect((raw['a'] as Map)['at'], now.millisecondsSinceEpoch);
      expect(raw['b'], {
        'status': 'not-found',
        'reason': 'no-translation',
        'at': now.millisecondsSinceEpoch,
      });
    });

    // brief 原写第二处推进 `days: 27`，与前面已过的 4 天相加是第 31 天，
    // 已越过 30 天命中 TTL —— 任何正确实现都会读回 null。React 的判据是
    // `Date.now() - at > TTL`（严格大于，translate-source.js:151），所以第 30 天
    // 仍算命中。这里把推进量改成 26 天，把断言钉在「正好 30 天仍命中」这个边界上。
    test('TTL：命中 30 天、未命中 3 天', () async {
      await cache.write('ok', ok);
      await cache.write('none', none);
      now = now.add(const Duration(days: 4));
      expect(await cache.read('ok'), isNotNull);
      expect(await cache.read('none'), isNull);
      now = now.add(const Duration(days: 26));
      expect(await cache.read('ok'), isNotNull);
      now = now.add(const Duration(days: 1, seconds: 1));
      expect(await cache.read('ok'), isNull);
    });

    test('只写 ok / not-found', () async {
      await cache.write('k', const TranslationRecord(status: 'error'));
      expect(await prefs.readString(TranslationIndexCache.prefsKey), isNull);
    });

    test('超限按 at 淘汰到正好 120 条', () async {
      for (var i = 0; i < 125; i++) {
        now = DateTime(2026, 1, 1).add(Duration(seconds: i));
        await cache.write('k$i', ok);
      }
      final raw = jsonDecode(
        (await prefs.readString(TranslationIndexCache.prefsKey))!,
      ) as Map<String, Object?>;
      expect(raw.length, 120);
      expect(raw.containsKey('k4'), isFalse);
      expect(raw.containsKey('k5'), isTrue);
    });

    test('脏数据当空表', () async {
      await prefs.writeString(TranslationIndexCache.prefsKey, '{bad');
      expect(await cache.read('k'), isNull);
    });
  });

  group('磁盘缓存', () {
    late Directory dir;
    late TranslationDiskCache disk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('translate-cache-');
      disk = TranslationDiskCache(directory: dir.path);
    });
    tearDown(() => dir.delete(recursive: true));

    test('keyFor 是 sha1(v2|title|artist|duration) 全小写', () async {
      final key = TranslationDiskCache.keyFor(
        title: 'Hello',
        artist: 'Adele',
        duration: 300,
      );
      expect(key.length, 40);
      expect(key, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(
        key,
        TranslationDiskCache.keyFor(
          title: 'hello',
          artist: 'adele',
          duration: 300,
        ),
      );
    });

    // 上一条只钉了「大小写不敏感」的自洽性：把 `v2|` 前缀整个删掉、或改成
    // 歌词那套不加前缀的拼法，它照样会绿。这条用 Node 生成的黄金值钉住逐字节口径。
    // 黄金值来源：
    //   node -e "const c=require('crypto');const h=s=>c.createHash('sha1')
    //     .update(s,'utf8').digest('hex');
    //     console.log(h('v2|十年|陈奕迅|300'.toLowerCase()))"
    test('keyFor 与 Node 的 sha1 逐字节一致（v2 前缀 + 整体 lowercase）', () async {
      expect(
        TranslationDiskCache.keyFor(title: '十年', artist: '陈奕迅', duration: 300),
        '893a0280020ef81f7d91b6931050334378880601',
      );
      expect(
        TranslationDiskCache.keyFor(
          title: 'Yesterday',
          artist: 'The Beatles',
          duration: 125,
        ),
        '7553bee837ba00773c349f9217452b41fbb436a8',
      );
      // 大小写差异只影响「谁被 lower」，哈希输入是同一个字符串。
      expect(
        TranslationDiskCache.keyFor(
          title: 'HELLO',
          artist: 'ADELE',
          duration: 300,
        ),
        '03c62dcf09f1cb341536ab32b87c74552c71ef1c',
      );
    });

    test('往返 + TTL + allowStale', () async {
      final key = TranslationDiskCache.keyFor(
        title: 'a',
        artist: 'b',
        duration: 1,
      );
      await disk.write(key, ok);
      expect((await disk.read(key))!.translated, '[00:01]A');
      File(
        '${dir.path}/$key.json',
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      expect(await disk.read(key), isNull);
      expect((await disk.read(key, allowStale: true))!.translated, '[00:01]A');
    });

    test('stale 返回时 source 追加「（离线缓存）」由调用方负责，缓存本身不改字符串', () async {
      final key = TranslationDiskCache.keyFor(
        title: 'a',
        artist: 'b',
        duration: 1,
      );
      await disk.write(key, ok);
      File(
        '${dir.path}/$key.json',
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));
      final stale = await disk.read(key, allowStale: true);
      expect(stale!.source, '网易云译文库（人工翻译）');
    });
  });
}
