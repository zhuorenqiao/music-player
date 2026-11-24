/**
 * music-api.ts —— 开发期的四个同源代理（Vite 中间件版）
 *
 * 前三个是 ../tools/serve.py 里那三个端口的 Node/TS 移植，行为对齐、响应结构一致，
 * 所以前端那几个图源模块（lyrics-source / cover-source / artist-image）可以原样复用；
 * `/api/translate` 是后加的，serve.py 里没有对应实现：
 *
 *   GET /api/lyrics?track_name&artist_name&duration   → LRCLIB → 汽水 → 酷狗 → 网易云
 *   GET /api/translate?track_name&artist_name&duration → 网易云中文译文库（人工翻译）
 *   GET /api/cover?title&artist&duration              → iTunes Search + 图片落盘
 *   GET /api/cover/img?id=<40hex>                     → 已缓存的封面字节
 *   GET /api/artist-image?name                        → 维基百科条目配图
 *   GET /api/artist-image/img?id=<40hex>              → 已缓存的配图字节
 *
 * 与 Python 版的两处有意差异：
 * 1) 缓存目录是本项目的 `.cache/`（不与 vanilla 版共用），换目录见 CACHE_ROOT；
 * 2) 上游请求走 Node 全局 fetch，**不读系统代理**。要走代理请设 `HTTPS_PROXY`
 *    并用 undici 的 ProxyAgent（本机实测：iTunes 0.4s 直连可用，维基被 DNS 污染，
 *    代理进程又没开 —— 与 Python 版表现一致）。
 */

import { createHash } from 'node:crypto';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { ViteDevServer } from 'vite';
import type { ServerResponse } from 'node:http';
import { toSimplified } from '../lib/chinese';
import {
  candidateKeyword,
  looksSynced,
  neteaseCandidates,
  parseNetEaseSongs,
  pickNetEaseSong,
  stripLeadingCredits,
  type NetEaseSong,
} from '../lib/netease-match';
import { fetchKugouLyrics, fetchQishuiLyrics } from './lyrics-providers';

// -- 常量（与 serve.py 同源同值）---------------------------------------------

/** 缓存根目录；想用绝对路径就设环境变量 MUSIC_CACHE_ROOT。 */
const CACHE_ROOT = resolve(process.env.MUSIC_CACHE_ROOT ?? '.cache');
/**
 * 2026-11-23 起 LRCLIB 是第一优先（链路：LRCLIB → 汽水 → 酷狗 → 网易云），
 * 换目录 = 换缓存纪元，旧 lyrics-v3/v2/v1 原样留在原地当孤儿（不再读、不再写）。
 */
const LYRICS_DIR = join(CACHE_ROOT, 'lyrics-v4');
const TRANSLATE_DIR = join(CACHE_ROOT, 'translate');
const COVER_META_DIR = join(CACHE_ROOT, 'covers', 'meta');
const COVER_IMG_DIR = join(CACHE_ROOT, 'covers', 'img');
const ARTIST_META_DIR = join(CACHE_ROOT, 'artists', 'meta');
const ARTIST_IMG_DIR = join(CACHE_ROOT, 'artists', 'img');

const LYRICS_UPSTREAM = 'https://lrclib.net/api';
/** 中文译文：网易云的 tlyric 是人工翻译且带时间轴，本机实测 0.2s 可达、免密钥。 */
const NETEASE_SEARCH = 'https://music.163.com/api/search/get';
const NETEASE_LYRIC = 'https://music.163.com/api/song/lyric';
const ITUNES_SEARCH = 'https://itunes.apple.com/search';

/** 命中留 30 天；「没找到」只留 3 天（曲库随时可能补录）。 */
const TTL_HIT = 30 * 24 * 60 * 60 * 1000;
const TTL_MISS = 3 * 24 * 60 * 60 * 1000;

/** 单路上游超时；歌词多路并行，总墙钟约等于最慢的一路。 */
const LYRICS_GET_TIMEOUT = 12_000;
const LYRICS_GET_ATTEMPTS = 2;
const LYRICS_SEARCH_TIMEOUT = 26_000;
const TRANSLATE_TIMEOUT = 8_000;
const COVER_TIMEOUT = 10_000;
const ARTIST_TIMEOUT = 8_000;
const IMAGE_TIMEOUT = 15_000;

/** 图片体积下限/上限：小于 2KB 多半是占位图，大于 2MB 视为异常。 */
const MIN_IMAGE_BYTES = 2048;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

const UPSTREAM_HEADERS = {
  Accept: 'application/json',
  'User-Agent': 'light-music-react/1.0 (+vite dev middleware)',
};

// -- 错误分类 ---------------------------------------------------------------

type UpstreamReason = 'rate-limit' | 'timeout' | 'unreachable' | 'upstream';

/** 上游失败的统一表示：reason 给前端决定措辞，message 是给人看的中文。 */
class UpstreamError extends Error {
  readonly reason: UpstreamReason;

