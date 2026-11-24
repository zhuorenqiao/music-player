/**
 * lyrics-relay —— 线上静态网页的歌词中转（CloudBase HTTP 云函数）。
 *
 * 浏览器拿不到汽水/酷狗的响应，因为上游没有 CORS 头；这个函数把这两家跑在
 * 服务端，只对浏览器暴露 `/api/lyrics`。网易云与 LRCLIB 仍由浏览器直连，
 * 所以这里查不到时返回 `fallback: true`，客户端继续走原来的直连链路。
 *
 * 纯 fetch、无本地磁盘缓存，冷启动不依赖任何文件。
 */

import http from 'node:http';
import { fetchKugouLyrics, fetchQishuiLyrics, type ProviderLyrics } from '../../../src/server/lyrics-providers';

type LyricsPayload = {
  status: 'ok' | 'not-found';
  syncedLyrics?: string;
  plainLyrics?: string;
  source?: string;
  trackName?: string;
  artistName?: string;
  duration?: number;
  fallback?: boolean;
};

async function findLyrics(
  trackName: string,
  artistName: string,
  duration: number,
): Promise<LyricsPayload> {
  const qishuiJob = fetchQishuiLyrics(trackName, artistName.trim(), duration).catch(() => null);
  const kugouJob = fetchKugouLyrics(trackName, artistName.trim(), duration).catch(() => null);

  let qishui: ProviderLyrics | null = null;
  try {
    qishui = await qishuiJob;
  } catch {
    qishui = null;
  }
  if (qishui) {
    return qishui;
  }

  let kugou: ProviderLyrics | null = null;
  try {
    kugou = await kugouJob;
  } catch {
    kugou = null;
  }
  if (kugou) {
    return kugou;
  }

  // 这两家都没有：让客户端继续直连网易云 → LRCLIB，不能把整个链路截断。
  return { status: 'not-found', fallback: true };
}

function sendJson(res: http.ServerResponse, statusCode: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');

  if (req.method === 'OPTIONS') {
    // 体验版环境无法把 doubao.link 加进「安全域名」白名单，网关也不会自己补
    // Access-Control-Allow-Origin；这里对一个只读的公开接口直接放开 `*`。
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Max-Age': '600',
    });
    res.end();
    return;
  }

  if (req.method === 'GET' && url.pathname === '/health') {
    sendJson(res, 200, { ok: true, service: 'lyrics-relay' });
    return;
  }

  if (req.method !== 'GET' || url.pathname !== '/api/lyrics') {
    sendJson(res, 404, { status: 'error', reason: 'not-found' });
    return;
  }

  const trackName = (url.searchParams.get('track_name') ?? '').trim().slice(0, 200);
  const artistName = (url.searchParams.get('artist_name') ?? '').trim().slice(0, 200);
  const duration = Number(url.searchParams.get('duration')) || 0;
  if (!trackName) {
    sendJson(res, 400, { status: 'error', reason: 'bad-request', message: 'track_name 不能为空' });
    return;
  }

  try {
    sendJson(res, 200, await findLyrics(trackName, artistName, duration));
  } catch {
    sendJson(res, 502, {
      status: 'error',
      reason: 'upstream',
      message: '歌词服务暂时不可用，请稍后重试',
    });
  }
});

server.listen(9000, '0.0.0.0');
