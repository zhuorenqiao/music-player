/**
 * translate-source.js —— 非中文歌词的中文译文
 *
 * 数据源：网易云音乐的 `song/lyric?tv=1`，返回的是**人工翻译**且带时间轴的 LRC。
 * 该接口不开 CORS，只能走同源代理 `api/translate`（src/server/music-api.ts）；
 * 纯静态部署没有这个代理，此时退回到 MyMemory 机翻接口（CORS 开放，可直接在
 * 网页里调用），并且在状态行明确标注「机翻」——人工译文仍然优先。
 *
 * 对齐思路：译文来自另一个曲库，时间轴和手上的歌词不会完全一致（同一首歌
 * 两边的行数、行首时间都不同，还可能整体偏移十几秒）。所以先用两边**原文相同
 * 的行**估出一个整体偏移，再把每条译文按时间落到「它所属的那一行歌词」上 ——
 * 即落在 [cue.time, cue.next.time) 区间里。区间内多条译文合并成一行显示。
 *
 * 判定语言只统计字符集，不做分词：中日韩按假名/谚文区分，纯汉字且占比够高才算中文。
 */

import { parseLRC } from './lyrics.js';
import { normalizeQuery, foldQuery, isOnline } from './lyrics-source.js';

/** 同源代理地址。 */
const LOCAL_PROXY = 'api/translate';

/**
 * localStorage 缓存键与容量（与歌词缓存分开，互不淘汰）。
 * v2：代理补上「曲名/歌手对调」候选之前存下的「查不到」是匹配器不全造成的假结论，整块作废重来。
 */
const CACHE_KEY = 'light-music.translate-cache.v2';
const MAX_CACHE_ENTRIES = 120;

/** 命中留 30 天；「没有译文」只留 3 天（译文库随时可能补录）。 */
const TTL_HIT = 30 * 24 * 60 * 60 * 1000;
const TTL_MISS = 3 * 24 * 60 * 60 * 1000;

/**
 * 超时（毫秒）。代理侧是「搜索 2 次重试 × 2 组关键词 + 取译文 2 次重试」，
 * 每步 8s，最坏接近 33s —— 前端预算必须比它长，否则我们先 abort、后端还在跑，
 * 用户看到的就是「连不上译文库」这种假原因。
 */
const TIMEOUT = 45000;

/**
 * 静态部署的机翻兜底。MyMemory 的免费接口带 CORS，网页可以直接调；
 * 单次查询上限 500 字符，所以按「整行」拼成不超过 450 字符的小包再发。
 * 逐行返回是它的既有行为（多行文本会保留换行），行数对不上时再逐行补一次。
 */
const MACHINE_ENDPOINT = 'https://api.mymemory.translated.net/get';
const MACHINE_CHUNK = 450;
const MACHINE_TIMEOUT = 20000;

/** 整体偏移的可信范围（秒）：超过这个量级说明锚点不可信，按 0 处理。 */
const MAX_SHIFT = 20;

/** 对齐质量下限：覆盖不到的行太多就当作没对上，宁可单语也不给半吊子双语。 */
const MIN_TIMED_COVERAGE = 0.25;
const MIN_PLAIN_COVERAGE = 0.5;

/**
 * 起手保护（秒）：译文行的时间戳离「下一句歌词」比离本句还近时，归给下一句。
 * 两个曲库的分句点经常差一两秒，不处理的话下一句的首词会挂到上一句尾巴上。
 */
const LEAD_IN = 1.5;

// ---------------------------------------------------------------------------
// 语言判定
// ---------------------------------------------------------------------------

/** 中日韩与其它常见字体的计数区间。 */
const SCRIPT_PATTERNS = {
  han: /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g,
  kana: /[\u3040-\u30ff]/g,
  hangul: /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]/g,
  latin: /[\u0041-\u007a\u00c0-\u024f]/g,
};

/** 去掉时间标签、元信息与逐字标签，只留正文再判语言。 */
function lyricBody(text) {
  return String(text ?? '')
    .replace(/\[[^\]\n]*\]/g, '')
    .replace(/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g, '');
}

