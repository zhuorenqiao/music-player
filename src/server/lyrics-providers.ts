/**
 * lyrics-providers.ts —— 汽水音乐 / 酷狗音乐的取词（服务端专用）
 *
 * 浏览器直连不了这两家（都没有 CORS 头，酷狗搜索还是 http-only 的老域名），
 * 所以只在 Vite 开发代理里实现；静态发布仍然落到 LRCLIB。
 *
 * 两家都复用 netease-match 的认歌规则（pickNetEaseSong），不另造一套：
 *   - 汽水：`luna/pc/sug` 匿名可用；歌词在分享页的 `_ROUTER_DATA` 里，
 *     分享页必须用移动端 UA，桌面 UA 拿到的是没有歌词的空壳；
 *   - 酷狗：`mobiles.kugou.com` 搜歌 → `krcs.kugou.com` 换候选 →
 *     `lyrics.kugou.com` 下载 base64 LRC。全部走 HTTPS（Android 9+ 禁明文）。
 */

import { looksSynced, pickNetEaseSong, stripLeadingCredits, type NetEaseSong } from '../lib/netease-match';

export interface ProviderLyrics {
  status: 'ok';
  syncedLyrics: string;
  plainLyrics: string;
  source: string;
  trackName: string;
  artistName: string;
  duration: number;
  /** 与 `CacheEntry` 的索引签名对齐：代理层会把结果原样落盘、原样返回。 */
  [key: string]: unknown;
}

const UPSTREAM_HEADERS = {
  Accept: 'application/json',
  'User-Agent': 'light-music-react/1.0 (+vite dev middleware)',
};

const MOBILE_HEADERS = {
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  'User-Agent':
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
};

const SUG_TIMEOUT = 6_000;
const PAGE_TIMEOUT = 10_000;
const KUGOU_SEARCH_TIMEOUT = 6_000;
const KUGOU_CANDIDATE_TIMEOUT = 6_000;
const KUGOU_DOWNLOAD_TIMEOUT = 6_000;

const QISHUI_SUG = 'https://api.qishui.com/luna/pc/sug';
const QISHUI_SHARE = 'https://music.douyin.com/qishui/share/track';
const KUGOU_SEARCH = 'https://mobiles.kugou.com/api/v3/search/song';
const KUGOU_CANDIDATE = 'https://krcs.kugou.com/search';
const KUGOU_DOWNLOAD = 'https://lyrics.kugou.com/download';

type JsonRecord = Record<string, unknown>;

function asRecord(value: unknown): JsonRecord | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonRecord) : null;
}

async function fetchJson(url: string, timeoutMs: number): Promise<unknown | null> {
  try {
    const response = await fetch(url, {
      headers: UPSTREAM_HEADERS,
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) return null;
    return (await response.json()) as unknown;
  } catch {
    return null;
  }
}

async function fetchText(url: string, timeoutMs: number, headers: Record<string, string>): Promise<string | null> {
  try {
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(timeoutMs) });
    if (!response.ok) return null;
    return await response.text();
  } catch {
    return null;
  }
}

function formatTag(milliseconds: number): string {
  const total = Math.max(0, Math.round(milliseconds));
  const minutes = Math.floor(total / 60_000);
  const seconds = Math.floor(total / 1000) % 60;
  const centis = Math.floor((total % 1000) / 10);
  return `[${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}.${String(centis).padStart(2, '0')}]`;
}

// -- 汽水音乐 ---------------------------------------------------------------

interface QishuiCandidate {
  song: NetEaseSong;
  synced: string;
  trackName: string;
  artistName: string;
  duration: number;
}

