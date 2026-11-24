import { chromium } from 'playwright';

const proxy = 'https://caidan-1-d9glqugbu5be15778-1316655607.ap-shanghai.app.tcloudbase.com/api/lyrics';
const cases = [
  ['孤勇者', '陈奕迅', 256],
  ['晴天', '周杰伦', 269],
  ['十年', '陈奕迅', 205],
  ['Yellow', 'Coldplay', 266],
  ['Zzz 不存在的歌', 'Nobody', 222],
];

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage();
await page.goto('http://127.0.0.1:5123/', { waitUntil: 'domcontentloaded' });
const results = await page.evaluate(async ({ base, items }) => {
  const output = [];
  for (const [track_name, artist_name, duration] of items) {
    const params = new URLSearchParams({ track_name, artist_name: artist_name || '', duration: String(duration) });
    try {
      const response = await fetch(`${base}?${params.toString()}`, {
        headers: { Accept: 'application/json' },
        credentials: 'omit',
        cache: 'no-store',
      });
      const body = await response.json();
      output.push({
        query: `${track_name} / ${artist_name}`,
        http: response.status,
        status: body.status,
        source: body.source,
        fallback: body.fallback,
        trackName: body.trackName,
        firstLine: body.syncedLyrics?.split('\n')[0] ?? '',
      });
    } catch (error) {
      output.push({ query: `${track_name} / ${artist_name}`, error: String(error) });
    }
  }
  return output;
}, { base: proxy, items: cases });
console.log(JSON.stringify(results, null, 2));
await browser.close();