/**
 * 这首歌的歌词需不需要配中文译文。
 *
 * 假名 / 谚文出现即判定外语（日语歌词里汉字很多，只看汉字会误判成中文）；
 * 汉字数量够多且占比够高才算中文歌词——中文歌常夹几句英文 hook，不该因此被当成外语。
 * @param {string} text 歌词原文
 * @returns {boolean}
 */
export function needsTranslation(text) {
  const body = lyricBody(text);
  if (!body.trim()) {
    return false;
  }
  const count = (pattern) => (body.match(pattern) || []).length;
  const kana = count(SCRIPT_PATTERNS.kana);
  const hangul = count(SCRIPT_PATTERNS.hangul);
  if (kana >= 3 || hangul > 0) {
    return true;
  }
  const han = count(SCRIPT_PATTERNS.han);
  const latin = count(SCRIPT_PATTERNS.latin);
  if (han + latin === 0) {
    // 西里尔、阿拉伯、泰文等：没有汉字也没有拉丁字母，一律当外语
    return body.trim().length > 0 && han === 0;
  }
  if (han < 8) {
    return latin > 0;
  }
  return han / (han + latin) < 0.35;
}

// ---------------------------------------------------------------------------
// localStorage 缓存（与歌词缓存同构，各存各的键）
// ---------------------------------------------------------------------------

/** @returns {Record<string, object>} */
function readCacheTable() {
  try {
    const raw = window.localStorage.getItem(CACHE_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (error) {
    console.error('[translate-source] 读取译文缓存失败，已忽略：', error);
    return {};
  }
}

/** @param {Record<string, object>} table @returns {void} */
function writeCacheTable(table) {
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
    console.error('[translate-source] 写入译文缓存失败：', error);
  }
}

/**
 * @param {string} key 查询键
 * @returns {{status?: string, translatedLyrics?: string, originalLyrics?: string, source?: string, reason?: string}|null}
 */
function readCached(key) {
  const entry = readCacheTable()[key];
  if (!entry || typeof entry.at !== 'number') {
    return null;
  }
  const isHit = entry.status === 'ok';
  if (Date.now() - entry.at > (isHit ? TTL_HIT : TTL_MISS)) {
    return null;
  }
  if (!isHit) {
    return { status: 'not-found', reason: entry.reason || 'song-not-matched' };
  }
  return {
    status: 'ok',
    translatedLyrics: typeof entry.t === 'string' ? entry.t : '',
    translatedLines: Array.isArray(entry.tl) ? entry.tl.map((line) => String(line ?? '')) : undefined,
    originalLyrics: typeof entry.o === 'string' ? entry.o : '',
    source: entry.src || '网易云译文库',
    machine: entry.m === true,
  };
}

/** @param {string} key @param {object} result @returns {void} */
function writeCached(key, result) {
  if (result.status !== 'ok' && result.status !== 'not-found') {
    return;
  }
  const table = readCacheTable();
  if (result.status === 'ok' && Array.isArray(result.translatedLines)) {
    // 机翻结果按「一行对一行」存，不存假时间轴：展示行变了也能直接对上。
    table[key] = {
      status: 'ok',
      tl: result.translatedLines,
      src: result.source,
      m: true,
      at: Date.now(),
    };
  } else {
    table[key] = result.status === 'ok'
      ? { status: 'ok', t: result.translatedLyrics || '', o: result.originalLyrics || '', src: result.source, at: Date.now() }
      : { status: 'not-found', reason: result.reason || 'song-not-matched', at: Date.now() };
  }
  writeCacheTable(table);
}

// ---------------------------------------------------------------------------
// 请求
// ---------------------------------------------------------------------------

/**
 * 请求一小包机器翻译。行数对不上时抛 `machine-lines`，由调用方退成逐行请求。
 * @param {string[]} lines 非空行
 * @param {AbortSignal} [signal]
 * @returns {Promise<string[]>}
 */
async function requestMachine(lines, signal) {
  const params = new URLSearchParams({ q: lines.join('\n'), langpair: 'Autodetect|zh-CN' });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MACHINE_TIMEOUT);
  const relay = () => controller.abort();
  if (signal) {
    if (signal.aborted) {
      controller.abort();
    } else {
      signal.addEventListener('abort', relay, { once: true });
    }
  }

  try {
    const response = await fetch(`${MACHINE_ENDPOINT}?${params.toString()}`, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
      credentials: 'omit',
      cache: 'no-store',
    });
    if (!response.ok) {
      throw new Error(`机器翻译返回 HTTP ${response.status}`);
    }
    const payload = await response.json();
    if (Number(payload?.responseStatus) !== 200) {
      const detail = String(payload?.responseDetails || '');
      const error = new Error(detail || '机器翻译失败');
      error.reason = /quota|limit|额度/i.test(detail) ? 'machine-quota' : 'machine';
      throw error;
    }
    const translated = String(payload?.responseData?.translatedText ?? '').replace(/\r/g, '');
    const parts = translated.split('\n').map((line) => line.trim());
    if (parts.length !== lines.length) {
      const error = new Error(`机器翻译行数对不上：${parts.length}/${lines.length}`);
      error.reason = 'machine-lines';
      throw error;
    }
    return parts;
  } finally {
    clearTimeout(timer);
    if (signal) {
      signal.removeEventListener('abort', relay);
    }
  }
}

