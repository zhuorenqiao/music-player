/**
 * netease-match.ts —— 网易云「认歌 + 取词归一」的纯函数（无 IO、无状态）。
 *
 * 三处共用这一份，别再各抄一套：
 *   - src/server/music-api.ts（/api/translate、/api/lyrics 的服务端）；
 *   - src/lib/lyrics-source.js（静态发布没有代理时，浏览器直连网易云）；
 *   - flutter-app/lib/lyrics/netease_match.dart 是同一套规则的 Dart 对译（注释更细）。
 *
 * 规则与 Dart 版逐字对齐（Dart 版又对译自原 music-api.ts 417-561），
 * 包括几个非显而易见的点：
 *   - normText 的字符类含全角 `！？` 和 `«»『』「」`，但不含括号（括号留给 coreTitle）；
 *   - coreTitle 的括号剥离循环到不动点，且不跨嵌套；剥完再单剥一个尾部分隔符；
 *   - artistHitSong 先按 `/ 、 , & feat.` 拆 token，长度 ≥3 才开前缀比较，且前缀双向；
 *   - duration 在网易云结果是毫秒，比较前 /1000；折算不了按 Infinity；
 *   - pickNetEaseSong 的 score 比较是严格大于，同分保留搜索结果里靠前的。
 */

import { toSimplified } from './chinese';

/** 一条网易云搜索结果（已解析成稳定形状）。 */
export interface NetEaseSong {
  id: number;
  name: string;
  /** 毫秒。与 pickNetEaseSong 的 duration（秒）不是同一单位。 */
  durationMs: number;
  artists: string[];
  alias: string[];
}

/** 一次认歌尝试的「曲名 + 歌手」。 */
export interface NetEaseCandidate {
  name: string;
  artist: string;
  /** 派生候选（对调、从曲名里拆出来的）必须另有歌手证据才认。 */
  strict: boolean;
}

