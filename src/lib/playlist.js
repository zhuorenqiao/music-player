/**
 * playlist.js —— 播放列表数据模型
 *
 * 只负责「数据与顺序」的纯逻辑：曲目增删、顺序调整、上一首/下一首推算、
 * 随机播放的洗牌队列。不接触 DOM，也不接触 Audio 元素。
 */

/** 三种播放模式。 */
export const PLAY_MODES = Object.freeze({
  LIST: 'list',
  ONE: 'one',
  SHUFFLE: 'shuffle',
});

/** 模式循环切换顺序：列表循环 → 单曲循环 → 随机播放 → 列表循环。 */
export const MODE_ORDER = Object.freeze([PLAY_MODES.LIST, PLAY_MODES.ONE, PLAY_MODES.SHUFFLE]);

/** 模式的中文文案。 */
export const MODE_LABELS = Object.freeze({
  [PLAY_MODES.LIST]: '列表循环',
  [PLAY_MODES.ONE]: '单曲循环',
  [PLAY_MODES.SHUFFLE]: '随机播放',
});

/**
 * 把区间外的数字夹回区间内。
 * @param {number} value 原始值
 * @param {number} min 最小值
 * @param {number} max 最大值
 * @returns {number}
 */
function clamp(value, min, max) {
  if (!Number.isFinite(value)) {
    return min;
  }
  return Math.min(max, Math.max(min, value));
}

/** 单曲歌词文本的长度上限（字符），防止异常数据把 localStorage 撑爆。 */
const MAX_LYRICS_LENGTH = 64 * 1024;

/**
 * 判断一个对象是否「足够像」一条曲目记录。
 * @param {*} value 待判断的值
 * @returns {boolean}
 */
export function isTrackLike(value) {
  return Boolean(value)
    && typeof value.id === 'string'
    && value.id.length > 0
    && typeof value.title === 'string'
    && typeof value.src === 'string'
    && value.src.length > 0;
}

/**
 * 把外部数据（localStorage / demo-data）规范成统一的曲目结构。
 * 缺失字段一律补默认值，保证渲染层不用做防御式判断。
 * @param {object} raw 原始曲目
 * @returns {object|null} 规范后的曲目，非法数据返回 null
 */
export function normalizeTrack(raw) {
  if (!isTrackLike(raw)) {
    return null;
  }
  const duration = typeof raw.duration === 'number' && Number.isFinite(raw.duration) && raw.duration > 0
    ? raw.duration
    : Number.NaN;
  return {
    id: raw.id,
    title: raw.title.trim() || '未知曲目',
    artist: typeof raw.artist === 'string' && raw.artist.trim() ? raw.artist.trim() : '',
    album: typeof raw.album === 'string' && raw.album.trim() ? raw.album.trim() : '',
    cover: typeof raw.cover === 'string' && raw.cover.trim() ? raw.cover.trim() : '',
    src: raw.src,
    duration,
    isLocal: raw.isLocal === true,
    // LRC 原文交给 lyrics.js 解析，这里只做类型与长度兜底
    lyrics: typeof raw.lyrics === 'string' && raw.lyrics.trim()
      ? raw.lyrics.slice(0, MAX_LYRICS_LENGTH)
      : '',
    // 无时间轴的纯文本歌词（第三方库只提供 plain 时）
    lyricsPlain: typeof raw.lyricsPlain === 'string' && raw.lyricsPlain.trim()
      ? raw.lyricsPlain.slice(0, MAX_LYRICS_LENGTH)
      : '',
    // 歌词来源：auto = 自动匹配，manual = 手动指定，空 = 内置数据
    lyricsSource: raw.lyricsSource === 'auto' || raw.lyricsSource === 'manual' ? raw.lyricsSource : '',
  };
}

/**
 * 播放列表模型。
 *
 * 随机播放使用「洗牌队列」：维护一份索引排列，切歌时按队列推进，
 * 一轮内不会重复；一轮结束后重新洗牌开始新一轮。
 */
