/**
 * lyrics-source.js —— 按曲目信息自动匹配歌词
 *
 * 数据源：LRCLIB（https://lrclib.net，免密钥、开源、返回标准 LRC）
 *
 * 两级通道：
 * 1) 同源代理 `api/lyrics`（tools/serve.py 提供）——服务端拉取 + 磁盘缓存，
 *    能绕开浏览器侧的代理/CORS 问题，本地开发时最快；
 * 2) 直连 `https://lrclib.net/api/*`——静态部署（没有本地服务）时使用，
 *    该接口返回 `access-control-allow-origin: *`，浏览器可直接跨域。
 *
 * 结果（含「没找到」）都会写进 localStorage 缓存，重复听同一首歌不再联网。
 * 本模块不碰 DOM，也不持有播放器，只做「查询 + 归一化」。
 */

/** 直连地址。 */
const DIRECT_BASE = 'https://lrclib.net/api';

/** 同源代理地址（由 tools/serve.py 实现，缺失时自动跳过）。 */
const LOCAL_PROXY = 'api/lyrics';

/** localStorage 缓存键与容量。 */
const CACHE_KEY = 'light-music.lyrics-cache.v1';
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

// ---------------------------------------------------------------------------
// localStorage 缓存
// ---------------------------------------------------------------------------

/**
 * 读缓存表（损坏时返回空表）。
 * @returns {Record<string, {s?: string, p?: string, miss?: boolean, at: number}>}
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
  const wantTitle = query.trackName.toLowerCase();
  const wantArtist = query.artistName.toLowerCase();

  const scored = list.map((item) => {
    let score = 0;
    if (typeof item.syncedLyrics === 'string' && item.syncedLyrics.trim()) {
      score += 50;
    }
    const name = String(item.trackName ?? item.name ?? '').toLowerCase();
    if (name === wantTitle) {
      score += 30;
    } else if (name.includes(wantTitle) || wantTitle.includes(name)) {
      score += 12;
    }
    const artist = String(item.artistName ?? '').toLowerCase();
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
 * 先走同源代理，再走直连（带重试）；失败以结构化结果返回。
 * @param {{trackName: string, artistName: string, duration: number}} query 查询
 * @param {AbortSignal} [signal] 取消信号
 * @param {{refresh?: boolean}} [options] refresh=true 时让同源代理绕过自己的缓存
 * @returns {Promise<{status: string, syncedLyrics?: string, plainLyrics?: string, source?: string, message?: string}>}
 */
async function requestFromNetwork(query, signal, { refresh = false } = {}) {
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

  // 1) 同源代理（tools/serve.py）。服务端自己会重试并缓存，这里不重试。
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
        return { status: 'not-found' };
      }
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
    // 404 / 非 JSON：说明没有这个代理端点（纯静态部署），继续走直连
  } catch (error) {
    if (error?.name === 'AbortError' && signal?.aborted) {
      throw error;
    }
    // 代理不可用，静默降级到直连
  }

  // 2) 直连公共 API：带时长的精确匹配（可重试）
  /** get 命中可能只有纯文本；先留着，等搜索里的带时间轴版本把它们比下去 */
  let plainFallback = null;
  const preferSynced = (result) => Boolean(result && result.syncedLyrics && result.syncedLyrics.trim());

  if (query.duration > 0) {
    const exact = await requestJsonRetry(`${DIRECT_BASE}/get?${params.toString()}`, {
      timeout: TIMEOUT_DIRECT,
      signal,
      attempts: 2,
    });
    if (exact.ok) {
      const result = toResult(exact.data);
      if (preferSynced(result)) {
        return result;
      }
      plainFallback = result;
    } else if (exact.status !== 404) {
      return { status: 'error', message: describeFailure(exact) };
    }
  }

  // 3) 不带时长的 get 也能命中，体积小得多，比搜索快一个数量级
  const loose = await requestJsonRetry(`${DIRECT_BASE}/get?${baseParams.toString()}`, {
    timeout: TIMEOUT_DIRECT,
    signal,
    attempts: 2,
  });
  if (loose.ok) {
    const result = toResult(loose.data);
    if (preferSynced(result)) {
      return result;
    }
    plainFallback = plainFallback ?? result;
  } else if (loose.status !== 404) {
    return { status: 'error', message: describeFailure(loose) };
  }

  // 4) 没有带时间轴的版本时，用搜索接口再找一次（同步歌词常只出现在搜索结果里）
  const found = await requestJsonRetry(`${DIRECT_BASE}/search?${baseParams.toString()}`, {
    timeout: TIMEOUT_DIRECT,
    signal,
    attempts: 1,
  });
  if (found.ok) {
    const best = pickBest(found.data, query);
    if (best) {
      const result = toResult(best);
      if (preferSynced(result) || !plainFallback) {
        return result;
      }
      return plainFallback;
    }
    return plainFallback ?? { status: 'not-found' };
  }
  if (found.status === 404) {
    return plainFallback ?? { status: 'not-found' };
  }
  return plainFallback ?? { status: 'error', message: describeFailure(found) };
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
  const query = normalizeQuery(track);
  if (!query.trackName) {
    return { status: 'empty-query', message: '曲目信息不足，无法匹配歌词' };
  }

  if (useCache) {
    const cached = readCached(query.key);
    if (cached) {
      return cached;
    }
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
 * 清空歌词缓存（调试 / 设置里用）。
 * @returns {void}
 */
export function clearLyricsCache() {
  try {
    window.localStorage.removeItem(CACHE_KEY);
  } catch (error) {
    console.error('[lyrics-source] 清空歌词缓存失败：', error);
  }
}