/**
 * 静态部署的机翻兜底：把展示行按 450 字符一包发出去，结果按行号放回原位。
 * 返回结构与代理一致（`translatedLines` 已经是「一行对一行」，不再走时间轴对齐）。
 * @param {Array<{text?: string}|string>} lines 展示歌词行
 * @param {AbortSignal} [signal]
 */
async function machineTranslate(lines, signal) {
  const texts = (lines || []).map((line) => String(typeof line === 'string' ? line : line?.text ?? '').trim());
  if (texts.length === 0 || texts.every((text) => !text)) {
    return { status: 'unavailable' };
  }

  const out = texts.map(() => '');
  const groups = [];
  let group = [];
  let size = 0;
  texts.forEach((text, index) => {
    if (!text) {
      return;
    }
    if (group.length > 0 && size + text.length + 1 > MACHINE_CHUNK) {
      groups.push(group);
      group = [];
      size = 0;
    }
    group.push({ index, text });
    size += text.length + 1;
  });
  if (group.length > 0) {
    groups.push(group);
  }

  try {
    for (const items of groups) {
      try {
        const parts = await requestMachine(items.map((item) => item.text), signal);
        items.forEach((item, i) => {
          out[item.index] = parts[i] || '';
        });
      } catch (error) {
        if (signal?.aborted) {
          throw error;
        }
        if (error?.reason === 'machine-quota') {
          return { status: 'error', reason: 'machine-quota', message: '机器翻译额度已用完（仅网页静态版）' };
        }
        if (error?.name === 'AbortError') {
          throw error;
        }
        // 行数没对上 / 单包失败：这一包拆成逐行再试，慢一点但不会整首丢。
        for (const item of items) {
          const parts = await requestMachine([item.text], signal);
          out[item.index] = parts[0] || '';
        }
      }
    }
  } catch (error) {
    if (signal?.aborted) {
      throw error;
    }
    if (error?.reason === 'machine-quota') {
      return { status: 'error', reason: 'machine-quota', message: '机器翻译额度已用完（仅网页静态版）' };
    }
    if (error?.name === 'AbortError') {
      return { status: 'error', reason: 'machine-timeout', message: '机器翻译超时' };
    }
    return { status: 'error', reason: 'machine', message: '机器翻译失败' };
  }

  return {
    status: 'ok',
    translatedLines: out,
    originalLyrics: '',
    source: '机器翻译 · MyMemory',
    machine: true,
  };
}

/**
 * 向同源代理要这首歌的中文译文；静态部署（没有代理）时退回机翻。
 * 永不抛错（除主动取消），失败以 status 表达。
 * @param {object} track 曲目
 * @param {{signal?: AbortSignal, useCache?: boolean, lines?: Array<{text?: string}|string>}} [options]
 * @returns {Promise<{status: string, translatedLyrics?: string, translatedLines?: string[], originalLyrics?: string, source?: string, machine?: boolean, reason?: string, message?: string}>}
 */
