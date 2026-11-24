/**
 * t-lyrics-providers.mjs —— 服务端汽水 / 酷狗取词的回归测试（不碰真网络）
 *
 * 运行（Node 不认 .ts，先用 esbuild 打包）：
 *   node_modules\.bin\esbuild.cmd tests/t-lyrics-providers.mjs --bundle --format=esm --platform=node --outfile=.cache/test/lyrics-providers.bundle.mjs
 *   node .cache/test/lyrics-providers.bundle.mjs
 */

import { fetchKugouLyrics, fetchQishuiLyrics } from '../src/server/lyrics-providers.ts';

let mode = 'qishui';
let qishuiKeywords = [];
let qishuiId = '';
let qishuiPage = '';
let kugouSearchInfo = [];
let kugouCandidates = [];
let kugouContent = '';
let kugouCandidateCalls = 0;

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });

const routerHtml = (option) =>
  `<html><body><script>window._ROUTER_DATA = ${JSON.stringify({ loaderData: { track_page: { audioWithLyricsOption: option } } })};</script></body></html>`;

const qishuiOption = ({ name, artist, duration, sentences }) => ({
  trackName: name,
  artistName: artist,
  duration,
  lyrics: { sentences },
});

global.fetch = async (url, init = {}) => {
  const href = String(url);
  const headers = init.headers ?? {};

  if (href.startsWith('https://api.qishui.com/luna/pc/sug')) {
    const q = new URL(href).searchParams.get('q') ?? '';
    qishuiKeywords.push(q);
    if (!qishuiId) return json({ sugs: [] });
    return json({ sugs: [{ content_type: 'track', entity: { track: { id: qishuiId } } }] });
  }

  if (href.startsWith('https://music.douyin.com/qishui/share/track')) {
    if (!String(headers['User-Agent'] ?? '').includes('iPhone')) {
      return new Response('', { status: 404 });
    }
    return new Response(qishuiPage, { status: 200, headers: { 'content-type': 'text/html' } });
  }

  if (href.startsWith('https://mobiles.kugou.com/api/v3/search/song')) {
    return json({ data: { info: kugouSearchInfo } });
  }

  if (href.startsWith('https://krcs.kugou.com/search')) {
    kugouCandidateCalls += 1;
    return json({ candidates: kugouCandidates });
  }

  if (href.startsWith('https://lyrics.kugou.com/download')) {
    return json({ content: kugouContent });
  }

  return new Response('', { status: 404 });
};

let failed = 0;
const check = (label, condition, extra = '') => {
  if (condition) {
    console.log(`ok  ${label}`);
  } else {
    console.error(`FAIL ${label}${extra ? ` ${extra}` : ''}`);
    failed += 1;
  }
};

const resetQishui = (id, page) => {
  mode = 'qishui';
  qishuiKeywords = [];
  qishuiId = id;
  qishuiPage = page;
};

const resetKugou = (info, candidates, content) => {
  mode = 'kugou';
  kugouSearchInfo = info;
  kugouCandidates = candidates;
  kugouContent = content;
  kugouCandidateCalls = 0;
};

// 1) 汽水：正主命中，行级 LRC 由 startMs 生成
resetQishui(
  '1',
  routerHtml(
    qishuiOption({
      name: '孤勇者',
      artist: '陈奕迅',
      duration: 256,
      sentences: [
        { startMs: 22280, text: '都 是勇敢的' },
        { startMs: 30000, text: '你额头的伤口' },
      ],
    }),
  ),
);
const qishuiHit = await fetchQishuiLyrics('孤勇者', '陈奕迅', 256);
check('汽水正主 → ok', qishuiHit?.status === 'ok', JSON.stringify(qishuiHit));
check('汽水来源', qishuiHit?.source === '汽水音乐');
check('汽水时间轴', qishuiHit?.syncedLyrics === '[00:22.28]都 是勇敢的\n[00:30.00]你额头的伤口', qishuiHit?.syncedLyrics);
check('汽水带歌手搜索', qishuiKeywords.includes('孤勇者 陈奕迅'), JSON.stringify(qishuiKeywords));

// 2) 汽水：同名翻唱 → null（strict 必须有歌手证据）
resetQishui(
  '2',
  routerHtml(
    qishuiOption({
      name: '晴天（杰伦）',
      artist: '哇欣',
      duration: 76,
      sentences: [{ startMs: 1000, text: '故事的小黄花' }],
    }),
  ),
);
const qishuiCover = await fetchQishuiLyrics('晴天', '周杰伦', 269);
check('汽水翻唱被排除', qishuiCover === null, JSON.stringify(qishuiCover));

// 3) 酷狗：正主命中，丢元信息 / 标题行 / 署名行
const kugouLrc = [
  '[id:000]',
  '[ar:陈奕迅]',
  '[ti:十年]',
  '[by:x]',
  '[00:00.00]十年 - 陈奕迅',
  '[00:11.25]合声：乙',
  '[00:13.50]吉他：丙',
  '[00:15.54]如果那两个字没有颤抖',
].join('\n');
const base64 = Buffer.from(kugouLrc, 'utf8').toString('base64');
resetKugou(
  [{ songname: '十年', singername: '陈奕迅', duration: 300, hash: 'H1' }],
  [{ id: '9', accesskey: 'AK', song: '十年', singer: '陈奕迅', duration: 300000 }],
  base64,
);
const kugouHit = await fetchKugouLyrics('十年', '陈奕迅', 300);
check('酷狗正主 → ok', kugouHit?.status === 'ok', JSON.stringify(kugouHit));
check('酷狗来源', kugouHit?.source === '酷狗音乐');
check('酷狗清理干净', kugouHit?.syncedLyrics === '[00:15.54]如果那两个字没有颤抖', kugouHit?.syncedLyrics);

// 4) 酷狗：歌手对不上 → 不换候选、不取词
resetKugou(
  [{ songname: '十年', singername: '陈奕迅', duration: 300, hash: 'H1' }],
  [{ id: '9', accesskey: 'AK', song: '十年', singer: '陈奕迅', duration: 300000 }],
  base64,
);
const kugouWrong = await fetchKugouLyrics('十年', '刘若英', 300);
check('酷狗歌手不符 → null', kugouWrong === null, JSON.stringify(kugouWrong));
check('酷狗不做无谓取词', kugouCandidateCalls === 0, String(kugouCandidateCalls));

if (failed > 0) {
  console.error(`\n${failed} 条失败`);
  process.exit(1);
}
console.log('\n全部通过');
