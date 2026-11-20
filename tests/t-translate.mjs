/**
 * t-translate.mjs —— 译文获取的两条路径（本地代理 / 静态部署机翻兜底）
 *
 * 运行：node tests/t-translate.mjs
 *
 * 这里只测「请求编排」：代理可用时拿人工译文；代理不可用（返回 HTML）时改用
 * MyMemory 机翻，结果按行对回展示行，并写进本地缓存。真实的网易译文解析在
 * 服务端 music-api.ts 里，不在这个模块的职责内。
 */

const root = new URL('../', import.meta.url);const store = new Map();
global.window = {
  localStorage: {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
  },
};

let proxyMode = 'html'; // 'html' | 'json'
let machineHits = 0;
const realFetch = global.fetch;
global.fetch = async (url, init) => {
  const href = String(url);
  if (href.startsWith('api/translate')) {
    if (proxyMode === 'json') {
      return new Response(JSON.stringify({
        status: 'ok',
        translatedLyrics: '[00:00.00]人工译文',
        originalLyrics: '[00:00.00]Original',
        source: '网易云译文库',
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response('<!doctype html><html></html>', { status: 200, headers: { 'content-type': 'text/html' } });
  }
  if (href.includes('api.mymemory.translated.net')) {
    machineHits += 1;
    const query = new URL(href).searchParams.get('q') || '';
    const lines = query.split('\n');
    return new Response(JSON.stringify({
      responseStatus: 200,
      responseData: { translatedText: lines.map((_, index) => `译文${index + 1}`).join('\n') },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  return realFetch(url, init);
};

const { fetchTranslation } = await import(new URL('src/lib/translate-source.js', root).href);

const track = { id: 't1', title: 'Yellow', artist: 'Coldplay', duration: 266, lyrics: '', lyricsPlain: '' };
const lines = [{ text: 'Look at the stars' }, { text: 'Look how they shine for you' }, { text: '' }];

let failed = 0;
const check = (label, condition) => {
  if (condition) {
    console.log(`ok  ${label}`);
  } else {
    console.error(`FAIL ${label}`);
    failed += 1;
  }
};

// 1. 代理返回 HTML（纯静态部署）→ 机翻，且空行保持为空
const machine = await fetchTranslation(track, { useCache: true, lines });
check('静态部署走机翻', machine.status === 'ok' && machine.machine === true);
check('机翻按行对齐', machine.translatedLines?.length === 3 && machine.translatedLines[0] === '译文1' && machine.translatedLines[2] === '');
check('机翻只请求一次', machineHits === 1);

// 2. 同一首歌再取：命中 localStorage 缓存，不再打接口
const cached = await fetchTranslation(track, { useCache: true, lines });
check('二次命中缓存', cached.status === 'ok' && machineHits === 1);

// 3. 代理可用（开发服务器）→ 走人工译文，不碰机翻
proxyMode = 'json';
const human = await fetchTranslation({ ...track, id: 't2', title: 'Fix You' }, { useCache: true, lines });
check('代理可用时用人工译文', human.status === 'ok' && human.translatedLyrics === '[00:00.00]人工译文' && !human.machine);
check('人工路径不碰机翻', machineHits === 1);

console.log(failed === 0 ? '\n通过' : `\n失败 ${failed} 项`);
process.exit(failed === 0 ? 0 : 1);
