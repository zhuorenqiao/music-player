/**
 * t-lyrics-remote.mjs —— 线上绝对代理下的 LRCLIB 第一优先
 *
 * 与 t-lyrics.mjs 分开跑：LOCAL_PROXY 在模块加载时就定死，必须在 import 之前
 * 设 window.__LIGHT_MUSIC_LYRICS_PROXY__。线上中转只跑汽水、酷狗，LRCLIB
 * 必须由客户端先直连，本文件钉住这条顺序。
 */

const root = new URL('../', import.meta.url);
const store = new Map();
global.window = {
  __LIGHT_MUSIC_LYRICS_PROXY__: 'https://relay.example.com/api/lyrics',
  localStorage: {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
  },
};
Object.defineProperty(globalThis, 'navigator', {
  value: { onLine: true },
  configurable: true,
});

const V4 = 'light-music.lyrics-cache.v4';
let proxyMode = 'fallback'; // 'fallback' | 'qishui'
let neteaseHit = false;
let lrclibHit = null;
let lrclibStatus = 404;
const calls = [];

global.fetch = async (url) => {
  const href = String(url);
  calls.push(href);

  if (href.startsWith('https://lrclib.net/api/')) {
    if (lrclibStatus !== 200) {
      return new Response('', { status: lrclibStatus });
    }
    if (href.includes('/search?')) {
      return new Response(JSON.stringify(lrclibHit ? [lrclibHit] : []), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    return new Response(JSON.stringify(lrclibHit), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  if (href.startsWith('https://relay.example.com/api/lyrics')) {
    if (proxyMode === 'qishui') {
      return new Response(JSON.stringify({
        status: 'ok',
        syncedLyrics: '[00:01]汽水词',
        plainLyrics: '',
        source: '汽水音乐',
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response(JSON.stringify({ status: 'not-found', fallback: true }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  if (href.startsWith('https://music.163.com/api/search/get')) {
    return new Response(JSON.stringify({
      result: { songs: neteaseHit ? [{ id: 9, name: 'Zzz 不存在的歌', artists: [{ name: 'Nobody' }] }] : [] },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  if (href.startsWith('https://music.163.com/api/song/lyric')) {
    return new Response(JSON.stringify({ lrc: { lyric: '[00:15.54]网易云词' } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  return new Response('', { status: 404 });
};

const bundleUrl = new URL('.cache/test/lyrics-source.bundle.mjs', root);
const { matchLyrics, clearLyricsCache } = await import(bundleUrl.href);

let failed = 0;
const check = (label, condition, extra = '') => {
  if (condition) {
    console.log(`ok  ${label}`);
  } else {
    console.error(`FAIL ${label}${extra ? ` ${extra}` : ''}`);
    failed += 1;
  }
};

const reset = () => {
  store.clear();
  calls.length = 0;
  proxyMode = 'fallback';
  neteaseHit = false;
  lrclibHit = null;
  lrclibStatus = 404;
};

const track = { id: 'r1', title: '十年', artist: '陈奕迅', duration: 300, lyrics: '', lyricsPlain: '' };

// 1) LRCLIB 首命中：代理一次都不该被请求
reset();
lrclibStatus = 200;
lrclibHit = { syncedLyrics: '[00:15.54]LRCLIB 词', plainLyrics: '' };
const first = await matchLyrics(track);
check('LRCLIB 首命中 → ok', first.status === 'ok' && first.source === 'LRCLIB', JSON.stringify(first));
check('LRCLIB 是第一个请求源', calls[0]?.includes('lrclib.net'), calls[0]);
check('LRCLIB 命中后不请求代理', !calls.some((href) => href.includes('relay.example.com')));
const v4 = JSON.parse(store.get(V4));
check('v4 缓存记下 LRCLIB 来源', v4['十年|陈奕迅|300']?.src === 'LRCLIB', JSON.stringify(v4));

// 2) LRCLIB 没词 → 代理（汽水/酷狗）→ 网易云
reset();
proxyMode = 'fallback';
neteaseHit = true;
const second = await matchLyrics({ ...track, id: 'r2', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('LRCLIB 没词 → 网易云补位', second.status === 'ok' && second.source === '网易云音乐', JSON.stringify(second));
check(
  '线上顺序 LRCLIB → 代理 → 网易云',
  calls[0]?.includes('lrclib.net') &&
    calls.findIndex((href) => href.includes('relay.example.com')) <
      calls.findIndex((href) => href.includes('music.163.com')),
);

// 3) LRCLIB 没词、中转命中汽水：不再问网易云
reset();
proxyMode = 'qishui';
const third = await matchLyrics({ ...track, id: 'r3', title: '晴天', artist: '周杰伦', duration: 269 });
check('LRCLIB 没词 → 中转汽水命中', third.status === 'ok' && third.source === '汽水音乐', JSON.stringify(third));
check('中转命中后不请求网易云', !calls.some((href) => href.includes('music.163.com')));

// 4) LRCLIB 明确失败 → 补位都没词时，保留错误而不是「未找到」
reset();
lrclibStatus = 500;
const fourth = await matchLyrics({ ...track, id: 'r4', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('LRCLIB 失败不被改写成 not-found', fourth.status === 'error' && /限流|不可用|超时|连接/.test(fourth.message), JSON.stringify(fourth));

// 5) v4 缓存命中后不再联网
reset();
lrclibStatus = 200;
lrclibHit = { syncedLyrics: '[00:15.54]LRCLIB 词', plainLyrics: '' };
const cachedFirst = await matchLyrics({ ...track, id: 'r5', title: '十年', artist: '陈奕迅', duration: 300 });
const cachedCalls = calls.length;
const cachedSecond = await matchLyrics({ ...track, id: 'r5', title: '十年', artist: '陈奕迅', duration: 300 });
check('二次匹配走 v4 缓存', cachedSecond.status === 'ok' && cachedSecond.syncedLyrics === cachedFirst.syncedLyrics);
check('二次匹配不再联网', calls.length === cachedCalls);

clearLyricsCache();
check('clearLyricsCache 清 v4', !store.has(V4));

if (failed > 0) {
  console.error(`\n${failed} 条失败`);
  process.exit(1);
}
console.log('\n全部通过');
