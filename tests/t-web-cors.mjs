import { chromium } from 'playwright';

const proxy = 'https://caidan-1-d9glqugbu5be15778-1316655607.ap-shanghai.app.tcloudbase.com/api/lyrics';
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage();
const events = [];
page.on('console', (msg) => events.push(`console:${msg.type()}:${msg.text()}`));
page.on('pageerror', (error) => events.push(`pageerror:${String(error)}`));
page.on('requestfailed', (req) => events.push(`requestfailed:${req.url()}:${req.failure()?.errorText}`));
await page.goto('http://127.0.0.1:5123/', { waitUntil: 'domcontentloaded' });

const result = await page.evaluate(async (base) => {
  try {
    const params = new URLSearchParams({ track_name: '孤勇者', artist_name: '陈奕迅', duration: '256' });
    const response = await fetch(`${base}?${params.toString()}`, {
      headers: { Accept: 'application/json' },
      credentials: 'omit',
      cache: 'no-store',
    });
    const body = await response.json();
    return {
      ok: true,
      status: response.status,
      acao: response.headers.get('access-control-allow-origin'),
      source: body.source,
      trackName: body.trackName,
      firstLine: body.syncedLyrics?.split('\n')[0] ?? '',
    };
  } catch (error) {
    return { ok: false, error: String(error) };
  }
}, proxy);

console.log(JSON.stringify({ result, events }, null, 2));
await browser.close();
