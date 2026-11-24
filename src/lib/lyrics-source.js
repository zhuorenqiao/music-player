/**
 * lyrics-source.js —— 按曲目信息自动匹配歌词
 *
 * 2026-11-23 起是四源链路：**LRCLIB → 汽水 → 酷狗 → 网易云**。
 * LRCLIB 有 CORS，先由客户端直连；线上静态站再通过 CloudBase 中转
 * 访问汽水、酷狗（它们没有 CORS 头），中转没词时才继续直连网易云。
 *
 * 两级通道：
 * 1) 直连 LRCLIB：线上 / 静态部署的第一优先；本地开发由 Vite 中间件统一编排四源，
 *    因此相对代理模式下不重复预检；
 * 2) 代理 `api/lyrics`——线上指向 CloudBase 中转（只跑汽水、酷狗），本地开发
 *    由 Vite 中间件实现；代理没词时再直连网易云。
 *
 * 缓存换到 v4 纪元（`light-music.lyrics-cache.v4`）：旧 v3 / v2 / v1 表仍读，但只当兜底 ——
 * 命中后先问一遍新源，新源没词才拿旧结果。这样「LRCLIB 优先」对已经缓存过的歌也生效，
 * 离线时又不会因为换源丢掉手里的歌词；旧的「未找到」缓存不再挡路。
 *
 * 结果（含「没找到」）都会写进 localStorage 缓存，重复听同一首歌不再联网。
 * 本模块不碰 DOM，也不持有播放器，只做「查询 + 归一化」。
 */

import { toSimplified } from './chinese';
import {
  candidateKeyword,
  looksSynced,
  neteaseCandidates,
  parseNetEaseSongs,
  pickNetEaseSong,
  stripLeadingCredits,
} from './netease-match';

/** 直连地址。 */
const DIRECT_BASE = 'https://lrclib.net/api';

/** 网易云端点：搜索认歌 + 取词（与 server/music-api.ts 同源同路径）。 */
const NETEASE_SEARCH = 'https://music.163.com/api/search/get';
const NETEASE_LYRIC = 'https://music.163.com/api/song/lyric';

/**
 * 歌词查询代理地址。
 *
 * - 本地开发：走 Vite 中间件 `/api/lyrics`，同源、无 CORS；
 * - 线上静态站：汽水/酷狗没有 CORS 头，必须走 CloudBase 中转（绝对地址）；
 * - 测试/脚本：没有 `import.meta.env` 时保持相对地址，便于 mock。
 *
 * 需要临时切换时，可在页面加载前设 `window.__LIGHT_MUSIC_LYRICS_PROXY__`。
 */
const REMOTE_PROXY = 'https://caidan-1-d9glqugbu5be15778-1316655607.ap-shanghai.app.tcloudbase.com/api/lyrics';
const LOCAL_PROXY = (
  typeof window !== 'undefined' && typeof window.__LIGHT_MUSIC_LYRICS_PROXY__ === 'string'
    ? window.__LIGHT_MUSIC_LYRICS_PROXY__
    : (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_LYRICS_PROXY_URL)
) || (
  typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.PROD
    ? REMOTE_PROXY
    : 'api/lyrics'
);

/** localStorage 缓存键与容量。 */
const CACHE_KEY = 'light-music.lyrics-cache.v4';
/**
 * 换源前的老表：只读，只作兜底。v3 是四源时代（汽水 → 酷狗 → 网易云 → LRCLIB），
 * v2 是网易云时代，v1 是 LRCLIB 时代，各留一份当作离线时的最后一手（v3 优先）。
 */
const LEGACY_CACHE_KEYS = [
  'light-music.lyrics-cache.v3',
  'light-music.lyrics-cache.v2',
  'light-music.lyrics-cache.v1',
];
const MAX_CACHE_ENTRIES = 120;

/** 缓存有效期：命中 30 天，未命中 3 天（避免坏结果长期占位）。 */
const TTL_HIT = 30 * 24 * 60 * 60 * 1000;
const TTL_MISS = 3 * 24 * 60 * 60 * 1000;

/**
 * 超时时间（毫秒）。
 *
 * 代理端会并行跑多路查询、最多等 45s（serve.py 的 LYRICS_DEADLINE），
 * 这里必须比它更长，否则前端先 abort、后端其实还在跑，
 * 用户看到的就是「服务维护中」——而真实原因只是我们自己的预算太短。
 * 直连留 15s。
 */
const TIMEOUT_PROXY = 60000;
const TIMEOUT_DIRECT = 15000;
/** 网易云单程 6s：它排在最后补位，不能把整次匹配的时间预算吃光。 */
const TIMEOUT_NETEASE = 6000;

/** 值得重试的 HTTP 状态码（429 限流 / 5xx 网关与服务端抖动）。 */
const RETRYABLE_STATUS = new Set([429, 500, 502, 503, 504]);