export async function fetchTranslation(track, { signal, useCache = true, lines = [] } = {}) {
  // 网易云同样不认繁简：标签里的繁体歌手会直接搜不到（与歌词同一条根因）
  const query = foldQuery(normalizeQuery(track));
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
    return { status: 'error', reason: 'offline', message: '当前离线，无法获取中文译文' };
  }

  const params = new URLSearchParams({ track_name: query.trackName });
  if (query.artistName) {
    params.set('artist_name', query.artistName);
  }
  if (query.duration > 0) {
    params.set('duration', String(query.duration));
  }
  if (!useCache) {
    params.set('refresh', '1');
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT);
  const relay = () => controller.abort();
  if (signal) {
    if (signal.aborted) {
      controller.abort();
    } else {
      signal.addEventListener('abort', relay, { once: true });
    }
  }

  /** 机翻兜底：成功也写进同一份本地缓存，下次打开不再重复请求。 */
  const fallback = async () => {
    const result = await machineTranslate(lines, signal);
    writeCached(query.key, result);
    return result;
  };

  try {
    const response = await fetch(`${LOCAL_PROXY}?${params.toString()}`, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
      credentials: 'omit',
      cache: 'no-store',
    });
    // 纯静态部署：没有本地代理时改用机翻兜底，而不是让开关点了没反应
    if (response.status === 404 || response.status === 405) {
      return await fallback();
    }
    if (!response.ok) {
      return { status: 'error', reason: 'upstream', message: `译文库返回异常（HTTP ${response.status}）` };
    }
    /**
     * 静态部署时 /api/translate 会被 SPA 兜底成 index.html（HTTP 200 + HTML）。
     * 这不能算「连不上」——真实原因是没有本地代理，交给机翻兜底。
     */
    const contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('json')) {
      return await fallback();
    }
    const payload = await response.json();
    const result = {
      status: payload.status === 'ok' ? 'ok' : (payload.status === 'not-found' ? 'not-found' : 'error'),
      translatedLyrics: typeof payload.translatedLyrics === 'string' ? payload.translatedLyrics : '',
      originalLyrics: typeof payload.originalLyrics === 'string' ? payload.originalLyrics : '',
      source: payload.source || '网易云译文库',
      reason: payload.reason,
      message: payload.message,
    };
    writeCached(query.key, result);
    return result;
  } catch (error) {
    if (signal?.aborted) {
      throw error;
    }
    if (error?.name === 'AbortError') {
      return { status: 'error', reason: 'timeout', message: '获取中文译文超时，稍后会自动再试' };
    }
    // 代理连不上（例如本地服务没开、部署环境拦截）：还有展示行就退机翻
    return await fallback();
  } finally {
    clearTimeout(timer);
    if (signal) {
      signal.removeEventListener('abort', relay);
    }
  }
}

// ---------------------------------------------------------------------------
// 对齐
// ---------------------------------------------------------------------------