/** 匿名建议搜索，返回候选 track id。 */
async function searchQishuiIds(keyword: string): Promise<string[]> {
  const searchId = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
  const params = new URLSearchParams({
    aid: '386088',
    app_name: 'luna_pc',
    device_id: '3753066532709850',
    iid: '3753066532713946',
    version_name: '3.5.2',
    version_code: '30050200',
    device_platform: 'windows',
    device_type: 'Windows',
    q: keyword,
    cursor: '0',
    search_id: searchId,
    search_method: 'input',
    sug_scene: 'main',
    sug_search_id: searchId,
  });
  const json = asRecord(await fetchJson(`${QISHUI_SUG}?${params}`, SUG_TIMEOUT));
  const sugs = json?.sugs;
  if (!Array.isArray(sugs)) return [];
  const ids: string[] = [];
  for (const raw of sugs) {
    const item = asRecord(raw);
    if (item?.content_type !== 'track') continue;
    const track = asRecord(asRecord(item.entity)?.track);
    const id = track?.id;
    if (typeof id === 'string' && id && !ids.includes(id)) ids.push(id);
    if (ids.length >= 3) break;
  }
  return ids;
}

function extractRouterData(html: string): JsonRecord | null {
  const marker = html.indexOf('_ROUTER_DATA');
  if (marker < 0) return null;
  const start = html.indexOf('{', marker);
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < html.length; index += 1) {
    const char = html[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') {
      inString = true;
      continue;
    }
    if (char === '{') depth += 1;
    else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        try {
          return asRecord(JSON.parse(html.slice(start, index + 1)) as unknown);
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}

function findRecord(node: unknown, key: string): JsonRecord | null {
  const record = asRecord(node);
  if (record) {
    const value = asRecord(record[key]);
    if (value) return value;
    for (const child of Object.values(record)) {
      const found = findRecord(child, key);
      if (found) return found;
    }
    return null;
  }
  if (Array.isArray(node)) {
    for (const child of node) {
      const found = findRecord(child, key);
      if (found) return found;
    }
  }
  return null;
}

async function loadQishuiCandidate(id: string, songId: number, timeoutMs: number): Promise<QishuiCandidate | null> {
  if (timeoutMs <= 0) return null;
  const html = await fetchText(
    `${QISHUI_SHARE}?${new URLSearchParams({ track_id: id })}`,
    timeoutMs,
    MOBILE_HEADERS,
  );
  if (!html) return null;
  const data = extractRouterData(html);
  const option = data ? findRecord(data, 'audioWithLyricsOption') : null;
  if (!option) return null;

  const trackName = typeof option.trackName === 'string' ? option.trackName.trim() : '';
  if (!trackName) return null;
  const artistName = typeof option.artistName === 'string' ? option.artistName.trim() : '';
  const duration = typeof option.duration === 'number' && Number.isFinite(option.duration) ? option.duration : 0;
  const lyrics = asRecord(option.lyrics);
  const sentences = lyrics?.sentences;
  if (!Array.isArray(sentences) || sentences.length === 0) return null;

  const lines: string[] = [];
  for (const raw of sentences) {
    const sentence = asRecord(raw);
    if (!sentence) continue;
    const text = typeof sentence.text === 'string' ? sentence.text.trim() : '';
    if (!text) continue;
    const startMs = typeof sentence.startMs === 'number' && Number.isFinite(sentence.startMs) ? sentence.startMs : 0;
    lines.push(`${formatTag(startMs)}${text}`);
  }
  if (lines.length === 0) return null;

  const cleaned = stripLeadingCredits(lines.join('\n'));
  if (!cleaned.trim()) return null;

  return {
    song: {
      id: songId,
      name: trackName,
      durationMs: duration * 1000,
      artists: artistName ? [artistName] : [],
      alias: [],
    },
    synced: cleaned,
    trackName,
    artistName,
    duration,
  };
}

export async function fetchQishuiLyrics(trackName: string, artistName: string, duration: number): Promise<ProviderLyrics | null> {
  if (!trackName.trim()) return null;
  // 整家 16s 预算：它只是链路上的一环，不能把整次匹配的等待吃光。
  const deadline = Date.now() + 16_000;
  const keywords = [artistName ? `${trackName} ${artistName}` : '', trackName].filter(Boolean);
  const ids: string[] = [];
  for (const keyword of keywords) {
    if (ids.length >= 3 || Date.now() >= deadline) break;
    const found = await searchQishuiIds(keyword);
    for (const id of found) {
      if (!ids.includes(id)) ids.push(id);
      if (ids.length >= 3) break;
    }
  }
  if (ids.length === 0) return null;

  const candidates: QishuiCandidate[] = [];
  for (let index = 0; index < ids.length; index += 1) {
    if (Date.now() >= deadline) break;
    const remaining = deadline - Date.now();
    const candidate = await loadQishuiCandidate(ids[index], index + 1, Math.min(PAGE_TIMEOUT, remaining));
    if (candidate) candidates.push(candidate);
  }
  if (candidates.length === 0) return null;

  const picked = pickNetEaseSong(
    candidates.map((candidate) => candidate.song),
    { trackName, artistName, duration, strict: artistName.length > 0 },
  );
  if (!picked) return null;
  const match = candidates.find((candidate) => candidate.song.id === picked.id);
  if (!match) return null;
  /**
   * 时长差太大的「同名 + 同歌手」基本是另一种版本（翻唱、DJ 版、剪辑版）：
   * 汽水的建议结果里常有这种条目，strict 只校验歌手，拦不住。宁可让给酷狗，
   * 也不把别人的词贴到当前曲目上。
   */
  if (duration > 0 && match.duration > 0 && Math.abs(match.duration - duration) > 20) {
    return null;
  }

  return {
    status: 'ok',
    syncedLyrics: match.synced,
    plainLyrics: '',
    source: '汽水音乐',
    trackName: match.trackName,
    artistName: match.artistName,
    duration: match.duration,
  };
}

// -- 酷狗音乐 ---------------------------------------------------------------

interface KugouSong extends NetEaseSong {
  hash: string;
}

interface KugouCandidate {
  id: string;
  accessKey: string;
  song: KugouSong;
}

function numberValue(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

async function searchKugou(keyword: string): Promise<KugouSong[]> {
  const params = new URLSearchParams({
    format: 'json',
    keyword,
    page: '1',
    pagesize: '20',
    showtype: '1',
  });
  const json = asRecord(await fetchJson(`${KUGOU_SEARCH}?${params}`, KUGOU_SEARCH_TIMEOUT));
  const info = asRecord(json?.data)?.info;
  if (!Array.isArray(info)) return [];
  const songs: KugouSong[] = [];
  for (const raw of info) {
    const item = asRecord(raw);
    if (!item) continue;
    const name = typeof item.songname === 'string' ? item.songname.trim() : '';
    const artist = typeof item.singername === 'string' ? item.singername.trim() : '';
    const hash = typeof item.hash === 'string' ? item.hash : '';
    if (!name || !hash) continue;
    songs.push({
      id: songs.length + 1,
      name,
      durationMs: numberValue(item.duration) * 1000,
      artists: artist ? [artist] : [],
      alias: [],
      hash,
    });
  }
  return songs;
}

async function kugouCandidates(song: KugouSong): Promise<KugouCandidate[]> {
  const params = new URLSearchParams({
    ver: '1',
    man: 'yes',
    client: 'mobi',
    keyword: song.name,
    duration: String(Math.round(song.durationMs / 1000)),
    hash: song.hash,
  });
  const json = asRecord(await fetchJson(`${KUGOU_CANDIDATE}?${params}`, KUGOU_CANDIDATE_TIMEOUT));
  const items = json?.candidates;
  if (!Array.isArray(items)) return [];
  const candidates: KugouCandidate[] = [];
  for (const raw of items) {
    const item = asRecord(raw);
    if (!item) continue;
    const id = typeof item.id === 'string' ? item.id : typeof item.id === 'number' ? String(item.id) : '';
    const accessKey = typeof item.accesskey === 'string' ? item.accesskey : '';
    const name = typeof item.song === 'string' ? item.song.trim() : '';
    const singer = typeof item.singer === 'string' ? item.singer.trim() : '';
    if (!id || !accessKey || !name) continue;
    candidates.push({
      id,
      accessKey,
      song: {
        id: candidates.length + 1,
        name,
        durationMs: numberValue(item.duration),
        artists: singer ? [singer] : [],
        alias: [],
        hash: song.hash,
      },
    });
  }
  return candidates;
}

function dropKugouMeta(raw: string): string {
  const lines = raw.replace(/^\uFEFF/, '').split(/\r?\n/);
  const meta = /^\[(?:id|ar|ti|by|hash|al|sign|qq|total|offset|length)\s*:/i;
  return lines.filter((line) => !meta.test(line.trim())).join('\n');
}

/**
 * 酷狗 LRC 的第一行常是 `[00:00.00]晴天 - 周杰伦 (Jay Chou)`：带时间轴，会被当成
 * 第一句歌词。只认「歌名和歌手都在同一行、中间有空白破折号」这一种形态。
 */
function stripLeadingTitleLine(lyric: string, trackName: string, artistName: string): string {
  if (!trackName || !artistName) return lyric;
  const lines = lyric.split(/\r?\n/);
  const tag = /^\s*\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]\s*/;
  let first = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index].replace(tag, '').trim()) {
      first = index;
      break;
    }
  }
  if (first < 0) return lyric;
  const text = lines[first].replace(tag, '').trim();
  if (!/\s[-–—]\s/.test(text)) return lyric;
  const squash = (value: string) => value.toLowerCase().replace(/\s+/g, '');
  const normalized = squash(text);
  if (!normalized.includes(squash(trackName)) || !normalized.includes(squash(artistName))) {
    return lyric;
  }
  lines.splice(first, 1);
  return lines.join('\n');
}