/** 单次等待上限（毫秒），避免被异常大的 Retry-After 卡死。 */
const MAX_RETRY_AFTER_MS = 6000;

/** 命中限流后的冷却时长（毫秒）：这段时间内不再自动发请求，只提示用户稍后重试。 */
const RATE_LIMIT_COOLDOWN_MS = 60 * 1000;

/** @type {number} 限流冷却截止时间戳 */
let rateLimitedUntil = 0;

/**
 * 标记进入限流冷却。
 * @param {number} [retryAfterSeconds] 服务端建议的等待秒数
 * @returns {void}
 */
function noteRateLimit(retryAfterSeconds) {
  const base = retryAfterSeconds > 0 ? retryAfterSeconds * 1000 : RATE_LIMIT_COOLDOWN_MS;
  rateLimitedUntil = Date.now() + Math.min(Math.max(base, 10 * 1000), RATE_LIMIT_COOLDOWN_MS);
}

/**
 * 清除冷却（有一次成功就说明服务恢复了）。
 * @returns {void}
 */
function clearRateLimit() {
  rateLimitedUntil = 0;
}

/**
 * 当前是否处于限流冷却中。
 * @returns {boolean}
 */
export function isRateLimited() {
  return Date.now() < rateLimitedUntil;
}

/**
 * 等待若干毫秒。
 * @param {number} ms 毫秒
 * @returns {Promise<void>}
 */
function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

/**
 * 标题末尾、不带括号的噪声标签：`飞机场的10:30伴奏`、`Catherine - 伴奏`、
 * `Catherine_伴奏版`、`十年 完整版`……下载站与本地文件很常见。
 *
 * 只认**中文**标记，且要求剥完还剩内容（`伴奏` 本身不会被剥成空串）；
 * `Live` / `Remix` 这类英文词不在这里裸剥 —— `Live Forever` 是真歌名，
 * 只在括号里（`(Live)`）才当噪声。多轮剥是为了 `Catherine 伴奏 完整版`
 * 这种叠加尾巴，最多三轮足够。
 */
const TITLE_TAIL_NOISE = /(?:[\s\-_·|/–—－]+)?(?:伴奏音乐|伴奏版|纯伴奏|消音伴奏|伴奏|纯音乐版|纯音乐|高音质|无损|完整版|超清|动态歌词|原唱|翻唱|官方版|正式版|试听版)$/i;

/**
 * 去掉标题里的常见噪声（音质、官方版、伴奏等标记）。
 * @param {string} title 原始标题
 * @returns {string}
 */
function cleanTitle(title) {
  let value = String(title ?? '').trim();
  // 去掉开头的音轨号：01. / 01 - / [01]
  value = value.replace(/^\s*[[(]?\d{1,3}[)\]]?\s*[.\-、_]\s*/, '');
  // 去掉括号/方括号里的噪声说明
  value = value.replace(/[（(【[][^）)】\]]*(?:official|mv|hd|hq|live|remix|伴奏|纯音乐|高音质|无损|完整版|超清|动态歌词|原唱|翻唱)[^）)】\]]*[）)】\]]/gi, '');
  // 去掉尾部不带括号的噪声标签（可叠加，最多三轮）
  for (let i = 0; i < 3; i += 1) {
    const next = value
      .replace(TITLE_TAIL_NOISE, '')
      .replace(/[-_·|/–—－\s]+$/, '')
      .trim();
    if (next === value || next === '') {
      break;
    }
    value = next;
  }
  // 去掉尾部多余符号
  return value.replace(/\s{2,}/g, ' ').replace(/[-_\s]+$/, '').trim();
}

/** 判断字符串里是否含中日韩文字（用于「无空格的连字符」拆分判断）。 */
const CJK_PATTERN = /[\u3400-\u9fff\uf900-\ufaff]/;

/**
 * 从「歌手 - 歌名」形式的文件名里拆出歌手与歌名。
 *
 * 优先认带空格的 ` - ` / ` – ` / ` — `（最常见的下载命名）。
 * 没有空格时只在两侧都是中日韩文字才拆 —— 否则 `track-02` 会被误拆成
 * 歌手「track」+ 歌名「02」，`Jay-Z` 也会被误拆。
 * @param {string} raw 原始标题
 * @returns {{artist: string, title: string}|null}
 */
export function splitArtistTitle(raw) {
  const value = String(raw ?? '').trim();
  if (!value) {
    return null;
  }

  const spaced = value.match(/^(.{1,60}?)\s+[-–—]\s+(.{1,80})$/);
  if (spaced) {
    const artist = spaced[1].trim();
    const title = spaced[2].trim();
    return artist && title ? { artist, title } : null;
  }

  const tight = value.match(/^(.{1,60}?)[-–—](.{1,80})$/);
  if (tight) {
    const artist = tight[1].trim();
    const title = tight[2].trim();
    if (artist && title && CJK_PATTERN.test(artist) && CJK_PATTERN.test(title)) {
      return { artist, title };
    }
  }
  return null;
}