/** 归一化行文本，用于两边原文的锚点匹配。 */
function normalizeLine(text) {
  return String(text ?? '')
    .toLowerCase()
    .replace(/[\s　]/g, '')
    .replace(/[,.;:!?·、。，．：；!?'"「」『』（）()【】\[\]<>-]/g, '');
}

/** 同一时刻可能挂着原文 + 另一语种：译文要挂在这一组的第一行上。 */
function headOfSameTime(lines, index) {
  let at = index;
  while (at > 0 && lines[at - 1].time === lines[at].time) {
    at -= 1;
  }
  return at;
}

/** 二分：返回 time 落在哪一行（早于首行算第 0 行；同一时刻多行时取第一行）。 */
function cueIndexAt(lines, time) {
  if (lines.length === 0 || time <= lines[0].time) {
    return 0;
  }
  let low = 0;
  let high = lines.length - 1;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (lines[mid].time <= time) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return headOfSameTime(lines, low);
}

/**
 * 用两边原文里文本相同的行，估出「译文库时间轴 − 手上歌词时间轴」的整体偏移。
 * @param {Array<{time: number, text: string}>} lines 展示用的歌词行（带时间轴）
 * @param {Array<{time: number, text: string}>} anchors 同一首歌在译文库里的原文行
 * @returns {number} 秒；锚点不足时为 0
 */
function estimateShift(lines, anchors) {
  const firstAt = new Map();
  lines.forEach((line, index) => {
    const key = normalizeLine(line.text);
    if (key && !firstAt.has(key)) {
      firstAt.set(key, index);
    }
  });
  const diffs = [];
  anchors.forEach((anchor) => {
    const index = firstAt.get(normalizeLine(anchor.text));
    if (index !== undefined && Number.isFinite(anchor.time) && Number.isFinite(lines[index].time)) {
      diffs.push(anchor.time - lines[index].time);
    }
  });
  if (diffs.length < 3) {
    return 0;
  }
  diffs.sort((a, b) => a - b);
  const median = diffs[Math.floor(diffs.length / 2)];
  return Math.abs(median) > MAX_SHIFT ? 0 : median;
}

/** 同一个时间区间里的多条译文并成一行（网易原文里也用空格分隔这种断句）。 */
const joinFragments = (texts) => texts.join(' ').replace(/\s{2,}/g, ' ').trim();

/**
 * 把译文 LRC 落到展示行上。
 * @param {Array<{time?: number, text: string}>} lines 展示行：带时间轴的 cues，或纯文本行（time 为 NaN）
 * @param {string} translatedLrc 译文 LRC
 * @param {string} [originalLrc] 译文库那边的原文 LRC（用来估偏移 / 做文本匹配）
 * @returns {string[]} 与 lines 等长；没有对应译文的位置是空串
 */
export function alignTranslation(lines, translatedLrc, originalLrc) {
  const slots = lines.map(() => '');
  if (lines.length === 0 || !translatedLrc) {
    return slots;
  }
  const translated = parseLRC(translatedLrc).lines.filter((line) => line.text);
  if (translated.length === 0) {
    return slots;
  }
  const original = originalLrc ? parseLRC(originalLrc).lines.filter((line) => line.text) : [];

  const timed = lines.every((line) => Number.isFinite(line.time));
  if (timed) {
    const shift = estimateShift(lines, original);
    const buckets = lines.map(() => []);
    translated.forEach((line) => {
      const at = Math.max(0, line.time - shift);
      let index = cueIndexAt(lines, at);
      const next = lines[index + 1];
      // 起手保护：离下一句更近（且不早于本句起始）时归给下一句，并回到那一组的首行
      if (next && next.time > at && next.time - at <= LEAD_IN) {
        index = headOfSameTime(lines, index + 1);
      }
      buckets[index].push(line.text);
    });
    buckets.forEach((bucket, index) => {
      slots[index] = joinFragments(bucket);
    });
    const covered = slots.filter(Boolean).length / translated.length;
    return covered < MIN_TIMED_COVERAGE ? lines.map(() => '') : slots;
  }

  /**
   * 纯文本歌词没有时间轴，只能借译文库自己那份文件里的对应关系：
   * 同一份文件内原文与译文共用时间轴，先把译文按时间落到原文行上，
   * 再拿我们这行的文本去配那行原文。
   */
  const buckets = original.map(() => []);
  if (original.length > 0) {
    translated.forEach((line) => {
      let index = 0;
      while (index + 1 < original.length && original[index + 1].time <= line.time) {
        index += 1;
      }
      buckets[index].push(line.text);
    });
  }
  const byKey = new Map();
  original.forEach((line, index) => {
    const key = normalizeLine(line.text);
    const text = joinFragments(buckets[index]);
    if (key && text && !byKey.has(key)) {
      byKey.set(key, text);
    }
  });
  let matched = 0;
  lines.forEach((line, index) => {
    const found = byKey.get(normalizeLine(line.text));
    if (found) {
      slots[index] = found;
      matched += 1;
    }
  });
  if (matched / lines.length >= MIN_PLAIN_COVERAGE) {
    return slots;
  }
  /**
   * 配不上就退回单语。两个库分句不同（这边一行 = 那边两行）时按顺序硬对
   * 实测会把「你美梦成真」配到「已经步入婚姻殿堂」下面 —— 错行的译文比没有译文更糟。
   */
  return lines.map(() => '');
}
