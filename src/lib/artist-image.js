/**
 * artist-image.js —— 按歌手名取「写真图」（维基百科条目配图）
 *
 * 用在链路第三层：内嵌标签没封面、iTunes 也没匹配到专辑图时，退而求其次
 * 拿一张**属于这位歌手**的照片，而不是跟这首歌无关的通用音符图。
 *
 * 两级通道（与 cover-source.js 同一套思路）：
 * 1) 同源代理 `api/artist-image`（tools/serve.py）：服务端查 zh → en 维基、
 *    把图片下载落盘，返回同源地址 —— 绕开防盗链与系统代理，首选；
 * 2) 浏览器直连维基 REST：纯静态部署（没有本地服务）时用。维基的 REST 接口
 *    带 `Access-Control-Allow-Origin: *`，可以直接 fetch，拿到的是远程图片地址。
 *
 * 结果（含「没找到」）按歌手名缓存进 localStorage，同一个歌手不再重复请求。
 * 注意：本机所在网络可能连不通 wikipedia.org（DNS 污染），这一层会稳定 miss，
 * 此时界面落到 generated-cover.js 的本地生成卡 —— 那是完全离线的，不会白屏。
 * 本模块不碰 DOM。
 */

/** 同源代理地址（由 tools/serve.py 实现）。 */
const LOCAL_PROXY = 'api/artist-image';

/** 直连的维基 REST 端点（zh 优先、en 兜底）。 */
const WIKI_LANGS = ['zh', 'en'];

/** localStorage 缓存键与容量。 */
const CACHE_KEY = 'light-music.artist-image.v1';
const MAX_CACHE_ENTRIES = 80;

/** 命中留 30 天；没找到只留 1 天（维基条目随时可能补图）。 */
const TTL_HIT = 30 * 24 * 60 * 60 * 1000;
const TTL_MISS = 24 * 60 * 60 * 1000;

/** 代理要搜索 + 下图，给足预算；直连只查元数据，12s 够了。 */
const TIMEOUT_PROXY = 25000;
const TIMEOUT_DIRECT = 12000;

/**
 * 歌手名归一成缓存键（大小写 / 全半角空格差异并到同一条）。
 * @param {string} artist 歌手名
 * @returns {string}
 */
export function normalizeArtistKey(artist) {
  return String(artist ?? '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/\u3000/g, ' ');
}

/**
 * 读缓存表（损坏时返回空表）。
 * @returns {Record<string, {url?: string, source?: string, miss?: boolean, at: number}>}
 */
function readCache() {
  try {
    const raw = window.localStorage.getItem(CACHE_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (error) {
    console.error('[artist-image] 读取缓存失败，已忽略：', error);
    return {};
  }
}

/**
 * 写缓存（超出容量时丢掉最旧的一批）。
 * @param {string} key 归一化后的歌手名
 * @param {object} value 结果
 * @returns {void}
 */
function writeCache(key, value) {
  try {
    const table = readCache();
    table[key] = { ...value, at: Date.now() };
    const entries = Object.entries(table);
    if (entries.length > MAX_CACHE_ENTRIES) {
      const trimmed = Object.fromEntries(
        entries.sort((a, b) => (b[1]?.at ?? 0) - (a[1]?.at ?? 0)).slice(0, MAX_CACHE_ENTRIES),
      );
      window.localStorage.setItem(CACHE_KEY, JSON.stringify(trimmed));
      return;
    }
    window.localStorage.setItem(CACHE_KEY, JSON.stringify(table));
  } catch (error) {
    console.error('[artist-image] 写入缓存失败：', error);
  }
}

/**
 * 取一条仍然有效的缓存。
 * @param {string} key 归一化后的歌手名
 * @returns {object|null}
 */
function readCached(key) {
  const entry = readCache()[key];
  if (!entry || typeof entry !== 'object') {
    return null;
  }
  const age = Date.now() - (entry.at ?? 0);
  if (entry.url) {
    return age < TTL_HIT ? { status: 'ok', url: entry.url, source: entry.source ?? '' } : null;
  }
  if (entry.miss) {
    return age < TTL_MISS ? { status: 'not-found' } : null;
  }
  return null;
}

/**
 * 带超时与取消的 JSON 请求。
 * @param {string} url 地址
 * @param {{timeout: number, signal?: AbortSignal}} options 选项
 * @returns {Promise<any|null>} 404 返回 null
 */
async function requestJson(url, { timeout, signal }) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeout);
  const onOuterAbort = () => controller.abort();
  signal?.addEventListener('abort', onOuterAbort);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { Accept: 'application/json', 'Api-User-Agent': 'light-music-player/1.0 (local dev)' },
    });
    if (response.status === 404) {
      return null;
    }
    if (!response.ok) {
      throw Object.assign(new Error(`HTTP ${response.status}`), { httpStatus: response.status });
    }
    return await response.json();
  } finally {
    window.clearTimeout(timer);
    signal?.removeEventListener('abort', onOuterAbort);
  }
}