/**
 * 把一条曲目归一化成查询参数。
 * @param {object} track 曲目
 * @returns {{trackName: string, artistName: string, duration: number, key: string}}
 */
export function normalizeQuery(track) {
  const title = cleanTitle(track?.title ?? '');
  let artist = String(track?.artist ?? '').trim();

  // 本地文件默认 artist 是「本地文件」，没有信息量，尝试从文件名反推
  const isPlaceholder = artist === '' || artist === '本地文件' || artist === '未知歌手';
  let trackName = title;
  if (isPlaceholder) {
    const split = splitArtistTitle(title);
    if (split) {
      artist = split.artist;
      trackName = cleanTitle(split.title);
    } else {
      artist = '';
    }
  }

  const duration = Number.isFinite(track?.duration) && track.duration > 0
    ? Math.round(track.duration)
    : 0;

  const key = `${trackName}|${artist}|${duration}`.toLowerCase();
  return { trackName, artistName: artist, duration, key };
}

/**
 * 把查询参数折到简体。
 *
 * LRCLIB 的 `/get` 是「曲名 + 歌手」逐字匹配：标签写成繁体（周杰倫 / 完美主義）时，
 * 上游那条简体记录一条都对不上（实测 get 404、search 0 条，见 2026-11-21 的
 * 《完美主义》案例）。`/search` 同样按词面切词，也不认繁简。
 *
 * 所以查询前统一折到简体，缓存键也跟着折 —— 键变了，之前按繁体查出来的
 * 「未找到」不会再挡在缓存里。只折查询参数，不动歌词正文（正文的繁→简由
 * 显示层的 `toSimplified` 负责，缓存里保持原文）。
 *
 * 返回对象里额外带上原字形（`rawTrackName` / `rawArtistName`），供「简体也没命中」
 * 时补一次原字形搜索：只有繁体条目的冷门歌不至于因此回归。
 * @param {{trackName: string, artistName: string, duration: number, key: string}} query
 * @returns {{trackName: string, artistName: string, duration: number, key: string, rawTrackName: string, rawArtistName: string}}
 */
export function foldQuery(query) {
  const trackName = toSimplified(query.trackName);
  const artistName = toSimplified(query.artistName);
  return {
    ...query,
    trackName,
    artistName,
    key: `${trackName}|${artistName}|${query.duration}`.toLowerCase(),
    rawTrackName: query.trackName,
    rawArtistName: query.artistName,
  };
}

/**
 * 折叠是否真的改动了查询（决定要不要补原字形回退）。
 * @param {{trackName: string, artistName: string, rawTrackName?: string, rawArtistName?: string}} query
 * @returns {boolean}
 */
function hasScriptVariant(query) {
  return Boolean(query.rawTrackName || query.rawArtistName)
    && (query.rawTrackName !== query.trackName || query.rawArtistName !== query.artistName);
}

// ---------------------------------------------------------------------------
// localStorage 缓存
// ---------------------------------------------------------------------------

/**
 * 读缓存表（损坏时返回空表）。
 * @param {string} [key] localStorage 键，默认当前纪元
 * @returns {Record<string, {s?: string, p?: string, miss?: boolean, at: number}>}
 */
function readCache(key = CACHE_KEY) {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (error) {
    console.error('[lyrics-source] 读取歌词缓存失败，已忽略：', error);
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
    // 配额已满：清掉整张表再试一次，仍失败就放弃缓存（不影响功能）
    try {
      window.localStorage.removeItem(CACHE_KEY);
    } catch { /* 忽略 */ }
    console.error('[lyrics-source] 写入歌词缓存失败：', error);
  }
}

/**
 * 查缓存。
 * @param {string} key 查询键
 * @returns {{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string}|null}
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
  if (entry.miss) {
    return { status: 'not-found', source: '缓存' };
  }
  return {
    status: 'ok',
    syncedLyrics: typeof entry.s === 'string' ? entry.s : '',
    plainLyrics: typeof entry.p === 'string' ? entry.p : '',
    source: entry.src || 'LRCLIB',
  };
}

/**
 * 查旧纪元缓存（v3 → v2 → v1）：只作兜底，而且**不返回「未找到」** ——
 * 那是换源前的负结论，会挡住新源翻案。
 * @param {string} key 查询键
 * @returns {{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string}|null}
 */
