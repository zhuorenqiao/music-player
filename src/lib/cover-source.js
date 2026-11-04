/**
 * cover-source.js —— 按歌手 + 歌名自动匹配专辑封面
 *
 * 数据源：iTunes Search API（免密钥、结果自带官方专辑图）
 *
 * 两级通道：
 * 1) 同源代理 `api/cover`（tools/serve.py 提供）——服务端搜索 + 下载图片落盘，
 *    返回同源图片地址。封面直接用本地 URL，天然绕开图床防盗链、混合内容与
 *    系统代理三类问题，本地开发时首选；
 * 2) JSONP 直连 iTunes Search——纯静态部署（没有本地服务）时使用。iTunes
 *    搜索接口不开放 CORS，但仍支持 `callback` 参数，可用 script 标签查询；
 *    拿到的图片是 mzstatic CDN 的远程地址，`<img>` 加载不受 CORS 限制。
 *
 * 结果（含「没找到」）写进 localStorage，重复播放同一首歌不再联网。
 * 本模块不碰 DOM（JSONP 的 script 标签除外），只做「查询 + 归一化」。
 */

import { normalizeQuery } from './lyrics-source.js';

/** 同源代理地址（由 tools/serve.py 实现，缺失时自动降级 JSONP）。 */
const LOCAL_PROXY = 'api/cover';

/** localStorage 缓存键与容量。 */
const CACHE_KEY = 'light-music.cover-cache.v1';
const MAX_CACHE_ENTRIES = 150;

/** 缓存有效期：命中 30 天，未命中 3 天（新专辑可能上架，别让 miss 占太久）。 */
const TTL_HIT = 30 * 24 * 60 * 60 * 1000;
const TTL_MISS = 3 * 24 * 60 * 60 * 1000;

/** 代理超时（服务端要搜索 + 下载图片，给足预算）；JSONP 直连留 12s。 */
const TIMEOUT_PROXY = 40000;
const TIMEOUT_JSONP = 12000;

/** JSONP 请求的回调名计数器，避免并发冲突。 */
let jsonpSeq = 0;

/**
 * 判断当前是否在线（离线时上层直接跳过匹配）。
 * @returns {boolean}
 */
function isOnline() {
  return typeof navigator === 'undefined' || navigator.onLine !== false;
}

// ---------------------------------------------------------------------------
// localStorage 缓存
// ---------------------------------------------------------------------------

/**
 * 读缓存表（损坏时返回空表）。
 * @returns {Record<string, {u?: string, src?: string, miss?: boolean, at: number}>}
 */
