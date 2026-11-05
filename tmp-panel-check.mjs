import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = 9370;
const width = Number(process.argv[2] || 1280);
const height = Number(process.argv[3] || 900);
const out = process.argv[4] || 'panel.png';
const openSheet = process.argv[5] === 'sheet';
const edge = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--user-data-dir=C:/Users/Administrator/AppData/Local/Temp/cdp-panel-profile', '--no-first-run', '--disable-gpu', 'about:blank'], { stdio: 'ignore' });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function getWs() {
  for (let i = 0; i < 60; i += 1) {
    try { const res = await fetch(`http://127.0.0.1:${PORT}/json/new?about:blank`, { method: 'PUT' }); return (await res.json()).webSocketDebuggerUrl; } catch { await wait(250); }
  }
  throw new Error('no cdp');
}
const ws = new WebSocket(await getWs());
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); } };
const send = (method, params = {}) => new Promise((resolve, reject) => { id += 1; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params })); });
await send('Page.enable'); await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: width < 600, screenWidth: width, screenHeight: height });
await send('Page.navigate', { url: 'http://localhost:5173/' });
await wait(3200);
if (openSheet) {
  await send('Runtime.evaluate', { expression: `document.querySelector('.controls__queue').click(); 'open'`, returnByValue: true });
  await wait(700);
}
const info = await send('Runtime.evaluate', { expression: `({ hint: document.querySelector('.panel__hint')?.textContent ?? null, closeBtn: !!document.querySelector('.panel__close') })`, returnByValue: true });
console.log(JSON.stringify(info.result.value));
const shot = await send('Page.captureScreenshot', { format: 'png' });
writeFileSync(`C:/Users/Administrator/WorkBuddy/2026-11-02-09-29-28/music-player/${out}`, Buffer.from(shot.data, 'base64'));
ws.close(); edge.kill(); process.exit(0);