function readLegacyCached(key) {
  for (const cacheKey of LEGACY_CACHE_KEYS) {
    const entry = readCache(cacheKey)[key];
    if (!entry || entry.miss || typeof entry.at !== 'number') {
      continue;
    }
    if (Date.now() - entry.at > TTL_HIT) {
      continue;
    }
    return {
      status: 'ok',
      syncedLyrics: typeof entry.s === 'string' ? entry.s : '',
      plainLyrics: typeof entry.p === 'string' ? entry.p : '',
      source: entry.src || 'LRCLIB',
    };
  }
  return null;
}

/**
 * 写缓存。
 * @param {string} key 查询键
 * @param {{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string}} result 查询结果
 * @returns {void}
 */
function writeCached(key, result) {
  const table = readCache();
  if (result.status === 'ok') {
    table[key] = {
      s: result.syncedLyrics || '',
      p: result.plainLyrics || '',
      src: result.source || 'LRCLIB',
      at: Date.now(),
    };
  } else if (result.status === 'not-found') {
    table[key] = { miss: true, at: Date.now() };
  } else {
    return;
  }
  writeCache(table);
}

// ---------------------------------------------------------------------------
// 网络请求
// ---------------------------------------------------------------------------

/**
 * 带超时的 fetch，返回解析后的 JSON 或 null（404）。
 * @param {string} url 请求地址
 * @param {number} timeout 超时毫秒
 * @param {AbortSignal} [outerSignal] 外部取消信号
 * @returns {Promise<any|null>}
 */
/**
 * 发起一次请求。**不抛 5xx 异常**，一律以结构化结果返回，方便上层决定是否重试。
 * @param {string} url 请求地址
 * @param {{timeout: number, signal?: AbortSignal}} options 选项
 * @returns {Promise<{ok: boolean, data?: any, status: number, retryable?: boolean, retryAfter?: number, timeout?: boolean, network?: boolean}>}
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

    if (response.status === 404) {
      return { ok: false, status: 404, retryable: false };
    }
    if (!response.ok) {
      const retryAfter = Number(response.headers.get('retry-after'));
      return {
        ok: false,
        status: response.status,
        retryable: RETRYABLE_STATUS.has(response.status),
        retryAfter: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 0,
      };
    }
    return { ok: true, status: response.status, data: await response.json() };
  } catch (error) {
    // 外部主动取消：原样抛出，让上层静默丢弃
    if (signal?.aborted) {
      throw error;
    }
    if (error?.name === 'AbortError') {
      return { ok: false, status: 0, retryable: true, timeout: true };
    }
    return { ok: false, status: 0, retryable: true, network: true };
  } finally {
    clearTimeout(timer);
    if (signal) {
      signal.removeEventListener('abort', relay);
    }
  }
}

/**
 * 带退避重试的请求。
 *
 * 上游（LRCLIB / Cloudflare）会间歇性返回 503 或握手超时：同一条请求
 * 隔几秒重发往往就成功，所以必须重试；但重试要有节制，不能把限流越打越重。
 * @param {string} url 请求地址
 * @param {{timeout: number, signal?: AbortSignal, attempts?: number}} options 选项
 * @returns {Promise<object>} 与 requestJson 相同的结构
 */
async function requestJsonRetry(url, { timeout, signal, attempts = 2 }) {
  let last = { ok: false, status: 0, network: true };

  for (let index = 0; index < attempts; index += 1) {
    last = await requestJson(url, { timeout, signal });
    if (last.ok || last.status === 404) {
      clearRateLimit();
      return last;
    }
    if (!last.retryable) {
      return last;
    }

    if (last.status === 429 || last.status === 503) {
      // 记下冷却窗口，避免紧接着的其它曲目继续打同一个限流接口
      noteRateLimit(last.retryAfter);
    }
    if (index < attempts - 1) {
      // 优先遵循 Retry-After，其次 700ms → 1.8s 递增
      const wait = last.retryAfter
        ? Math.min(MAX_RETRY_AFTER_MS, last.retryAfter * 1000)
        : (index === 0 ? 700 : 1800);
      await sleep(wait);
    }
  }
  return last;
}

/**
 * 把失败结果翻译成用户能看懂的中文。
 * @param {object} result requestJson 的失败结果
 * @returns {string}
 */
function describeFailure(result) {
  if (result.timeout) {
    return '连接歌词服务超时，请检查网络后点「重试」';
  }
  if (result.status === 429 || result.status === 503) {
    return '歌词服务正在限流，请稍后点「重试」';
  }
  if (result.status >= 500) {
    return `歌词服务暂时不可用（HTTP ${result.status}），请稍后重试`;
  }
  if (result.network) {
    return '无法连接歌词服务，请检查网络或代理设置';
  }
  return '歌词匹配失败';
}

/**
 * 把一次 LRCLIB 返回的记录整理成结果对象。
 * @param {object} record LRCLIB 记录
 * @returns {{status: string, syncedLyrics: string, plainLyrics: string, source: string}}
 */