  readonly retryAfter: number | null;

  constructor(reason: UpstreamReason, message: string, retryAfter: number | null = null) {
    super(message);
    this.name = 'UpstreamError';
    this.reason = reason;
    this.retryAfter = retryAfter;
  }
}

function classifyError(error: unknown, source = '歌词库'): UpstreamError {
  if (error instanceof UpstreamError) {
    return error;
  }
  const text = `${(error as Error)?.name ?? ''} ${(error as Error)?.message ?? ''}`.toLowerCase();
  if (text.includes('timeout') || text.includes('aborterror') || text.includes('timed out')) {
    return new UpstreamError('timeout', `连接${source}超时（本机到该站点较慢，稍等会自动重试）`);
  }
  return new UpstreamError('unreachable', `连不上${source}，请检查网络或代理设置`);
}

/** 多路都失败时，挑一条最能说明问题的报给用户。 */
function worstError(errors: UpstreamError[]): UpstreamError {
  const order: Record<UpstreamReason, number> = { 'rate-limit': 0, timeout: 1, unreachable: 2, upstream: 3 };
  return [...errors].sort((a, b) => order[a.reason] - order[b.reason])[0];
}

// -- 小工具 -----------------------------------------------------------------

const sha1 = (text: string): string => createHash('sha1').update(text, 'utf8').digest('hex');

async function fetchJson(url: string, timeoutMs: number): Promise<unknown> {
  const response = await fetch(url, { headers: UPSTREAM_HEADERS, signal: AbortSignal.timeout(timeoutMs) });
  if (response.status === 404) {
    return null;
  }
  if (response.status === 429 || response.status === 503) {
    const header = Number(response.headers.get('retry-after'));
    throw new UpstreamError('rate-limit', `歌词库正在限流（HTTP ${response.status}）`, Number.isFinite(header) ? header : null);
  }
  if (!response.ok) {
    throw new UpstreamError('upstream', `${response.status >= 500 ? '服务暂时不可用' : '返回异常'}（HTTP ${response.status}）`);
  }
  return await response.json();
}

/** 带重试的 JSON 抓取：只对超时/网络错误重试，限流与 4xx 直接抛。 */
async function fetchJsonWithRetry(url: string, timeoutMs: number, attempts = 1): Promise<unknown> {
  let last: unknown = null;
  for (let index = 0; index < attempts; index += 1) {
    try {
      return await fetchJson(url, timeoutMs);
    } catch (error) {
      last = error;
      const classified = classifyError(error);
      if (classified.reason === 'rate-limit' || classified.reason === 'upstream') {
        throw classified;
      }
      if (index < attempts - 1) {
        await new Promise((r) => setTimeout(r, 400));
      }
    }
  }
  throw classifyError(last);
}

async function downloadImage(url: string, timeoutMs: number): Promise<Buffer | null> {
  try {
    const response = await fetch(url, {
      headers: { ...UPSTREAM_HEADERS, Accept: 'image/*' },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      return null;
    }
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.byteLength < MIN_IMAGE_BYTES || buffer.byteLength > MAX_IMAGE_BYTES) {
      return null;
    }
    return buffer;
  } catch {
    return null;
  }
}

/** 按魔数判断图片类型（维基配图可能是 PNG，不能一律当 JPEG 发）。 */
function sniffImageMime(bytes: Buffer): string {
  if (bytes.subarray(0, 4).toString('latin1') === '\x89PNG') return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.subarray(0, 4).toString('latin1') === 'GIF8') return 'image/gif';
  if (bytes.subarray(0, 4).toString('latin1') === 'RIFF' && bytes.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
  return '';
}

interface CacheEntry {
  status?: string;
  [key: string]: unknown;
}

async function readCache(dir: string, key: string, options: { allowStale?: boolean; allowMiss?: boolean } = {}): Promise<CacheEntry | null> {
  const { allowStale = false, allowMiss = true } = options;
  try {
    const text = await readFile(join(dir, `${key}.json`), 'utf8');
    const data = JSON.parse(text) as CacheEntry;
    const isHit = data.status === 'ok';
    if (!isHit && !allowMiss) {
      return null;
    }
    if (!allowStale) {
      const info = await stat(join(dir, `${key}.json`));
      const ttl = isHit ? TTL_HIT : TTL_MISS;
      if (Date.now() - info.mtimeMs > ttl) {
        return null;
      }
    }
    return data;
  } catch {
    return null;
  }
}

async function writeCache(dir: string, key: string, payload: CacheEntry): Promise<void> {
  try {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, `${key}.json`), JSON.stringify(payload), 'utf8');
  } catch {
    // 缓存写失败不影响本次响应
  }
}

async function writeImage(dir: string, id: string, bytes: Buffer): Promise<void> {
  try {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, `${id}.bin`), bytes);
  } catch {
    // 同上
  }
}

