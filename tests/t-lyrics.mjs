/**
 * t-lyrics.mjs —— 客户端歌词编排：四源链路 / LRCLIB 兜底 / 缓存纪元
 *
 * 运行（先打一个把 TS 依赖编进去的包，Node 不认 .ts）：
 *   node_modules\.bin\esbuild.cmd src/lib/lyrics-source.js --bundle --format=esm --platform=node --outfile=.cache/test/lyrics-source.bundle.mjs
 *   node tests/t-lyrics.mjs
 *
 * 本文件跑的是**相对代理**（本地 / 静态兼容模式）：代理先问，代理没词 /
 * fallback 后才直连网易云 → LRCLIB，因此 LRCLIB 在这里仍是最后一手。
 * 线上绝对代理的「LRCLIB 真第一」由 t-lyrics-remote.mjs 单独钉。
 * 真实的上游解析在服务端 music-api.ts 与 Dart 端各自的测试里。
 */

const root = new URL('../', import.meta.url);
const store = new Map();
global.window = {
  localStorage: {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
  },
};
// Node 22 自带只读的 navigator，只能用 defineProperty 覆盖。
Object.defineProperty(globalThis, 'navigator', {
  value: { onLine: true },
  configurable: true,
});

const V4 = 'light-music.lyrics-cache.v4';
const V3 = 'light-music.lyrics-cache.v3';
const V2 = 'light-music.lyrics-cache.v2';
const V1 = 'light-music.lyrics-cache.v1';

let mode = 'static'; // 'static'（代理端点不存在，返回 HTML）| 'proxy' | 'proxy-fallback' | 'proxy-miss'
let neteaseSongs = [];
let neteaseLyric = '';
let lrclibHit = null;
const calls = [];