/**
 * 从维基 REST 的页面摘要里挑一张能用的配图（优先原图，退回缩略图）。
 * @param {any} page 摘要 JSON
 * @returns {string}
 */
function pickImage(page) {
  const candidates = [page?.originalimage?.source, page?.thumbnail?.source];
  const found = candidates.find((url) => typeof url === 'string' && /^https?:\/\//i.test(url));
  return found ?? '';
}

/**
 * 直连维基 REST（纯静态部署时的一级通道）。
 * @param {string} artist 歌手名
 * @param {AbortSignal} [signal] 取消信号
 * @returns {Promise<object>} 与 matchArtistImage 同构的结果
 */
async function requestDirect(artist, signal) {
  for (const lang of WIKI_LANGS) {
    let page = null;
    try {
      page = await requestJson(
        `https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(artist.trim())}`,
        { timeout: TIMEOUT_DIRECT, signal },
      );
    } catch (error) {
      if (error?.name === 'AbortError' && signal?.aborted) {
        return { status: 'aborted' };
      }
      // 这一级连不上就换下一个语言，全失败再报错
      continue;
    }
    if (!page) {
      continue;
    }
    const url = pickImage(page);
    if (url) {
      return { status: 'ok', url, source: `Wikipedia（${lang}，直连）` };
    }
  }
  return { status: 'not-found' };
}

/**
 * 按歌手名匹配写真图。
 * @param {string} artist 歌手名
 * @param {{signal?: AbortSignal, useCache?: boolean}} [options] options
 * @returns {Promise<{status: 'ok'|'not-found'|'error'|'aborted', url?: string, source?: string, message?: string, reason?: string}>}
 */
export async function matchArtistImage(artist, { signal, useCache = true } = {}) {
  const name = String(artist ?? '').trim();
  const key = normalizeArtistKey(name);
  if (!key || key === '本地文件' || key === '未知歌手') {
    return { status: 'not-found' };
  }

  if (useCache) {
    const cached = readCached(key);
    if (cached) {
      return cached;
    }
  }

  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    return { status: 'error', reason: 'offline', message: '当前处于离线状态，无法获取歌手图片' };
  }

  // 1) 同源代理：服务端下图并落盘，前端拿同源地址
  try {
    const payload = await requestJson(`${LOCAL_PROXY}?name=${encodeURIComponent(name)}`, {
      timeout: TIMEOUT_PROXY,
      signal,
    });
    if (payload && typeof payload.status === 'string') {
      if (payload.status === 'ok' && payload.url) {
        writeCache(key, { url: payload.url, source: payload.source });
        return { status: 'ok', url: payload.url, source: payload.source ?? '' };
      }
      if (payload.status === 'not-found') {
        writeCache(key, { miss: true });
        return { status: 'not-found' };
      }
      return {
        status: 'error',
        reason: payload.reason ?? 'upstream',
        message: payload.message || '歌手图片源暂时不可用',
      };
    }
    // 404 / 非 JSON：没有本地服务，降级直连
  } catch (error) {
    if (error?.name === 'AbortError' && signal?.aborted) {
      return { status: 'aborted' };
    }
  }

  // 2) 浏览器直连维基 REST
  try {
    const direct = await requestDirect(name, signal);
    if (direct.status === 'ok') {
      writeCache(key, { url: direct.url, source: direct.source });
    } else if (direct.status === 'not-found') {
      writeCache(key, { miss: true });
    }
    return direct;
  } catch (error) {
    console.error('[artist-image] 匹配歌手图片失败：', name, error);
    return { status: 'error', reason: 'unreachable', message: '获取歌手图片失败' };
  }
}

/**
 * 清掉歌手图片缓存（设置里「重新匹配」时用）。
 * @returns {void}
 */
export function clearArtistImageCache() {
  try {
    window.localStorage.removeItem(CACHE_KEY);
  } catch (error) {
    console.error('[artist-image] 清空缓存失败：', error);
  }
}