export class Playlist {
  /** @type {object[]} 曲目数组 */
  #tracks = [];

  /** @type {number} 当前曲目索引，-1 表示未选中 */
  #currentIndex = -1;

  /** @type {string} 当前播放模式 */
  #mode = PLAY_MODES.LIST;

  /** @type {number[]} 洗牌队列（存的是曲目索引） */
  #shuffleQueue = [];

  /** @type {number} 洗牌队列游标 */
  #shufflePos = -1;

  /**
   * @param {object} [options]
   * @param {object[]} [options.tracks] 初始曲目
   * @param {string} [options.mode] 初始模式
   * @param {number} [options.currentIndex] 初始当前索引
   */
  constructor({ tracks = [], mode = PLAY_MODES.LIST, currentIndex = 0 } = {}) {
    this.#tracks = tracks.map(normalizeTrack).filter(Boolean);
    this.#mode = MODE_ORDER.includes(mode) ? mode : PLAY_MODES.LIST;
    this.#currentIndex = this.#tracks.length > 0
      ? clamp(currentIndex, 0, this.#tracks.length - 1)
      : -1;
    this.#rebuildShuffle();
  }

  /** @returns {object[]} 曲目数组（只读约定，调用方不要原地修改） */
  get tracks() {
    return this.#tracks;
  }

  /** @returns {number} 曲目数量 */
  get size() {
    return this.#tracks.length;
  }

  /** @returns {string} 当前播放模式 */
  get mode() {
    return this.#mode;
  }

  /** @returns {number} 当前曲目索引 */
  get currentIndex() {
    return this.#currentIndex;
  }

  /** @returns {object|null} 当前曲目 */
  get current() {
    return this.#tracks[this.#currentIndex] ?? null;
  }

  /** @returns {boolean} 是否处于随机模式 */
  get isShuffle() {
    return this.#mode === PLAY_MODES.SHUFFLE;
  }

  /** @returns {number} 全部曲目时长之和（未知时长按 0 计） */
  get totalDuration() {
    return this.#tracks.reduce((sum, track) => (
      Number.isFinite(track.duration) ? sum + track.duration : sum
    ), 0);
  }

  /**
   * 设置播放模式。
   * @param {string} mode 目标模式
   * @returns {string} 生效后的模式
   */
  setMode(mode) {
    if (!MODE_ORDER.includes(mode)) {
      return this.#mode;
    }
    this.#mode = mode;
    if (mode === PLAY_MODES.SHUFFLE) {
      this.#rebuildShuffle();
    }
    return this.#mode;
  }

  /**
   * 按 list → one → shuffle 的顺序循环切换模式。
   * @returns {string} 生效后的模式
   */
  cycleMode() {
    const at = MODE_ORDER.indexOf(this.#mode);
    const next = MODE_ORDER[(at + 1) % MODE_ORDER.length];
    return this.setMode(next);
  }

  /**
   * 按 id 查找索引。
   * @param {string} id 曲目 id
   * @returns {number} 索引，找不到返回 -1
   */
  indexOfId(id) {
    return this.#tracks.findIndex((track) => track.id === id);
  }

  /**
   * 直接定位到某一首（用户点击列表项时调用）。
   * @param {number} index 目标索引
   * @returns {object|null} 定位后的当前曲目
   */
  setCurrentIndex(index) {
    if (this.#tracks.length === 0) {
      this.#currentIndex = -1;
      return null;
    }
    this.#currentIndex = clamp(index, 0, this.#tracks.length - 1);
    this.#syncShuffleCursor();
    return this.current;
  }

  /**
   * 按 id 定位当前曲目。
   * @param {string} id 曲目 id
   * @returns {object|null} 当前曲目；找不到时保持原状
   */
  setCurrentById(id) {
    const at = this.indexOfId(id);
    return at >= 0 ? this.setCurrentIndex(at) : this.current;
  }

  /**
   * 在指定位置插入一首。
   * @param {object} track 曲目
   * @param {number} [index] 插入位置，默认追加到末尾
   * @returns {object|null} 插入后的曲目
   */
  addAt(track, index = this.#tracks.length) {
    const normalized = normalizeTrack(track);
    if (!normalized) {
      return null;
    }
    const at = clamp(index, 0, this.#tracks.length);
    this.#tracks.splice(at, 0, normalized);

    if (this.#currentIndex < 0) {
      this.#currentIndex = at;
    } else if (at <= this.#currentIndex) {
      this.#currentIndex += 1;
    }
    this.#rebuildShuffle();
    return normalized;
  }

  /**
   * 批量追加曲目（添加本地文件时用）。
   * @param {object[]} tracks 曲目数组
   * @returns {{added: number, firstIndex: number, loadedFirst: boolean}}
   *          added：成功加入数量；firstIndex：第一条的下标；
   *          loadedFirst：加入前列表为空（调用方可据此决定是否自动播放）
   */
  addMany(tracks) {
    const normalized = tracks.map(normalizeTrack).filter(Boolean);
    if (normalized.length === 0) {
      return { added: 0, firstIndex: -1, loadedFirst: false };
    }
    const firstIndex = this.#tracks.length;
    const wasEmpty = this.#currentIndex < 0;
    this.#tracks.push(...normalized);
    if (wasEmpty) {
      this.#currentIndex = firstIndex;
    }
    this.#rebuildShuffle();
    return { added: normalized.length, firstIndex, loadedFirst: wasEmpty };
  }

  /**
   * 删除指定曲目，并同步修正当前索引。
   * @param {string} id 曲目 id
   * @returns {{removed: object|null, currentChanged: boolean}}
   *          removed：被删除的曲目；currentChanged：当前曲目是否因此换了一首
   */
  removeById(id) {
    const at = this.indexOfId(id);
    if (at < 0) {
      return { removed: null, currentChanged: false };
    }
    const [removed] = this.#tracks.splice(at, 1);
    let currentChanged = false;

    if (this.#tracks.length === 0) {
      this.#currentIndex = -1;
      currentChanged = true;
    } else if (at < this.#currentIndex) {
      // 删的是当前项之前的曲目，索引整体前移
      this.#currentIndex -= 1;
    } else if (at === this.#currentIndex) {
      // 删的是当前项：索引保持不动，即自动落到下一首；越界则退到末尾
      this.#currentIndex = Math.min(this.#currentIndex, this.#tracks.length - 1);
      currentChanged = true;
    }
    this.#rebuildShuffle();
    return { removed, currentChanged };
  }

  /**
   * 上/下移动一首（供排序使用）。
   * @param {string} id 曲目 id
   * @param {number} delta 位移量，负数上移
   * @returns {boolean} 是否发生了移动
   */
  move(id, delta) {
    const at = this.indexOfId(id);
    const to = at + delta;
    if (at < 0 || to < 0 || to >= this.#tracks.length) {
      return false;
    }
    const [moved] = this.#tracks.splice(at, 1);
    this.#tracks.splice(to, 0, moved);

    if (this.#currentIndex === at) {
      this.#currentIndex = to;
    } else if (at < this.#currentIndex && to >= this.#currentIndex) {
      this.#currentIndex -= 1;
    } else if (at > this.#currentIndex && to <= this.#currentIndex) {
      this.#currentIndex += 1;
    }
    this.#rebuildShuffle();
    return true;
  }

  /**
   * 清空列表。
   * @returns {object[]} 被清空的曲目（调用方负责释放 blob URL）
   */
  clear() {
    const removed = this.#tracks;
    this.#tracks = [];
    this.#currentIndex = -1;
    this.#shuffleQueue = [];
    this.#shufflePos = -1;
    return removed;
  }

  /**
   * 计算下一首的索引。
   *
   * 注意：**不修改当前曲目索引**（`#currentIndex` 由调用方 `setCurrentIndex` 提交），
   * 但在随机模式下**会推进内部洗牌游标**（`#shufflePos`），必要时还会重建洗牌队列。
   * 这是有意的副作用——连续调用会依次拿到后续曲目，而不是一直返回同一个值。
   * @param {object} [options]
   * @param {boolean} [options.auto] 是否为自动播放（播放结束触发）。
   *        自动播放且处于单曲循环时返回当前索引（原地重播）。
   * @returns {number} 下一首索引，列表为空返回 -1
   */
  nextIndex({ auto = false } = {}) {
    const size = this.#tracks.length;
    if (size === 0) {
      return -1;
    }
    if (auto && this.#mode === PLAY_MODES.ONE) {
      return this.#currentIndex;
    }
    if (this.#mode === PLAY_MODES.SHUFFLE) {
      return this.#advanceShuffle(1);
    }
    if (this.#currentIndex < 0) {
      return 0;
    }
    return (this.#currentIndex + 1) % size;
  }

  /**
   * 计算上一首的索引。
   *
   * 与 {@link nextIndex} 一致：不改 `#currentIndex`，但随机模式下**会回退内部洗牌游标**。
   * @returns {number} 上一首索引，列表为空返回 -1
   */
  prevIndex() {
    const size = this.#tracks.length;
    if (size === 0) {
      return -1;
    }
    if (this.#mode === PLAY_MODES.SHUFFLE) {
      return this.#advanceShuffle(-1);
    }
    if (this.#currentIndex < 0) {
      return 0;
    }
    return (this.#currentIndex - 1 + size) % size;
  }

  /**
   * 在洗牌队列上前后移动游标。
   * @param {number} step 前进为正，后退为负
   * @returns {number} 目标曲目索引
   */
  #advanceShuffle(step) {
    const size = this.#tracks.length;
    if (size === 0) {
      return -1;
    }
    this.#syncShuffleCursor();

    let pos = this.#shufflePos + step;
    if (pos >= this.#shuffleQueue.length) {
      // 一轮放完：重新洗牌开始新一轮（避免立刻重复刚放完的那首）
      this.#rebuildShuffle({ keepCurrentFirst: false });
      pos = 0;
    }
    if (pos < 0) {
      pos = this.#shuffleQueue.length - 1;
    }
    this.#shufflePos = clamp(pos, 0, this.#shuffleQueue.length - 1);
    const index = this.#shuffleQueue[this.#shufflePos];
    return Number.isInteger(index) ? index : 0;
  }

  /**
   * 让洗牌游标指向当前曲目；队列与列表长度不一致时整体重建。
   */
  #syncShuffleCursor() {
    const size = this.#tracks.length;
    if (this.#shuffleQueue.length !== size) {
      this.#rebuildShuffle();
      return;
    }
    if (this.#currentIndex < 0) {
      this.#shufflePos = -1;
      return;
    }
    const at = this.#shuffleQueue.indexOf(this.#currentIndex);
    if (at >= 0) {
      this.#shufflePos = at;
    } else {
      this.#rebuildShuffle();
    }
  }

  /**
   * 重建洗牌队列（Fisher-Yates 洗牌）。
   * @param {object} [options]
   * @param {boolean} [options.keepCurrentFirst] 是否把当前曲目排到队首
   */
  #rebuildShuffle({ keepCurrentFirst = true } = {}) {
    const size = this.#tracks.length;
    const order = Array.from({ length: size }, (_, i) => i);

    for (let i = size - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [order[i], order[j]] = [order[j], order[i]];
    }

    if (size > 1 && keepCurrentFirst && this.#currentIndex >= 0) {
      const at = order.indexOf(this.#currentIndex);
      if (at > 0) {
        order.splice(at, 1);
        order.unshift(this.#currentIndex);
      }
    } else if (size > 1 && !keepCurrentFirst && order[0] === this.#currentIndex) {
      const swapAt = 1 + Math.floor(Math.random() * (size - 1));
      [order[0], order[swapAt]] = [order[swapAt], order[0]];
    }

    this.#shuffleQueue = order;
    this.#shufflePos = keepCurrentFirst && this.#currentIndex >= 0 && size > 0 ? 0 : -1;
  }
}