function toResult(record) {
  return {
    status: 'ok',
    syncedLyrics: typeof record?.syncedLyrics === 'string' ? record.syncedLyrics : '',
    plainLyrics: typeof record?.plainLyrics === 'string' ? record.plainLyrics : '',
    source: 'LRCLIB',
  };
}

/**
 * 从搜索结果里挑最合适的一条：优先有时间轴，其次时长接近、标题/歌手完全一致。
 * @param {object[]} list 搜索结果
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @returns {object|null}
 */
function pickBest(list, query) {
  if (!Array.isArray(list) || list.length === 0) {
    return null;
  }
  const wantTitle = toSimplified(query.trackName).toLowerCase();
  const wantArtist = toSimplified(query.artistName).toLowerCase();

  const scored = list.map((item) => {
    let score = 0;
    if (typeof item.syncedLyrics === 'string' && item.syncedLyrics.trim()) {
      score += 50;
    }
    const name = toSimplified(String(item.trackName ?? item.name ?? '')).toLowerCase();
    if (name === wantTitle) {
      score += 30;
    } else if (name.includes(wantTitle) || wantTitle.includes(name)) {
      score += 12;
    }
    const artist = toSimplified(String(item.artistName ?? '')).toLowerCase();
    if (wantArtist && artist === wantArtist) {
      score += 25;
    } else if (wantArtist && artist.includes(wantArtist)) {
      score += 10;
    }
    if (query.duration > 0 && Number.isFinite(item.duration)) {
      const diff = Math.abs(item.duration - query.duration);
      if (diff <= 2) {
        score += 30;
      } else if (diff <= 6) {
        score += 12;
      } else if (diff > 25) {
        score -= 25;
      }
    }
    return { item, score };
  });

  scored.sort((a, b) => b.score - a.score);
  return scored[0].item;
}

/**
 * 直连网易云：认歌（与译文链路同一套候选 / 门槛）→ 取 `lrc.lyric` → 归一。
 *
 * 只有「没有同源代理」的静态部署才会走到这里：`music.163.com` 不带 CORS 头，
 * 浏览器里通常第一条请求就快速失败。整家连不上时立刻收手，
 * 不再拿三个候选挨个撞墙。它是四源里的最后一手，前面已经试过 LRCLIB、汽水、酷狗。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询（已折简体）
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<{status: string, syncedLyrics: string, plainLyrics: string, source: string}|null>}
 */
async function requestNetEaseLyrics(query, signal) {
  const candidates = neteaseCandidates(query.trackName, query.artistName);
  if (query.artistName) {
    candidates.push({ name: query.trackName, artist: '', strict: false });
  }
  const tried = new Set();
  for (const candidate of candidates) {
    const keyword = candidateKeyword(candidate);
    if (!keyword) {
      continue;
    }
    try {
      const params = new URLSearchParams({ s: keyword, type: '1', limit: '20' });
      const found = await requestJson(`${NETEASE_SEARCH}?${params.toString()}`, {
        timeout: TIMEOUT_NETEASE,
        signal,
      });
      if (!found.ok) {
        // 连不上 / 超时是「整家」的问题，换候选只会把同样的墙再撞一遍。
        if (found.network || found.timeout) {
          return null;
        }
        continue;
      }
      const songs = parseNetEaseSongs(found.data);
      const song = pickNetEaseSong(songs, {
        trackName: candidate.name,
        artistName: candidate.artist,
        duration: query.duration,
        strict: candidate.strict,
      });
      if (!song || tried.has(song.id)) {
        continue;
      }
      tried.add(song.id);
      const lyricParams = new URLSearchParams({ id: String(song.id), lv: '1' });
      const lyric = await requestJson(`${NETEASE_LYRIC}?${lyricParams.toString()}`, {
        timeout: TIMEOUT_NETEASE,
        signal,
      });
      if (!lyric.ok || !lyric.data || lyric.data.nolyric || lyric.data.uncollected) {
        continue;
      }
      const text = typeof lyric.data?.lrc?.lyric === 'string' ? lyric.data.lrc.lyric : '';
      if (!text.trim()) {
        continue;
      }
      // 网易云开头常带一串带时间轴的制作署名，解析器只清前 4 行，这里先剥干净。
      const body = stripLeadingCredits(text);
      if (!body.trim()) {
        continue;
      }
      const synced = looksSynced(body);
      return {
        status: 'ok',
        syncedLyrics: synced ? body : '',
        plainLyrics: synced ? '' : body,
        source: '网易云音乐',
      };
    } catch (error) {
      if (error?.name === 'AbortError' && signal?.aborted) {
        throw error;
      }
      continue;
    }
  }
  return null;
}