function readCache() {
  try {
    const raw = window.localStorage.getItem(CACHE_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (error) {
    console.error('[cover-source] 读取封面缓存失败，已忽略：', error);
    return {};
  }
}

/**
 * 写缓存表（超限时按时间淘汰最旧的一半）。
 * @param {Record<string, object>} table 缓存表
 * @returns {void}
 */
function writeCache(table) {
  try {
    const entries = Object.entries(table);
    if (entries.length > MAX_CACHE_ENTRIES) {
      entries
        .sort((a, b) => (a[1]?.at ?? 0) - (b[1]?.at ?? 0))
        .slice(0, entries.length - MAX_CACHE_ENTRIES)
        .forEach(([key]) => delete table[key]);
    }
    window.localStorage.setItem(CACHE_KEY, JSON.stringify(table));
  } catch (error) {
    try {
      window.localStorage.removeItem(CACHE_KEY);
    } catch { /* 忽略 */ }
    console.error('[cover-source] 写入封面缓存失败：', error);
  }
}

/**
 * 查缓存。
 * @param {string} key 查询键
 * @returns {{status: string, url?: string, source?: string}|null}
 */
function readCached(key) {
  const table = readCache();
  const entry = table[key];
  if (!entry || typeof entry.at !== 'number') {
    return null;
  }
  const ttl = entry.miss ? TTL_MISS : TTL_HIT;
  if (Date.now() - entry.at > ttl) {
    return null;
  }
  if (entry.miss || typeof entry.u !== 'string' || !entry.u) {
    return { status: 'not-found' };
  }
  return { status: 'ok', url: entry.u, source: entry.src || 'iTunes' };
}

/**
 * 写缓存。
 * @param {string} key 查询键
 * @param {{status: string, url?: string, source?: string}} result 查询结果
 * @returns {void}
 */
function writeCached(key, result) {
  const table = readCache();
  if (result.status === 'ok' && result.url) {
    table[key] = { u: result.url, src: result.source || 'iTunes', at: Date.now() };
  } else if (result.status === 'not-found') {
    table[key] = { miss: true, at: Date.now() };
  } else {
    return; // 网络错误不缓存，下次还值得一试
  }
  writeCache(table);
}

// ---------------------------------------------------------------------------
// iTunes 搜索
// ---------------------------------------------------------------------------

/**
 * 把 iTunes 的 100x100 缩略图地址换成 600x600 大图。
 * @param {string} artworkUrl 缩略图地址
 * @returns {string}
 */
function artworkBig(artworkUrl) {
  return String(artworkUrl ?? '').replace(/\/\d+x\d+bb\.(\w+)$/, '/600x600bb.$1');
}

/**
 * 给一条搜索结果打相似度分（歌名权重最高，其次歌手，时长只做参考）。
 * @param {object} item iTunes 结果
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @returns {{score: number, titleExact: boolean, artistMatch: boolean}}
 */
function scoreItem(item, query) {
  const wantTitle = query.trackName.toLowerCase();
  const wantArtist = query.artistName.toLowerCase();
  let score = 0;

  const name = String(item.trackName ?? '').toLowerCase();
  const titleExact = Boolean(wantTitle) && name === wantTitle;
  if (titleExact) {
    score += 30;
  } else if (wantTitle && (name.includes(wantTitle) || wantTitle.includes(name))) {
    score += 12;
  }

  const artist = String(item.artistName ?? '').toLowerCase();
  const artistMatch = Boolean(wantArtist) && (
    wantArtist === artist
    || artist.includes(wantArtist)
    || wantArtist.includes(artist)
  );
  if (wantArtist && artist === wantArtist) {
    score += 25;
  } else if (artistMatch) {
    score += 10;
  }

  const millis = item.trackTimeMillis;
  if (query.duration > 0 && Number.isFinite(millis) && millis > 0) {
    const diff = Math.abs(millis / 1000 - query.duration);
    if (diff <= 2) {
      score += 20;
    } else if (diff <= 6) {
      score += 8;
    } else if (diff > 25) {
      score -= 25;
    }
  }
  return { score, titleExact, artistMatch };
}

/**
 * 从结果列表里挑最合适的一条；歌名对不上（得分太低）宁可放弃也不给错图。
 *
 * 接受门槛：歌名完全一致（同名翻唱也认），或歌手对得上。
 * 否则「光年之外」这类原版只有英文名的歌会命中别人的翻唱 Live 版。
 * @param {object[]} results iTunes 搜索结果
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @returns {object|null}
 */
function pickBest(results, query) {
  if (!Array.isArray(results)) {
    return null;
  }
  let best = null;
  let bestScore = 0;
  for (const item of results) {
    if (!item || typeof item.artworkUrl100 !== 'string' || !item.artworkUrl100) {
      continue;
    }
    const { score, titleExact, artistMatch } = scoreItem(item, query);
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  if (!best || bestScore < 18) {
    return null;
  }
  const name = String(best.trackName ?? '').toLowerCase();
  const artist = String(best.artistName ?? '').toLowerCase();
  const titleExact = Boolean(query.trackName) && name === query.trackName.toLowerCase();
  const artistMatch = Boolean(query.artistName) && (
    artist.includes(query.artistName.toLowerCase())
    || query.artistName.toLowerCase().includes(artist)
  );
  return titleExact || artistMatch ? best : null;
}

/**
 * JSONP 方式调用 iTunes Search（接口不开放 CORS，但支持 callback 参数）。
 * 超时 / 出错 / 被取消都解析为 null，不抛异常。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<{artworkUrl100: string}|null>}
 */
function jsonpSearch(query, signal) {
  return new Promise((resolve) => {
    const seq = ++jsonpSeq;
    const callbackName = `__coverCallback${seq}`;
    const script = document.createElement('script');
    let settled = false;

    const cleanup = () => {
      delete window[callbackName];
      script.remove();
      signal?.removeEventListener('abort', onAbort);
      window.clearTimeout(timer);
    };
    const finish = (value) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve(value);
    };
    const onAbort = () => finish(null);
    const timer = window.setTimeout(() => finish(null), TIMEOUT_JSONP);

    window[callbackName] = (data) => {
      const best = pickBest(data?.results, query);
      finish(best ? { artworkUrl100: best.artworkUrl100 } : null);
    };
    script.onerror = () => finish(null);
    signal?.addEventListener('abort', onAbort, { once: true });

    const params = new URLSearchParams();
    const term = [query.artistName, query.trackName].filter(Boolean).join(' ');
    params.set('term', term);
    params.set('entity', 'song');
    params.set('media', 'music');
    params.set('limit', '8');
    params.set('callback', callbackName);
    script.src = `https://itunes.apple.com/search?${params.toString()}`;
    document.head.append(script);
  });
}

/**
 * 带超时与取消的代理请求，返回解析后的 JSON。
 * @param {string} url 请求地址
 * @param {{timeout: number, signal?: AbortSignal}} options 选项
 * @returns {Promise<object>}
 */
async function requestJson(url, { timeout, signal }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  const relay = () => controller.abort();
  if (signal) {
    if (signal.aborted) {
      controller.abort();
    } else {
      signal.addEventListener('abort', relay, { once: true });
    }
  }
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
      credentials: 'omit',
      cache: 'no-store',
    });
    if (!response.ok) {
      throw Object.assign(new Error(`HTTP ${response.status}`), { httpStatus: response.status });
    }
    return await response.json();
  } finally {
    clearTimeout(timer);
    if (signal) {
      signal.removeEventListener('abort', relay);
    }
  }
}