global.fetch = async (url) => {
  const href = String(url);
  calls.push(href);

  if (href.startsWith('api/lyrics')) {
    if (mode === 'proxy') {
      return new Response(JSON.stringify({
        status: 'ok',
        syncedLyrics: '[00:01]代理取回的网易云词',
        plainLyrics: '',
        source: '网易云音乐',
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    if (mode === 'proxy-fallback') {
      // 线上中转只跑汽水 / 酷狗：两家都没词时带 fallback，客户端要继续直连
      return new Response(JSON.stringify({ status: 'not-found', fallback: true }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (mode === 'proxy-miss') {
      // 本地代理四源全查完，确定没词：客户端不应再走直连
      return new Response(JSON.stringify({ status: 'not-found' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    // 静态托管：没有这个端点，返回的是 index.html（旧前端就是这样识别「没有代理」的）
    return new Response('<!doctype html><html><body>app</body></html>', {
      status: 200,
      headers: { 'content-type': 'text/html' },
    });
  }
  if (href.startsWith('https://music.163.com/api/search/get')) {
    return new Response(JSON.stringify({ result: { songs: neteaseSongs } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  if (href.startsWith('https://music.163.com/api/song/lyric')) {
    return new Response(JSON.stringify({ lrc: { lyric: neteaseLyric } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  if (href.startsWith('https://lrclib.net/api/') && lrclibHit && href.includes('/get?')) {
    return new Response(JSON.stringify(lrclibHit), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }
  return new Response('', { status: 404 });
};

const bundleUrl = process.env.LYRICS_BUNDLE
  ? new URL(process.env.LYRICS_BUNDLE, import.meta.url)
  : new URL('.cache/test/lyrics-source.bundle.mjs', root);
const { matchLyrics, lyricsOriginOf, lyricsOriginLabel, clearLyricsCache } = await import(
  bundleUrl.href
);

let failed = 0;
const check = (label, condition, extra = '') => {
  if (condition) {
    console.log(`ok  ${label}`);
  } else {
    console.error(`FAIL ${label}${extra ? ` ${extra}` : ''}`);
    failed += 1;
  }
};

const reset = ({ staticMode = true } = {}) => {
  store.clear();
  calls.length = 0;
  mode = staticMode ? 'static' : 'proxy';
  neteaseSongs = [];
  neteaseLyric = '';
  lrclibHit = null;
};

const song = {
  id: 1,
  name: '十年',
  duration: 300000,
  artists: [{ name: '陈奕迅' }],
};

const track = { id: 't1', title: '十年', artist: '陈奕迅', duration: 300, lyrics: '', lyricsPlain: '' };

// 1) 静态部署 + 网易云命中：LRCLIB 一次都不该被请求
reset();
neteaseSongs = [song];
neteaseLyric = '[00:00.00] 作词 : 甲\n[00:00.50] 作曲 : 乙\n[00:15.54]如果那两个字没有颤抖';
const first = await matchLyrics(track);
check('网易云命中 → ok', first.status === 'ok', JSON.stringify(first));
check('source 是网易云音乐', first.source === '网易云音乐');
check('开头署名已剥掉', first.syncedLyrics.startsWith('[00:15.54]如果那两个字没有颤抖'), first.syncedLyrics?.slice(0, 40));
check('LRCLIB 未被请求', !calls.some((href) => href.includes('lrclib.net')));
check('先搜歌再取词', calls.filter((href) => href.includes('music.163.com')).length === 2);
const v4 = JSON.parse(store.get(V4));
check('v4 缓存记下来源', v4['十年|陈奕迅|300']?.src === '网易云音乐', JSON.stringify(v4));

const cachedCalls = calls.length;
const second = await matchLyrics(track);
check('二次匹配走 v4 缓存', second.status === 'ok' && second.syncedLyrics === first.syncedLyrics);
check('二次匹配不再联网', calls.length === cachedCalls);
check('来源 id 归一', lyricsOriginOf(second.source) === 'netease');
check('来源文案', lyricsOriginLabel('netease') === '网易云音乐' && lyricsOriginLabel('lrclib') === 'LRCLIB线上库');
check('汽水 / 酷狗来源文案', lyricsOriginLabel('qishui') === '汽水音乐' && lyricsOriginLabel('kugou') === '酷狗音乐');
check('汽水 / 酷狗来源 id', lyricsOriginOf('汽水音乐') === 'qishui' && lyricsOriginOf('酷狗音乐') === 'kugou');

// 2) 代理可用：交给服务端统一按四源链路查，前端不直连
reset({ staticMode: false });
const proxied = await matchLyrics({ ...track, id: 't2', title: 'Yellow', artist: 'Coldplay', duration: 266 });
check('代理命中 → ok', proxied.status === 'ok');
check('来源透传', proxied.source === '网易云音乐');
check('只打同源代理', calls.length === 1 && calls[0].startsWith('api/lyrics'));

// 2b) 相对代理 fallback（本地兼容）：未命中 → 客户端继续网易云 → LRCLIB
reset({ staticMode: false });
mode = 'proxy-fallback';
neteaseSongs = [];
lrclibHit = { syncedLyrics: '[00:15.54]本地代理未命中后的 LRCLIB 词', plainLyrics: '' };
const afterProxyMiss = await matchLyrics({ ...track, id: 't2b', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('代理 fallback → 继续直连命中', afterProxyMiss.status === 'ok' && afterProxyMiss.source === 'LRCLIB', JSON.stringify(afterProxyMiss));
check('相对代理 fallback 后先网易云后 LRCLIB', calls.findIndex((h) => h.includes('music.163.com')) < calls.findIndex((h) => h.includes('lrclib.net')));

// 2c) 本地代理明确 not-found（无 fallback）→ 不应再走直连
reset({ staticMode: false });
mode = 'proxy-miss';
const proxyRetired = await matchLyrics({ ...track, id: 't2c', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('代理明确未命中 → not-found', proxyRetired.status === 'not-found');
check('代理明确未命中不直连', calls.length === 1 && calls[0].startsWith('api/lyrics'));

// 3) 相对代理 / 静态部署：代理没词 → 网易云没歌 → LRCLIB 兜底
reset();
neteaseSongs = []; // 认不到歌
lrclibHit = { syncedLyrics: '[00:15.54]LRCLIB 的词', plainLyrics: '' };
const fallback = await matchLyrics({ ...track, id: 't3', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('LRCLIB 兜底 → ok', fallback.status === 'ok', JSON.stringify(fallback));
check('来源是 LRCLIB', fallback.source === 'LRCLIB');
check('相对代理下先问网易云再问 LRCLIB', calls.findIndex((h) => h.includes('music.163.com')) < calls.findIndex((h) => h.includes('lrclib.net')));
check('静态部署不直连汽水 / 酷狗', !calls.some((h) => h.includes('qishui') || h.includes('kugou')));

// 4) 旧纪元 v3 → v2 → v1：新源都没词才拿出来，并转正到 v4
reset();
store.set(V3, JSON.stringify({
  'zzz 不存在的歌|nobody|222': { s: '[00:03]四源时代的词', p: '', src: '酷狗音乐', at: Date.now() },
}));
store.set(V2, JSON.stringify({
  'zzz 不存在的歌|nobody|222': { s: '[00:02]网易云时代的词', p: '', src: '网易云音乐', at: Date.now() },
}));
store.set(V1, JSON.stringify({
  'zzz 不存在的歌|nobody|222': { s: '[00:01]LRCLIB 时代的词', p: 'LRCLIB 时代的词', src: 'LRCLIB', at: Date.now() },
}));
const legacy = await matchLyrics({ ...track, id: 't4', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('旧词兜底 → ok', legacy.status === 'ok' && legacy.syncedLyrics === '[00:03]四源时代的词', JSON.stringify(legacy));
check('v3 优先于 v2 / v1', legacy.source === '酷狗音乐');
const v4AfterLegacy = JSON.parse(store.get(V4));
check('旧词转正到 v4', v4AfterLegacy['zzz 不存在的歌|nobody|222']?.src === '酷狗音乐');
const againCalls = calls.length;
const legacyAgain = await matchLyrics({ ...track, id: 't4', title: 'Zzz 不存在的歌', artist: 'Nobody', duration: 222 });
check('转正后不再联网', legacyAgain.status === 'ok' && calls.length === againCalls);

// 5) 旧纪元的「未找到」不挡新源：网易云能翻案
reset();
store.set(V3, JSON.stringify({
  '十年|陈奕迅|300': { miss: true, at: Date.now() },
}));
store.set(V2, JSON.stringify({
  '十年|陈奕迅|300': { miss: true, at: Date.now() },
}));
store.set(V1, JSON.stringify({
  '十年|陈奕迅|300': { miss: true, at: Date.now() },
}));
neteaseSongs = [song];
neteaseLyric = '[00:15.54]如果那两个字没有颤抖';
const reprieved = await matchLyrics(track);
check('旧 miss 不挡路 → 网易云命中', reprieved.status === 'ok' && reprieved.source === '网易云音乐', JSON.stringify(reprieved));

// 6) 清缓存四代一起清
clearLyricsCache();
check('clearLyricsCache 清 v1 + v2 + v3 + v4', !store.has(V1) && !store.has(V2) && !store.has(V3) && !store.has(V4));

if (failed > 0) {
  console.error(`\n${failed} 条失败`);
  process.exit(1);
}
console.log('\n全部通过');