/**
 * 直连 LRCLIB：带时长的精确 get、不带时长的 get、search 三路并行，全部等完再裁决。
 *
 * 线上 / 静态部署的第一优先就是它；本地相对代理模式下由服务端统一跑四源，
 * 客户端不再重复预检。三路并行是为了不让「LRCLIB 优先」变成串行等待：
 * 最坏情况只等最慢的一路，而不是三路超时相加。首次预检不重试（attempts: 1），
 * 一次网络抖动就交给汽水 / 酷狗补位，别把整次匹配拖到几十秒。
 * 裁决与 music-api.ts 一致：synced get → synced search → 任意 get → get 失败
 * → 任意 search → 其它失败 → not-found。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @param {URLSearchParams} params 带时长的查询参数
 * @param {URLSearchParams} baseParams 不带时长的查询参数
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string, message?: string}>}
 */
async function requestLrclibDirect(query, params, baseParams, signal) {
  const jobs = [];
  const runGet = async (url) => {
    const response = await requestJsonRetry(url, {
      timeout: TIMEOUT_DIRECT,
      signal,
      attempts: 1,
    });
    if (response.ok) {
      const result = toResult(response.data);
      if (!result.syncedLyrics.trim() && !result.plainLyrics.trim()) {
        return { status: 'not-found' };
      }
      return result;
    }
    if (response.status === 404) {
      return { status: 'not-found' };
    }
    throw new Error(describeFailure(response));
  };

  if (query.duration > 0) {
    jobs.push({ kind: 'get', run: () => runGet(`${DIRECT_BASE}/get?${params.toString()}`) });
  }
  jobs.push({ kind: 'get', run: () => runGet(`${DIRECT_BASE}/get?${baseParams.toString()}`) });
  jobs.push({
    kind: 'search',
    run: async () => {
      const response = await requestJsonRetry(`${DIRECT_BASE}/search?${baseParams.toString()}`, {
        timeout: TIMEOUT_DIRECT,
        signal,
        attempts: 1,
      });
      if (!response.ok) {
        if (response.status === 404) {
          return { status: 'not-found' };
        }
        throw new Error(describeFailure(response));
      }
      return best ? toResult(best) : { status: 'not-found' };
    },
  });

  const settled = await Promise.allSettled(jobs.map((job) => job.run()));
  const getHits = [];
  const searchHits = [];
  const getErrors = [];
  const errors = [];

  settled.forEach((entry, index) => {
    const kind = jobs[index].kind;
    if (entry.status === 'fulfilled') {
      if (entry.value.status !== 'ok') {
        return;
      }
      if (kind === 'get') {
        getHits.push(entry.value);
      } else {
        searchHits.push(entry.value);
      }
      return;
    }
    if (signal?.aborted) {
      throw entry.reason;
    }
    const failure = {
      status: 'error',
      message: entry.reason?.message || '歌词匹配失败，请稍后点「重试」',
    };
    errors.push(failure);
    if (kind === 'get') {
      getErrors.push(failure);
    }
  });

  const hasSynced = (result) => Boolean(result && result.syncedLyrics && result.syncedLyrics.trim());
  const syncedGet = getHits.find(hasSynced);
  if (syncedGet) {
    return syncedGet;
  }
  const syncedSearch = searchHits.find(hasSynced);
  if (syncedSearch) {
    return syncedSearch;
  }
  if (getHits.length > 0) {
    return getHits[0];
  }
  if (getErrors.length > 0) {
    return getErrors[0];
  }
  if (searchHits.length > 0) {
    return searchHits[0];
  }
  if (errors.length > 0) {
    return errors[0];
  }
  return { status: 'not-found' };
}

/**
 * 先走 LRCLIB（仅线上 / 静态代理），再走同源代理，再走直连网易云。
 * query 必须已折到简体（matchLyrics 用 foldQuery 折过）。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @param {AbortSignal} [signal] 取消信号
 * @param {{refresh?: boolean}} [options] refresh=true 时让同源代理绕过自己的缓存
 * @returns {Promise<{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string, message?: string}>}
 */