// -- 歌词 -------------------------------------------------------------------

interface LyricsRecord {
  trackName?: string;
  name?: string;
  artistName?: string;
  duration?: number;
  syncedLyrics?: string;
  plainLyrics?: string;
}

interface LyricsResult extends CacheEntry {
  status: 'ok' | 'not-found';
  syncedLyrics?: string;
  plainLyrics?: string;
  source?: string;
  trackName?: string;
  artistName?: string;
  duration?: number;
}

function toLyricsResult(record: LyricsRecord | null | undefined): LyricsResult {
  const synced = typeof record?.syncedLyrics === 'string' ? record.syncedLyrics : '';
  const plain = typeof record?.plainLyrics === 'string' ? record.plainLyrics : '';
  if (!record || (!synced && !plain)) {
    return { status: 'not-found' };
  }
  return {
    status: 'ok',
    syncedLyrics: synced,
    plainLyrics: plain,
    source: 'LRCLIB',
    trackName: record.trackName ?? record.name ?? '',
    artistName: record.artistName ?? '',
    duration: record.duration,
  };
}

/** 从搜索结果里挑最合适的一条：优先有时间轴，其次标题/歌手/时长接近。 */
function pickBestLyrics(items: unknown, trackName: string, artistName: string, duration: string): LyricsRecord | null {
  if (!Array.isArray(items) || items.length === 0) {
    return null;
  }
  // 曲名/歌手折到简体再比：上游候选可能写成繁体，逐字比会白丢分
  const wantTitle = toSimplified(trackName).toLowerCase();
  const wantArtist = toSimplified(artistName).toLowerCase();
  const wantDuration = Number(duration) > 0 ? Number(duration) : 0;

  let best: LyricsRecord | null = null;
  let bestScore = 0;
  for (const raw of items) {
    const item = raw as LyricsRecord;
    let score = 0;
    if ((item.syncedLyrics ?? '').trim()) score += 50;
    const name = toSimplified(item.trackName ?? item.name ?? '').toLowerCase();
    if (name && name === wantTitle) score += 30;
    else if (name && (name.includes(wantTitle) || wantTitle.includes(name))) score += 12;
    const artist = toSimplified(item.artistName ?? '').toLowerCase();
    if (wantArtist && artist === wantArtist) score += 25;
    else if (wantArtist && artist.includes(wantArtist)) score += 10;
    const itemDuration = Number(item.duration);
    if (wantDuration > 0 && Number.isFinite(itemDuration)) {
      const diff = Math.abs(itemDuration - wantDuration);
      if (diff <= 2) score += 30;
      else if (diff <= 6) score += 12;
      else if (diff > 25) score -= 25;
    }
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return best;
}

/**
 * （歌名, 歌手）候选。
 *
 * 文件名既可能是「歌手 - 歌名」也可能是「歌名 - 歌手」，前端拆反时查询参数就是反的、
 * 永远查不到 —— 对调再试一次几乎零成本，命中后两个 key 都写缓存。
 */
function lyricsPairs(trackName: string, artistName: string): Array<[string, string]> {
  const pairs: Array<[string, string]> = [[trackName, artistName]];
  if (artistName && artistName !== trackName) {
    pairs.push([artistName, trackName]);
  }
  return pairs;
}

/**
 * 查询参数的原字形（折叠前）——只用于「简体那几路全没命中」时补一次原字形搜索。
 */
interface RawQuery {
  trackName: string;
  artistName: string;
}

/**
 * 歌词主链（2026-11-23）：LRCLIB → 汽水 → 酷狗 → 网易云。
 *
 * LRCLIB 先跑完整的多路 get / search；它没词或上游失败时才静默落到下一家。
 * 后三家同样只当「补位」：没词、认不到、上游失败都继续往下，不能把结果改写成网络错误。
 * 如果 LRCLIB 是**失败**（不是 not-found）且三家补位也没词，最终把那条例外的
 * 错误抛出去 —— 限流 / 超时不该被说成「未找到」。
 */
async function fetchLyrics(trackName: string, artistName: string, duration: string, raw?: RawQuery): Promise<LyricsResult> {
  const seconds = Number(duration) || 0;

  let lrclibFailure: UpstreamError | null = null;
  try {
    const lrclib = await fetchLrclibLyrics(trackName, artistName, duration, raw);
    if (lrclib.status === 'ok') {
      return lrclib;
    }
  } catch (error) {
    lrclibFailure = classifyError(error);
  }

  try {
    const qishui = await fetchQishuiLyrics(trackName, artistName.trim(), seconds);
    if (qishui) {
      return qishui;
    }
  } catch {
    // 静默：汽水的问题不影响后面的源。
  }
  try {
    const kugou = await fetchKugouLyrics(trackName, artistName.trim(), seconds);
    if (kugou) {
      return kugou;
    }
  } catch {
    // 同上。
  }
  try {
    const netease = await fetchNetEaseLyrics(trackName, artistName, seconds);
    if (netease) {
      return netease;
    }
  } catch {
    // 同上：吞掉，别让上游的问题冒充最终结论。
  }

  if (lrclibFailure) {
    throw lrclibFailure;
  }
  return { status: 'not-found' };
}

/** LRCLIB 的多路并行取词：原方向 / 对调方向的 get，加一条 search，全部等完再裁决。 */
async function fetchLrclibLyrics(trackName: string, artistName: string, duration: string, raw?: RawQuery): Promise<LyricsResult> {
  const jobs: Array<{ kind: 'get' | 'search'; run: () => Promise<LyricsResult> }> = [];

  for (const [name, artist] of lyricsPairs(trackName, artistName)) {
    const base = new URLSearchParams({ track_name: name });
    if (artist) {
      base.set('artist_name', artist);
    }
    if (duration) {
      const withDuration = new URLSearchParams(base);
      withDuration.set('duration', duration);
      jobs.push({
        kind: 'get',
        run: async () => toLyricsResult(await fetchJsonWithRetry(`${LYRICS_UPSTREAM}/get?${withDuration}`, LYRICS_GET_TIMEOUT, LYRICS_GET_ATTEMPTS) as LyricsRecord | null),
      });
    }
    jobs.push({
      kind: 'get',
      run: async () => toLyricsResult(await fetchJsonWithRetry(`${LYRICS_UPSTREAM}/get?${base}`, LYRICS_GET_TIMEOUT, LYRICS_GET_ATTEMPTS) as LyricsRecord | null),
    });
  }
  const loose = [trackName, artistName].filter(Boolean).join(' ');
  jobs.push({
    kind: 'search',
    run: async () => {
      const items = await fetchJsonWithRetry(`${LYRICS_UPSTREAM}/search?${new URLSearchParams({ q: loose })}`, LYRICS_SEARCH_TIMEOUT, 1);
      const want = lyricsPairs(trackName, artistName)[0];
      return toLyricsResult(pickBestLyrics(items, want[0], want[1], duration));
    },
  });

  // 全部并行；get 命中优先，search 命中兜底
  const settled = await Promise.allSettled(jobs.map((job) => job.run()));
  const errors: UpstreamError[] = [];
  const getErrors: UpstreamError[] = [];
  let getHit: LyricsResult | null = null;
  let searchHit: LyricsResult | null = null;

  settled.forEach((entry, index) => {
    const kind = jobs[index].kind;
    if (entry.status === 'fulfilled') {
      if (entry.value.status !== 'ok') {
        return;
      }
      if (kind === 'get') {
        getHit = getHit ?? entry.value;
      } else {
        searchHit = searchHit ?? entry.value;
      }
      return;
    }
    const classified = classifyError(entry.reason);
    errors.push(classified);
    if (kind === 'get') {
      getErrors.push(classified);
    }
  });

  const hasSynced = (hit: LyricsResult | null): boolean => Boolean(hit && (hit.syncedLyrics ?? '').trim());

  /**
   * 带时间轴的版本优先，哪怕它来自 search：`get` 命中可能只有纯文本，
   * 而同一首歌在搜索结果里常有带时间轴的记录（例如「湘女多情-周杰伦」）。
   * 只用 get 的纯文本会把逐行高亮白白丢掉。
   */
  if (getHit && hasSynced(getHit)) {
    return getHit;
  }
  if (searchHit && hasSynced(searchHit)) {
    return searchHit;
  }
  if (getHit) {
    return getHit;
  }
  /**
   * `get` 是权威那一路（参数就是这首歌）。它一次都没跑通时，
   * 哪怕 `search` 返回了空列表也不能断言「曲库里没有」—— 那正是把限流
   * 说成「未找到」、让用户以为功能坏了的根源。此时宁可报错让前端重试。
   */
  if (getErrors.length > 0) {
    throw worstError(getErrors);
  }
  if (searchHit) {
    return searchHit;
  }
  if (errors.length > 0) {
    throw worstError(errors);
  }
  /**
   * 简体那几路都没命中，而标签本来是繁体时，再按原字形搜一次：
   * 上游偶尔只收了繁体条目（折叠后 get 404、search 也是 0 条）。
   * 只补 search，失败不改写结论 —— 主路径已经正常判定 not-found。
   */
  if (raw && (raw.trackName !== trackName || raw.artistName !== artistName)) {
    const loose = [raw.trackName, raw.artistName].filter(Boolean).join(' ');
    if (loose) {
      try {
        const items = await fetchJsonWithRetry(
          `${LYRICS_UPSTREAM}/search?${new URLSearchParams({ q: loose })}`,
          LYRICS_GET_TIMEOUT,
          1,
        );
        const hit = toLyricsResult(pickBestLyrics(items, trackName, artistName, duration));
        if (hit.status === 'ok') {
          return hit;
        }
      } catch {
        // 补救失败不影响「未找到」
      }
    }
  }
  return { status: 'not-found' };
}

// -- 中文译文 ---------------------------------------------------------------

interface TranslateResult extends CacheEntry {
  status: 'ok' | 'not-found';
  reason?: string;
  translatedLyrics?: string;
  originalLyrics?: string;
  source?: string;
  songId?: number;
  songName?: string;
  songArtist?: string;
}

/** 匹配用的归一化 / 歌名本体 / 歌手证据 / 认歌规则都在 lib/netease-match.ts（三处共用）。 */

/** 本地文件没标签时的占位歌手，拿去当搜索词只会污染结果。 */
const PLACEHOLDER_ARTISTS = new Set(['本地文件', '未知歌手', '未知', 'unknown', 'various artists']);

/** 网易云搜索：一次 20 条（与译文链路同参）。 */
async function searchNetEaseSongs(keyword: string): Promise<ReturnType<typeof parseNetEaseSongs>> {
  const url = `${NETEASE_SEARCH}?${new URLSearchParams({ s: keyword, type: '1', limit: '20' })}`;
  return parseNetEaseSongs(await fetchJsonWithRetry(url, TRANSLATE_TIMEOUT, 2));
}

/**
 * 网易云歌词：认歌 → 取 `lrc.lyric` → 归一成 LyricsResult；没词 / 认不到返回 null。
 *
 * 与译文链路同一套候选与认歌门槛：错配一首歌的歌词和错配整页译文一样糟，
 * 宁可返回 null 交给 LRCLIB，也不给一首错的词。
 * 单个候选失败不放弃整次尝试；全部失败也只是 null —— 网易云只是「优先」。
 */
async function fetchNetEaseLyrics(trackName: string, artistName: string, duration: number): Promise<LyricsResult | null> {
  const artist = PLACEHOLDER_ARTISTS.has(artistName.trim().toLowerCase()) ? '' : artistName.trim();
  const candidates = neteaseCandidates(trackName, artist);
  /** 歌手字段写得花哨（「Coldplay / Beyoncé」「feat. X」）时，只搜歌名常常才是对的 */
  if (artist) {
    candidates.push({ name: trackName, artist: '', strict: false });
  }
  const tried = new Set<number>();
  for (const candidate of candidates) {
    const keyword = candidateKeyword(candidate);
    if (!keyword) {
      continue;
    }
    try {
      const songs = await searchNetEaseSongs(keyword);
      const song = pickNetEaseSong(songs, {
        trackName: candidate.name,
        artistName: candidate.artist,
        duration,
        strict: candidate.strict,
      });
      if (!song || tried.has(song.id)) {
        continue;
      }
      // 同一首歌被多个候选认出来时只取一次词（纯音乐 / 未收录会被反复认到）。
      tried.add(song.id);
      const data = await fetchJsonWithRetry(
        `${NETEASE_LYRIC}?${new URLSearchParams({ id: String(song.id), lv: '1' })}`,
        TRANSLATE_TIMEOUT,
        1,
      ) as { lrc?: { lyric?: string }; nolyric?: boolean; uncollected?: boolean } | null;
      if (data?.nolyric || data?.uncollected) {
        continue;
      }
      const lyric = typeof data?.lrc?.lyric === 'string' ? data.lrc.lyric : '';
      if (!lyric.trim()) {
        continue;
      }
      // 网易云带一串带时间轴的制作署名：解析器只清前 4 行，这里先剥干净开头。
      const body = stripLeadingCredits(lyric);
      if (!body.trim()) {
        continue;
      }
      const synced = looksSynced(body);
      return {
        status: 'ok',
        syncedLyrics: synced ? body : '',
        plainLyrics: synced ? '' : body,
        source: '网易云音乐',
        trackName: song.name,
        artistName: song.artists.join(' / '),
        duration: Math.round(song.durationMs / 1000),
      };
    } catch {
      // 单个候选搜挂了（超时 / 连不上 / 限流）不放弃整次尝试，试下一个。
      continue;
    }
  }
  return null;
}

async function fetchTranslation(trackName: string, artistName: string, duration: number): Promise<TranslateResult> {
  const artist = PLACEHOLDER_ARTISTS.has(artistName.trim().toLowerCase()) ? '' : artistName.trim();
  const candidates = neteaseCandidates(trackName, artist);
  /** 歌手字段写得花哨（「Coldplay / Beyoncé」「feat. X」）时，只搜歌名常常才是对的 */
  candidates.push({ name: trackName, artist: '', strict: false });

  const errors: UpstreamError[] = [];
  let matched: NetEaseSong | null = null;
  for (const candidate of candidates) {
    const keyword = candidateKeyword(candidate);
    if (!keyword) {
      continue;
    }
    try {
      matched = pickNetEaseSong(await searchNetEaseSongs(keyword), {
        trackName: candidate.name,
        artistName: candidate.artist,
        duration,
        strict: candidate.strict,
      });
    } catch (error) {
      errors.push(classifyError(error, '译文库'));
      continue;
    }
    if (matched) {
      break;
    }
  }
  const song = matched;
  if (!song) {
    /**
     * 搜索全失败（超时/连不上）时报错而不是「未收录」：
     * 把网络问题说成「这首歌没有译文」，用户就会以为功能坏了。
     */
    if (errors.length > 0) {
      throw worstError(errors);
    }
    return { status: 'not-found', reason: 'song-not-matched' };
  }

  const data = await fetchJsonWithRetry(
    `${NETEASE_LYRIC}?${new URLSearchParams({ id: String(song.id), lv: '1', tv: '1' })}`,
    TRANSLATE_TIMEOUT,
    2,
  ) as { lrc?: { lyric?: string }; tlyric?: { lyric?: string } } | null;
  const translated = typeof data?.tlyric?.lyric === 'string' ? data.tlyric.lyric : '';
  const original = typeof data?.lrc?.lyric === 'string' ? data.lrc.lyric : '';
  if (!translated.trim()) {
    return { status: 'not-found', reason: 'no-translation' };
  }
  return {
    status: 'ok',
    translatedLyrics: translated,
    originalLyrics: original,
    source: '网易云译文库（人工翻译）',
    songId: song.id,
    songName: song.name,
    songArtist: song.artists.join(' / '),
  };
}

// -- 封面 -------------------------------------------------------------------

interface ItunesItem {
  trackName?: string;
  artistName?: string;
  collectionName?: string;
  artworkUrl100?: string;
  trackTimeMillis?: number;
}

function pickCover(items: unknown, title: string, artist: string, duration: string): { item: ItunesItem; score: number } | null {
  if (!Array.isArray(items)) {
    return null;
  }
  const wantTitle = title.toLowerCase();
  const wantArtist = artist.toLowerCase();
  const wantDuration = Number(duration) > 0 ? Number(duration) : 0;

  let best: { item: ItunesItem; score: number } | null = null;
  for (const raw of items) {
    const item = raw as ItunesItem;
    if (!item?.artworkUrl100) {
      continue;
    }
    let score = 0;
    const name = (item.trackName ?? '').toLowerCase();
    const titleExact = Boolean(wantTitle) && name === wantTitle;
    if (titleExact) score += 30;
    else if (wantTitle && (name.includes(wantTitle) || wantTitle.includes(name))) score += 12;
    const itemArtist = (item.artistName ?? '').toLowerCase();
    if (wantArtist && itemArtist === wantArtist) score += 25;
    else if (wantArtist && (itemArtist.includes(wantArtist) || wantArtist.includes(itemArtist))) score += 10;
    const millis = Number(item.trackTimeMillis);
    if (wantDuration > 0 && Number.isFinite(millis) && millis > 0) {
      const diff = Math.abs(millis / 1000 - wantDuration);
      if (diff <= 2) score += 20;
      else if (diff <= 6) score += 8;
      else if (diff > 25) score -= 25;
    }
    if (!best || score > best.score) {
      best = { item, score };
    }
  }
  if (!best) {
    return null;
  }
  // 接受门槛：歌名完全一致，或歌手对得上；否则给错封面不如不给
  const name = (best.item.trackName ?? '').toLowerCase();
  const itemArtist = (best.item.artistName ?? '').toLowerCase();
  const titleExact = Boolean(wantTitle) && name === wantTitle;
  const artistMatch = Boolean(wantArtist) && (itemArtist.includes(wantArtist) || wantArtist.includes(itemArtist));
  if (best.score < 18 || !(titleExact || artistMatch)) {
    return null;
  }
  return best;
}

/** iTunes 的 100x100 缩略图换成 600x600 大图（同一 CDN 同一路径规则）。 */
const artworkBig = (url: string): string => url.replace(/\/\d+x\d+bb\.(\w+)$/, '/600x600bb.$1');

async function fetchCover(title: string, artist: string, duration: string): Promise<CacheEntry> {
  const term = artist ? `${artist} ${title}` : title;
  const queries = [
    new URLSearchParams({ term, entity: 'song', media: 'music', limit: '8', country: 'CN' }),
    new URLSearchParams({ term, entity: 'song', media: 'music', limit: '8' }),
  ];

  let best: { item: ItunesItem; score: number } | null = null;
  for (const params of queries) {
    try {
      const data = (await fetchJsonWithRetry(`${ITUNES_SEARCH}?${params}`, COVER_TIMEOUT, 1)) as { results?: unknown } | null;
      const candidate = pickCover(data?.results, title, artist, duration);
      if (candidate && (!best || candidate.score > best.score)) {
        best = candidate;
      }
    } catch {
      // 一个区失败不影响另一个区
    }
  }
  if (!best?.item.artworkUrl100) {
    return { status: 'not-found' };
  }
  const image = await downloadImage(artworkBig(best.item.artworkUrl100), IMAGE_TIMEOUT);
  if (!image) {
    return { status: 'not-found' };
  }
  const imageId = sha1(`${title}|${artist}`.toLowerCase());
  await writeImage(COVER_IMG_DIR, imageId, image);
  return {
    status: 'ok',
    url: `/api/cover/img?id=${imageId}`,
    source: 'iTunes',
    trackName: best.item.trackName ?? '',
    artistName: best.item.artistName ?? '',
    album: best.item.collectionName ?? '',
  };
}

// -- 歌手写真图 -------------------------------------------------------------

interface WikiSummary {
  title?: string;
  originalimage?: { source?: string };
  thumbnail?: { source?: string };
}

async function fetchArtistImage(name: string): Promise<CacheEntry> {
  const errors: UpstreamError[] = [];
  for (const lang of ['zh', 'en'] as const) {
    const url = `https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(name.trim())}`;
    let page: WikiSummary | null = null;
    try {
      page = (await fetchJson(url, ARTIST_TIMEOUT)) as WikiSummary | null;
    } catch (error) {
      errors.push(classifyError(error, '维基'));
      continue;
    }
    const image = page?.originalimage?.source ?? page?.thumbnail?.source ?? '';
    if (!/^https?:\/\//i.test(image)) {
      continue;
    }
    const bytes = await downloadImage(image, ARTIST_TIMEOUT);
    if (!bytes) {
      continue;
    }
    const imageId = sha1(image);
    await writeImage(ARTIST_IMG_DIR, imageId, bytes);
    return {
      status: 'ok',
      url: `/api/artist-image/img?id=${imageId}`,
      source: `Wikipedia（${lang}）`,
      artistName: page?.title ?? name,
    };
  }
  if (errors.length > 0) {
    throw worstError(errors);
  }
  return { status: 'not-found' };
}

// -- 路由 -------------------------------------------------------------------

function sendJson(res: ServerResponse, status: number, payload: CacheEntry): void {
  const body = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(body);
}

async function serveCachedImage(res: ServerResponse, dir: string, rawId: string, label: string): Promise<void> {
  if (!/^[0-9a-f]{40}$/.test(rawId)) {
    sendJson(res, 400, { status: 'error', message: `Invalid ${label} id` });
    return;
  }
  try {
    const bytes = await readFile(join(dir, `${rawId}.bin`));
    res.statusCode = 200;
    res.setHeader('Content-Type', sniffImageMime(bytes) || 'application/octet-stream');
    res.setHeader('Cache-Control', 'public, max-age=2592000');
    res.end(bytes);
  } catch {
    sendJson(res, 404, { status: 'error', message: 'Not found' });
  }
}

const param = (url: URL, key: string): string => (url.searchParams.get(key) ?? '').trim();

async function handleLyrics(url: URL, res: ServerResponse): Promise<void> {
  const rawTrackName = param(url, 'track_name');
  const rawArtistName = param(url, 'artist_name');
  const duration = param(url, 'duration');
  if (!rawTrackName) {
    sendJson(res, 400, { status: 'error', message: '缺少 track_name' });
    return;
  }
  /**
   * 查询参数折到简体：LRCLIB 的 get 是逐字匹配，标签里的繁体（周杰倫）会让
   * 上游那条简体记录一条都对不上（2026-11-21《完美主义》案例）。
   * 新前端已经自己折过一遍，这里再折一次是幂等的，同时兜住旧链接/旧缓存。
   */
  const trackName = toSimplified(rawTrackName);
  const artistName = toSimplified(rawArtistName);
  const key = sha1(`${trackName}|${artistName}|${duration}`);
  // refresh=1：绕过缓存重新问上游（前端发现只有纯文本歌词、想升级成带时间轴版本时用）
  const refresh = param(url, 'refresh') === '1';
  if (!refresh) {
    const cached = await readCache(LYRICS_DIR, key);
    if (cached) {
      sendJson(res, 200, cached);
      return;
    }
  }
  let result: LyricsResult;
  try {
    result = await fetchLyrics(trackName, artistName, duration, {
      trackName: rawTrackName,
      artistName: rawArtistName,
    });
  } catch (error) {
    const stale = await readCache(LYRICS_DIR, key, { allowStale: true });
    if (stale) {
      sendJson(res, 200, { ...stale, source: `${String(stale.source ?? '')}（离线缓存）` });
      return;
    }
    const classified = classifyError(error);
    sendJson(res, 200, { status: 'error', reason: classified.reason, message: classified.message });
    return;
  }
  await writeCache(LYRICS_DIR, key, result);
  // 命中可能来自对调那一路：结果同时记到对调 key 下，下次两种写法都瞬时命中
  const swappedKey = sha1(`${artistName}|${trackName}|${duration}`);
  if (swappedKey !== key) {
    await writeCache(LYRICS_DIR, swappedKey, result);
  }
  sendJson(res, 200, result);
}

async function handleTranslate(url: URL, res: ServerResponse): Promise<void> {
  // 网易云同样不认繁简：标签里的繁体歌手会直接搜不到
  const trackName = toSimplified(param(url, 'track_name'));
  const artistName = toSimplified(param(url, 'artist_name'));
  const duration = Number(param(url, 'duration')) || 0;
  if (!trackName) {
    sendJson(res, 400, { status: 'error', message: '缺少 track_name' });
    return;
  }
  /**
   * v2：候选对调补上之前，「查不到」是匹配器不全造成的假结论，
   * 那些缓存条目必须作废（旧文件留在原地当孤儿，不影响新键）。
   */
  const key = sha1(`v2|${trackName}|${artistName}|${duration}`.toLowerCase());
  const refresh = param(url, 'refresh') === '1';
  if (!refresh) {
    const cached = await readCache(TRANSLATE_DIR, key);
    if (cached) {
      sendJson(res, 200, cached);
      return;
    }
  }
  let result: TranslateResult;
  try {
    result = await fetchTranslation(trackName, artistName, duration);
  } catch (error) {
    const stale = await readCache(TRANSLATE_DIR, key, { allowStale: true });
    if (stale) {
      sendJson(res, 200, { ...stale, source: `${String(stale.source ?? '')}（离线缓存）` });
      return;
    }
    const classified = classifyError(error, '译文库');
    sendJson(res, 200, { status: 'error', reason: classified.reason, message: classified.message });
    return;
  }
  await writeCache(TRANSLATE_DIR, key, result);
  sendJson(res, 200, result);
}

async function handleCover(url: URL, res: ServerResponse): Promise<void> {
  const title = param(url, 'title');
  const artist = param(url, 'artist');
  const duration = param(url, 'duration');
  if (!title) {
    sendJson(res, 400, { status: 'error', message: '缺少 title' });
    return;
  }
  const key = sha1(`${title}|${artist}`.toLowerCase());
  const cached = await readCache(COVER_META_DIR, key);
  if (cached) {
    sendJson(res, 200, cached);
    return;
  }
  const result = await fetchCover(title, artist, duration);
  await writeCache(COVER_META_DIR, key, result);
  sendJson(res, 200, result);
}

async function handleArtistImage(url: URL, res: ServerResponse): Promise<void> {
  const name = param(url, 'name');
  if (!name) {
    sendJson(res, 400, { status: 'error', message: '缺少 name' });
    return;
  }
  const key = sha1(name.toLowerCase());
  const cached = await readCache(ARTIST_META_DIR, key);
  if (cached) {
    sendJson(res, 200, cached);
    return;
  }
  try {
    const result = await fetchArtistImage(name);
    await writeCache(ARTIST_META_DIR, key, result);
    sendJson(res, 200, result);
  } catch (error) {
    const stale = await readCache(ARTIST_META_DIR, key, { allowStale: true });
    if (stale) {
      sendJson(res, 200, { ...stale, source: `${String(stale.source ?? '')}（离线缓存）` });
      return;
    }
    const classified = classifyError(error, '维基');
    sendJson(res, 200, { status: 'error', reason: classified.reason, message: classified.message });
  }
}

/** 命中路由就处理并返回 true。 */
async function route(res: ServerResponse, reqUrl: string): Promise<boolean> {
  const url = new URL(reqUrl, 'http://localhost');
  const path = url.pathname;
  try {
    if (path === '/api/lyrics') {
      await handleLyrics(url, res);
    } else if (path === '/api/translate') {
      await handleTranslate(url, res);
    } else if (path === '/api/cover') {
      await handleCover(url, res);
    } else if (path === '/api/cover/img') {
      await serveCachedImage(res, COVER_IMG_DIR, url.searchParams.get('id') ?? '', 'cover');
    } else if (path === '/api/artist-image') {
      await handleArtistImage(url, res);
    } else if (path === '/api/artist-image/img') {
      await serveCachedImage(res, ARTIST_IMG_DIR, url.searchParams.get('id') ?? '', 'artist');
    } else {
      return false;
    }
  } catch (error) {
    // 中间件绝不能把 dev server 带崩
    console.error('[music-api] 处理失败：', path, error);
    sendJson(res, 500, { status: 'error', reason: 'local', message: `本地代理出错（${(error as Error)?.name ?? 'Error'}）` });
  }
  return true;
}

/** 作为 Vite 插件注册中间件。 */
export function musicApi(): { name: string; configureServer(server: ViteDevServer): void } {
  return {
    name: 'light-music-api',
    configureServer(server: ViteDevServer): void {
      server.middlewares.use((req, res, next) => {
        const url = req.url ?? '';
        if (!url.startsWith('/api/')) {
          next();
          return;
        }
        void route(res, url);
      });
    },
  };
}