const SPACES = /[\s　]/g;
const PUNCT = /[,.;:!?·、。，．：；！？"'«»『』「」]/g;
const TAIL_PAREN = /\s*[(（【[][^()（）【】\[\]]*[)）】\]]\s*$/;
const TAIL_SEPARATOR = /\s*[-–—:,;]\s*$/;
const ARTIST_SEP = /[/、,，&；;]|\bfeat\.?\b/gi;
const TITLE_SPLIT = /^(.{2,60}?)\s+[-–—]\s+(.{2,60})$/;

/** 匹配用的归一化：繁→简、小写、去空白与常见标点，括号说明留着（靠前缀判断）。 */
export function normText(value: unknown): string {
  return toSimplified(String(value ?? ''))
    .toLowerCase()
    .replace(SPACES, '')
    .replace(PUNCT, '');
}

/** 去掉尾部的括号说明与分隔符：`Old Town Road (feat. X)` → `Old Town Road`。 */
export function coreTitle(value: unknown): string {
  let text = String(value ?? '');
  let before = '';
  while (before !== text) {
    before = text;
    text = text.replace(TAIL_PAREN, '').trimEnd();
  }
  return text.replace(TAIL_SEPARATOR, '').trim();
}

/** 歌手证据。 */
function artistHitSong(song: NetEaseSong, wantArtist: string): boolean {
  if (!wantArtist) {
    return false;
  }
  const tokens = song.artists
    .flatMap((value) => value.split(ARTIST_SEP))
    .map(normText)
    .filter(Boolean);
  return tokens.some((token) => token === wantArtist
    || (token.length >= 3 && (token.startsWith(wantArtist) || wantArtist.startsWith(token))));
}

/**
 * 从搜索结果里挑唯一可信的一条。
 *
 * 歌名必须一致（含去掉版本后缀的本体），且歌手对得上或时长差 ≤6 秒；
 * `strict` 时必须有歌手证据（派生候选里的歌手本身是猜的）。
 *
 * @param duration 秒；0 表示未知。
 */
export function pickNetEaseSong(
  songs: NetEaseSong[],
  { trackName, artistName, duration, strict = false }: {
    trackName: string;
    artistName: string;
    duration: number;
    strict?: boolean;
  },
): NetEaseSong | null {
  const wantTitle = normText(trackName);
  const wantCore = normText(coreTitle(trackName));
  const wantArtist = normText(artistName);
  if (!wantTitle) {
    return null;
  }
  const onlyTitle = !wantArtist && !(duration > 0);

  let best: NetEaseSong | null = null;
  let bestScore = 0;
  for (const song of songs) {
    const name = normText(song.name);
    if (!name || !song.id) {
      continue;
    }
    const core = normText(coreTitle(song.name));
    const titleExact = name === wantTitle
      || song.alias.some((alias) => normText(alias) === wantTitle)
      || (wantCore.length >= 3 && core === wantCore);
    const titlePrefix = !titleExact && wantTitle.length >= 3 && name.startsWith(wantTitle);
    if (!titleExact && !titlePrefix) {
      continue;
    }
    const artistHit = artistHitSong(song, wantArtist);
    const millis = song.durationMs;
    const diff = duration > 0 && Number.isFinite(millis) && millis > 0
      ? Math.abs(millis / 1000 - duration)
      : Number.POSITIVE_INFINITY;
    const durHit = diff <= 6;
    if (!titleExact) {
      // 前缀命中必须靠时长或歌手背书，否则「Yellow」会配上「Yellow (Live)」那种 6 分钟版本
      if (!artistHit && !durHit) {
        continue;
      }
      if (diff > 20) {
        continue;
      }
    } else if (!artistHit && !durHit && !onlyTitle) {
      continue;
    }
    if (strict && !artistHit) {
      continue;
    }
    const score = (titleExact ? 40 : 18) + (artistHit ? 25 : 0) + (durHit ? 25 : 0);
    if (score > bestScore) {
      best = song;
      bestScore = score;
    }
  }
  return best;
}

/** 解析 `result.songs`（也接受已经拍平成数组的输入）；怪数据跳过，不强转。 */
export function parseNetEaseSongs(raw: unknown): NetEaseSong[] {
  const list = Array.isArray(raw)
    ? raw
    : (raw as { result?: { songs?: unknown } } | null)?.result?.songs;
  if (!Array.isArray(list)) {
    return [];
  }
  const parsed: NetEaseSong[] = [];
  for (const item of list) {
    const song = item as {
      id?: unknown;
      name?: unknown;
      duration?: unknown;
      artists?: unknown;
      alias?: unknown;
    };
    if (typeof song?.id !== 'number' || !Number.isFinite(song.id) || song.id <= 0) {
      continue;
    }
    if (typeof song.name !== 'string' || !song.name.trim()) {
      continue;
    }
    const artists = Array.isArray(song.artists)
      ? song.artists
        .map((artist) => (artist as { name?: unknown })?.name)
        .filter((name): name is string => typeof name === 'string')
      : [];
    const alias = Array.isArray(song.alias)
      ? song.alias.filter((name): name is string => typeof name === 'string')
      : [];
    const durationMs = typeof song.duration === 'number' && Number.isFinite(song.duration)
      ? song.duration
      : 0;
    parsed.push({
      id: Math.trunc(song.id),
      name: song.name.trim(),
      durationMs,
      artists,
      alias,
    });
  }
  return parsed;
}

/**
 * （曲名, 歌手）候选。
 *
 * 本地标签的三种拆法都试：正方向、「歌手 - 歌名」对调、曲名本身写着「歌名 - 歌手」。
 * 派生候选标 strict（歌手是猜的，必须另有歌手证据）。
 */
export function neteaseCandidates(trackName: string, artistName: string): NetEaseCandidate[] {
  const pairs: NetEaseCandidate[] = [{ name: trackName, artist: artistName, strict: false }];
  if (artistName && artistName !== trackName) {
    pairs.push({ name: artistName, artist: trackName, strict: true });
  }
  const split = trackName.match(TITLE_SPLIT);
  if (split) {
    const [, head, tail] = split;
    pairs.push({ name: head.trim(), artist: tail.trim(), strict: true });
    pairs.push({ name: tail.trim(), artist: head.trim(), strict: true });
  }
  const seen = new Set<string>();
  return pairs.filter((pair) => {
    const key = `${pair.name}|${pair.artist}`.toLowerCase();
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

/** 搜索词：歌手在前，单空格连接。 */
export const candidateKeyword = (candidate: NetEaseCandidate): string =>
  [candidate.artist, candidate.name].filter(Boolean).join(' ');

/** 时间标签：`[00:01]` / `[00:01.2]` / `[00:01.23]` / `[00:01.234]`。 */
const TIME_TAG = /\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]/;

/** 开头制作署名：`作曲 :` / `录音师 :` / `混音工程师 :` …… */
// 冒号后必须还有内容，避免把「鼓声响起：……」这类正文当成署名；
// OP / SP 单独一条大小写敏感规则，否则英文歌词的 `Open your eyes:` 会被误判。
const CREDIT_LINE = /^(?:作词|作曲|编曲|词|曲|制作人|制作|出品|监制|混音|母带|录音|和声|合声|伴唱|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|演唱|原唱|配唱|编写)[^:：]{0,14}[:：]\s*\S/i;
// 英文署名（`Lyrics by：` / `Composed by:`，酷狗英文歌词常见），与 Dart 版同一条规则。
const CREDIT_WORDS = /^(?:lyrics|composed|arranged|written|produced|mixed|mastered|recorded|performed|translated)\s*(?:by\s*)?[:：]\s*\S/i;
const CREDIT_LATIN = /^(?:OP|SP)\s*[:：]\s*\S/;

/** 开头署名行的扫描上限。 */
const CREDIT_SCAN_LIMIT = 12;

/** 正文是否有时间轴（决定放 synced 还是 plain）。 */
export const looksSynced = (text: string): boolean => TIME_TAG.test(text);

/**
 * 剥掉开头连续的制作署名行（带不带时间轴都剥）。
 *
 * 解析器的署名清理只扫前 4 行，网易云的署名常有一整串（8 行上下），
 * 多出来的会在歌词页顶上排成一片。这里先把开头连续的署名剥掉，遇到正文即停。
 */
export function stripLeadingCredits(lyric: string): string {
  const lines = lyric.split(/\r?\n/);
  let index = 0;
  while (index < lines.length && index < CREDIT_SCAN_LIMIT) {
    const text = lines[index].replace(TIME_TAG, '').trim();
    if (!text) {
      index += 1;
      continue;
    }
    if (!CREDIT_LINE.test(text) && !CREDIT_WORDS.test(text) && !CREDIT_LATIN.test(text)) {
      break;
    }
    index += 1;
  }
  if (index === 0) {
    return lyric;
  }
  return lines.slice(index).join('\n').trim();
}