async function requestFoldedNetwork(query, signal, { refresh = false } = {}) {
  const params = new URLSearchParams();
  params.set('track_name', query.trackName);
  if (query.artistName) {
    params.set('artist_name', query.artistName);
  }
  if (query.duration > 0) {
    params.set('duration', String(query.duration));
  }

  const proxyParams = new URLSearchParams(params);
  if (refresh) {
    proxyParams.set('refresh', '1');
  }

  const baseParams = new URLSearchParams();
  baseParams.set('track_name', query.trackName);
  if (query.artistName) {
    baseParams.set('artist_name', query.artistName);
  }

  /**
   * 绝对地址 = 线上 / 静态部署：中转只跑汽水、酷狗，LRCLIB 必须由客户端先直连。
   * 相对地址 = 本地 Vite 中间件，服务端已经按「LRCLIB → 汽水 → 酷狗 → 网易云」
   * 完整编排过四源，客户端不再重复预检。
   */
  const hasRemoteProxy = /^https?:\/\//i.test(LOCAL_PROXY);
  let lrclibFirst = null;
  if (hasRemoteProxy) {
    lrclibFirst = await requestLrclibDirect(query, params, baseParams, signal);
    if (lrclibFirst.status === 'ok') {
      clearRateLimit();
      return lrclibFirst;
    }
  }

  // 1) 代理（线上是 CloudBase 中转，本地开发是 Vite 中间件）。服务端会重试并缓存，这里不重试。
  try {
    const proxied = await requestJson(`${LOCAL_PROXY}?${proxyParams.toString()}`, {
      timeout: TIMEOUT_PROXY,
      signal,
    });
    if (proxied.ok && proxied.data && typeof proxied.data.status === 'string') {
      const payload = proxied.data;
      if (payload.status === 'ok') {
        clearRateLimit();
        return { ...toResult(payload), source: payload.source || 'LRCLIB' };
      }
      if (payload.status === 'not-found') {
        // 线上中转只负责汽水、酷狗两家（它们没有 CORS 头）。这两家没词时
        // 会带 fallback 标记，客户端继续直连网易云；不能在这里截断。
        if (payload.fallback !== true) {
          return { status: 'not-found' };
        }
      }
      // 线上中转只负责汽水、酷狗两家（它们没有 CORS 头）。这两家没词时
      // 会带 fallback 标记，客户端继续直连网易云；不能在这里截断。
      const canFallback = payload.status === 'not-found' && payload.fallback === true;
      if (payload.status === 'not-found' && !canFallback) {
        return { status: 'not-found' };
      }
      if (!canFallback) {
        // 代理明确报告上游失败：直接把原因交给界面，不再走浏览器直连（那条路通常更慢）。
        // reason 要一路带到界面：是限流、超时还是连不上，用户的处理方式完全不同。
        if (payload.reason === 'rate-limit') {
          noteRateLimit(payload.retryAfter);
        }
        return {
          status: 'error',
          reason: payload.reason || 'upstream',
          rateLimited: payload.reason === 'rate-limit',
          message: payload.message || '歌词服务暂时不可用，请稍后重试',
        };
      }
    }
    // 404 / 非 JSON：说明没有这个代理端点，继续走直连
  } catch (error) {
    if (error?.name === 'AbortError' && signal?.aborted) {
      throw error;
    }
    // 代理不可用，静默降级到直连
  }

  // 2) 直连网易云（代理未命中 / 不可用时才走到这里；CORS 不通时快速失败）
  const netEase = await requestNetEaseLyrics(query, signal);
  if (netEase) {
    clearRateLimit();
    return netEase;
  }

  /**
   * 线上 / 静态部署：LRCLIB 已经在本函数最前面直连过，这里不再重复请求；
   * 若它当时是明确失败（限流 / 超时），把那条原因带回去，别改写成「未找到」。
   */
  if (hasRemoteProxy) {
    if (lrclibFirst?.status === 'error') {
      return lrclibFirst;
    }
    return { status: 'not-found' };
  }

  // 3) 本地相对代理：服务端没词 / 代理不可用时，再由客户端直连 LRCLIB
  return requestLrclibDirect(query, params, baseParams, signal);
}

/**
 * 简体那几路都没命中时，用原字形再搜一次。
 *
 * 只补一次 search（不回补 get）：LRCLIB 的条目大多有简繁两份，折叠后一般直接命中；
 * 只有「上游只收了繁体条目」的冷门歌会走到这里，一次搜索足以确认。
 * @param {{trackName: string, artistName: string, rawTrackName: string, rawArtistName: string, duration: number}} query 折叠后的查询（带原字形）
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<object|null>} 命中结果；没命中 / 请求失败都返回 null
 */
async function searchRawScript(query, signal) {
  const loose = [query.rawTrackName, query.rawArtistName].filter(Boolean).join(' ');
  if (!loose) {
    return null;
  }
  try {
    const params = new URLSearchParams({ q: loose });
    const found = await requestJsonRetry(`${DIRECT_BASE}/search?${params.toString()}`, {
      timeout: TIMEOUT_DIRECT,
      signal,
      attempts: 1,
    });
    if (!found.ok) {
      return null;
    }
    const best = pickBest(found.data, query);
    return best ? toResult(best) : null;
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw error;
    }
    // 回退那一路失败不改写结论：主路径已经判定 not-found，这只是一次补救
    return null;
  }
}

/**
 * 先查简体，未命中且原字形不同再补一次原字形搜索。
 * @param {{trackName: string, artistName: string, duration: number, rawTrackName: string, rawArtistName: string}} query 折叠后的查询
 * @param {AbortSignal} [signal] 取消信号
 * @param {{refresh?: boolean}} [options] refresh=true 时让同源代理绕过自己的缓存
 * @returns {Promise<object>} 与 requestFoldedNetwork 同构
 */