async function downloadKugou(candidate: KugouCandidate): Promise<ProviderLyrics | null> {
  const params = new URLSearchParams({
    ver: '1',
    client: 'pc',
    fmt: 'lrc',
    charset: 'utf8',
    id: candidate.id,
    accesskey: candidate.accessKey,
  });
  const json = asRecord(await fetchJson(`${KUGOU_DOWNLOAD}?${params}`, KUGOU_DOWNLOAD_TIMEOUT));
  const content = typeof json?.content === 'string' ? json.content : '';
  if (!content) return null;
  let raw = '';
  try {
    raw = Buffer.from(content, 'base64').toString('utf8');
  } catch {
    return null;
  }
  const body = stripLeadingCredits(
    stripLeadingTitleLine(
      dropKugouMeta(raw),
      candidate.song.name,
      candidate.song.artists[0] ?? '',
    ),
  );
  if (!body.trim()) return null;
  const synced = looksSynced(body);
  return {
    status: 'ok',
    syncedLyrics: synced ? body : '',
    plainLyrics: synced ? '' : body,
    source: '酷狗音乐',
    trackName: candidate.song.name,
    artistName: candidate.song.artists[0] ?? '',
    duration: candidate.song.durationMs / 1000,
  };
}

export async function fetchKugouLyrics(trackName: string, artistName: string, duration: number): Promise<ProviderLyrics | null> {
  if (!trackName.trim()) return null;
  // 整家 12s 预算（与 Flutter 侧一致），保证它不会把后面的网易云 / LRCLIB 堵死。
  const deadline = Date.now() + 12_000;
  const keyword = [trackName, artistName].filter(Boolean).join(' ');
  const songs = await searchKugou(keyword);
  if (songs.length === 0) return null;

  const remaining = [...songs];
  let attempts = 0;
  while (remaining.length > 0 && attempts < 3 && Date.now() < deadline) {
    const picked = pickNetEaseSong(remaining, {
      trackName,
      artistName,
      duration,
      strict: artistName.length > 0,
    });
    if (!picked) break;
    const index = remaining.findIndex((song) => song.id === picked.id);
    if (index < 0) break;
    const song = remaining[index];
    remaining.splice(index, 1);
    attempts += 1;

    const candidates = await kugouCandidates(song);
    const pending = [...candidates];
    let candidateAttempts = 0;
    while (pending.length > 0 && candidateAttempts < 2 && Date.now() < deadline) {
      const best = pickNetEaseSong(
        pending.map((candidate) => candidate.song),
        {
          trackName: song.name,
          artistName: song.artists[0] ?? '',
          duration: Math.round(song.durationMs / 1000),
          strict: song.artists.length > 0,
        },
      );
      if (!best) break;
      const candidateIndex = pending.findIndex((candidate) => candidate.song.id === best.id);
      if (candidateIndex < 0) break;
      const candidate = pending[candidateIndex];
      pending.splice(candidateIndex, 1);
      candidateAttempts += 1;
      const record = await downloadKugou(candidate);
      if (record) return record;
    }
  }
  return null;
}