/**
 * 先走同源代理，代理不可用时降级 JSONP 直连。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<{status: 'ok'|'not-found'|'error', url?: string, source?: string, message?: string}>}
 */
async function requestFromNetwork(query, signal) {
  const params = new URLSearchParams();
  params.set('title', query.trackName);
  if (query.artistName) {
    params.set('artist', query.artistName);
  }
  if (query.duration > 0) {
    params.set('duration', String(query.duration));
  }

  // 1) 同源代理（tools/serve.py）：搜索、下载、落盘一条龙，结果最稳
  try {
    const payload = await requestJson(`${LOCAL_PROXY}?${params.toString()}`, {
      timeout: TIMEOUT_PROXY,
      signal,
    });
    if (payload?.status === 'ok' && typeof payload.url === 'string' && payload.url) {
      return { status: 'ok', url: payload.url, source: 'iTunes' };
    }
    if (payload?.status === 'not-found') {
      return { status: 'not-found' };
    }
    if (payload?.status === 'error') {
      return { status: 'error', message: payload.message || '封面服务暂时不可用，请稍后重试' };
    }
    // 其它形状的响应视为代理异常，继续降级
  } catch (error) {
    if (signal?.aborted) {
      throw error;
    }
    // 代理不存在（纯静态部署）或网络抖动：静默降级到 JSONP
  }

  // 2) JSONP 直连（只能拿远程图片地址，交给 <img> 直接加载）
  if (!isOnline()) {
    return { status: 'error', message: '当前处于离线状态，无法匹配封面' };
  }
  const found = await jsonpSearch(query, signal);
  if (found?.artworkUrl100) {
    return { status: 'ok', url: artworkBig(found.artworkUrl100), source: 'iTunes' };
  }
  return { status: 'not-found' };
}

/**
 * 按曲目信息自动匹配封面。永不抛错（除主动取消），失败一律以 status 表达。
 * @param {object} track 曲目
 * @param {{signal?: AbortSignal, useCache?: boolean}} [options] 选项
 * @returns {Promise<{status: 'ok'|'not-found'|'error'|'aborted'|'empty-query', url?: string, source?: string, message?: string}>}
 */
export async function matchCover(track, { signal, useCache = true } = {}) {
  const query = normalizeQuery(track);
  if (!query.trackName) {
    return { status: 'empty-query' };
  }

  if (useCache) {
    const cached = readCached(query.key);
    if (cached) {
      return cached;
    }
  }

  if (!isOnline()) {
    return { status: 'error', message: '当前处于离线状态，无法匹配封面' };
  }

  try {
    const result = await requestFromNetwork(query, signal);
    writeCached(query.key, result);
    return result;
  } catch (error) {
    if (error?.name === 'AbortError') {
      return { status: 'aborted' };
    }
    console.error('[cover-source] 匹配封面失败：', error);
    return { status: 'error', message: '封面匹配失败' };
  }
}

/**
 * 清空封面缓存（调试 / 设置里用）。
 * @returns {void}
 */
export function clearCoverCache() {
  try {
    window.localStorage.removeItem(CACHE_KEY);
  } catch (error) {
    console.error('[cover-source] 清空封面缓存失败：', error);
  }
}

// 预取时的温和限速间隔（毫秒），对公共搜索接口客气一点
export const COVER_PREFETCH_DELAY = 400;