async function requestFromNetwork(query, signal, options = {}) {
  const primary = await requestFoldedNetwork(query, signal, options);
  if (primary.status !== 'not-found' || !hasScriptVariant(query)) {
    return primary;
  }
  return await searchRawScript(query, signal) ?? primary;
}

/**
 * 判断接口是否可用（用于界面提示，不做实际请求）。
 * @returns {boolean}
 */
export function isOnline() {
  return typeof navigator === 'undefined' || navigator.onLine !== false;
}

/**
 * 按曲目自动匹配歌词。永不抛错（除主动取消），失败一律以 status 表达。
 * @param {object} track 曲目
 * @param {{signal?: AbortSignal, useCache?: boolean}} [options] 选项
 * @returns {Promise<{status: 'ok'|'not-found'|'error'|'aborted'|'empty-query', syncedLyrics?: string, plainLyrics?: string, source?: string, message?: string}>}
 */
export async function matchLyrics(track, { signal, useCache = true } = {}) {
  const rawQuery = normalizeQuery(track);
  if (!rawQuery.trackName) {
    return { status: 'empty-query', message: '曲目信息不足，无法匹配歌词' };
  }
  // 曲名/歌手先折到简体再查（繁体标签对不上 LRCLIB 的简体记录，见 foldQuery）
  const query = foldQuery(rawQuery);

  // v4 命中（含「未找到」）直接返回；旧纪元的命中只当兜底，先让新源说话。
  let legacy = null;
  if (useCache) {
    const cached = readCached(query.key);
    if (cached) {
      return cached;
    }
    legacy = readLegacyCached(query.key);
  }

  if (!isOnline()) {
    return { status: 'error', message: '当前处于离线状态，无法在线匹配歌词' };
  }

  // 冷却期内不再自动发请求（用户手动点「重试」时 useCache 为 false，允许旁路）
  if (isRateLimited() && useCache) {
    return { status: 'error', message: '歌词服务刚才在限流，请稍后点「重试」', rateLimited: true };
  }

  try {
    const result = await requestFromNetwork(query, signal, { refresh: !useCache });
    if (result.status === 'ok') {
      writeCached(query.key, result);
      return result;
    }
    // 所有源都没词：旧纪元的词总比没有强，顺手写进 v4，
    // 免得每次播放都为同一首歌再问一遍上游。
    if (result.status === 'not-found' && legacy) {
      writeCached(query.key, legacy);
      return legacy;
    }
    writeCached(query.key, result);
    return result;
  } catch (error) {
    if (error?.name === 'AbortError') {
      return { status: 'aborted' };
    }
    console.error('[lyrics-source] 匹配歌词失败：', error);
    return { status: 'error', message: '歌词匹配失败，请稍后点「重试」' };
  }
}

/**
 * 结果 source → 持久化的来源 id（`qishui` / `kugou` / `netease` / `lrclib` / 空串）。
 * 缓存里的 source 是给人看的字面量，落进 Track 的是稳定 id。
 * @param {string} [source] 匹配结果的 source
 * @returns {'qishui'|'kugou'|'netease'|'lrclib'|''}
 */
export function lyricsOriginOf(source) {
  const text = String(source ?? '');
  if (text.includes('汽水')) {
    return 'qishui';
  }
  if (text.includes('酷狗')) {
    return 'kugou';
  }
  if (text.includes('网易云')) {
    return 'netease';
  }
  if (text.includes('LRCLIB')) {
    return 'lrclib';
  }
  return '';
}

/**
 * 来源 id → 状态行里的名称。
 * @param {string} [origin] Track.lyricsOrigin
 * @returns {string}
 */
export function lyricsOriginLabel(origin) {
  if (origin === 'qishui') {
    return '汽水音乐';
  }
  if (origin === 'kugou') {
    return '酷狗音乐';
  }
  if (origin === 'netease') {
    return '网易云音乐';
  }
  if (origin === 'lrclib') {
    return 'LRCLIB线上库';
  }
  // 老档案没有来源字段：只敢说「线上歌词库」，不冒充某一家。
  return '线上歌词库';
}

/**
 * 清空歌词缓存（调试 / 设置里用）。
 * @returns {void}
 */
export function clearLyricsCache() {
  try {
    window.localStorage.removeItem(CACHE_KEY);
    // 换源前的旧表也清掉，否则「强制刷新」还会从旧表里兜回老词。
    for (const legacyKey of LEGACY_CACHE_KEYS) {
      window.localStorage.removeItem(legacyKey);
    }
  } catch (error) {
    console.error('[lyrics-source] 清空歌词缓存失败：', error);
  }
}
