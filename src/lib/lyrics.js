/**
 * lyrics.js —— LRC 歌词解析与同步滚动视图
 *
 * 职责边界：
 * - parseLRC：把 LRC 文本解析成 [{ time, text }]（纯函数，无副作用）
 * - LyricsView：把歌词渲染成可点击的行，按播放时间高亮当前行并自动居中
 *
 * 不持有播放器引用，时间由外部 push 进来（setTime），跳转通过 onSeek 回调交还外部。
 */

/** 一个时间标签：[mm:ss] / [mm:ss.x] / [mm:ss.xx] / [mm:ss.xxx] */
const TIME_TAG_SOURCE = '\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]';

/** 元信息标签：[ti:] [ar:] [al:] [by:] [offset:] [length:] */
const META_TAG = /^\[(ti|ar|al|by|offset|length)\s*:\s*(.*?)\]$/i;

/**
 * 逐字（增强型）LRC 的内联时间标签：`<00:12.345>`。
 *
 * 部分歌词库返回的是这种格式，时间轴仍然在行首的 `[mm:ss]` 里，
 * 行内这些标签只是逐字高亮用；不去掉会原样显示成乱码。
 */
const WORD_TAG = /<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g;

/** 制作人员署名行：`词：方文山`、`编曲: 钟兴民` …… 不属于歌词正文。 */
const CREDIT_LINE = /^(?:作词|作曲|编曲|词|曲|制作人|出品|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐|统筹|发行|策划|OP|SP)\s*[:：]/i;

/** 只清理开头这么多行，避免误删正文。 */
const CREDIT_SCAN_LIMIT = 4;

/** 当前行判定容差（秒）：避免卡在行边界时来回跳 */
const ACTIVE_TOLERANCE = 0.12;

/** 用户手动滚动后，暂停自动跟随的时长（毫秒） */
const MANUAL_SCROLL_HOLD = 2600;

/**
 * 把时间标签的小数部分换算成秒。
 * @param {string|undefined} raw 小数位原始字符串（1~3 位）
 * @returns {number} 秒
 */
function parseFraction(raw) {
  if (!raw) {
    return 0;
  }
  const digits = raw.length === 1 ? `${raw}00` : (raw.length === 2 ? `${raw}0` : raw.slice(0, 3));
  const value = Number(digits);
  return Number.isFinite(value) ? value / 1000 : 0;
}

/**
 * 解析 LRC 文本。
 *
 * 支持：一行多个时间标签、[offset:] 整体偏移（毫秒，正值表示歌词提前）、
 * 空行与纯元信息行跳过、时间乱序自动排序。
 *
 * @param {string} text LRC 原始文本
 * @param {{title?: string, artist?: string}} [context] 曲目信息（用于剔除开头的标题行）
 * @returns {{lines: Array<{time: number, text: string}>, meta: Record<string, string>}}
 */
export function parseLRC(text, context = {}) {
  const result = { lines: [], meta: {} };
  if (typeof text !== 'string' || text.trim() === '') {
    return result;
  }

  const collected = [];
  let offset = 0;

  text.split(/\r?\n/).forEach((rawLine) => {
    const line = rawLine.trim();
    if (line === '') {
      return;
    }

    const metaMatch = line.match(META_TAG);
    if (metaMatch) {
      const key = metaMatch[1].toLowerCase();
      const value = metaMatch[2].trim();
      result.meta[key] = value;
      if (key === 'offset') {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) {
          offset = parsed;
        }
      }
      return;
    }

    const tagPattern = new RegExp(TIME_TAG_SOURCE, 'g');
    const times = [];
    let match = tagPattern.exec(line);
    while (match) {
      const minutes = Number(match[1]);
      const seconds = Number(match[2]);
      if (Number.isFinite(minutes) && Number.isFinite(seconds) && seconds < 60) {
        times.push(minutes * 60 + seconds + parseFraction(match[3]));
      }
      match = tagPattern.exec(line);
    }
    if (times.length === 0) {
      return;
    }

    const content = line.replace(tagPattern, '').replace(WORD_TAG, '').trim();
    times.forEach((time) => collected.push({ time, text: content }));
  });

  const shift = offset / 1000;
  const sorted = collected
    .map((entry) => ({ time: Math.max(0, entry.time - shift), text: entry.text }))
    .sort((a, b) => a.time - b.time);

  result.lines = dropHeaderLines(sorted, {
    title: context.title || result.meta.ti || '',
    artist: context.artist || result.meta.ar || '',
  });
  return result;
}

/**
 * 去掉开头的制作署名行与「歌名 - 歌手」标题行。
 *
 * 只在开头几行里判断，且清理后至少保留 3 行，避免把正文误删。
 * @param {Array<{time: number, text: string}>} lines 已排序的歌词行
 * @param {{title?: string, artist?: string}} context 曲目信息
 * @returns {Array<{time: number, text: string}>}
 */
function dropHeaderLines(lines, context) {
  if (lines.length <= 3) {
    return lines;
  }

  const norm = (value) => String(value ?? '').toLowerCase().replace(/\s+/g, '');
  const title = norm(context.title);
  const artist = norm(context.artist);

  const kept = [];
  for (const line of lines) {
    const text = line.text.trim();
    const scanned = kept.length < CREDIT_SCAN_LIMIT;
    const isCredit = CREDIT_LINE.test(text);
    const isTitleLine = Boolean(title && artist)
      && text.length <= 60
      && norm(text).includes(title)
      && norm(text).includes(artist);
    if (scanned && (isCredit || isTitleLine)) {
      continue;
    }
    kept.push(line);
  }

  return kept.length >= 3 ? kept : lines;
}

/**
 * 判断用户是否要求减少动效。
 * @returns {boolean}
 */
function prefersReducedMotion() {
  return typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/**
 * 歌词视图。
 */
export class LyricsView {
  /** @type {HTMLElement} 歌词滚动容器（ul） */
  #listEl;

  /** @type {HTMLElement|null} 无歌词空状态 */
  #emptyEl;

  /** @type {number|null} 固定的上下留白比例，null 表示按屏幕宽度自动 */
  #ratio = null;

  /** @type {(time: number) => void} 点击某行时的跳转回调 */
  #onSeek;

  /** @type {Array<{time: number, text: string}>} 当前歌词行 */
  #lines = [];

  /** @type {number} 当前高亮行下标，-1 表示尚未开始 */
  #activeIndex = -1;

  /** @type {boolean} 当前曲目是否有歌词 */
  #hasLyrics = false;

  /** @type {boolean} 用户正在手动浏览歌词（暂停自动跟随） */
  #userScrolling = false;

  /** @type {number} 手动浏览的保持计时器 */
  #holdTimer = 0;

  /** @type {number} 滚动节流的 rAF id */
  #scrollFrame = 0;

  /** @type {boolean} 已渲染的曲目 id，避免同一首歌重复重建 */
  #trackId = '';

  /** @type {string} 已渲染的歌词原文，用于判断是否需要重建 */
  #lyricsSource = '';

  /** @type {string} 已渲染的纯文本歌词，用于判断是否需要重建 */
  #plainSource = '';

  /** @type {boolean} 当前歌词是否带时间轴（可同步高亮） */
  #synced = false;

  /** @type {ResizeObserver|null} 容器尺寸监听 */
  #resizeObserver = null;

  /**
   * @param {object} options 配置
   * @param {HTMLElement} options.listEl 歌词容器
   * @param {HTMLElement|null} [options.emptyEl] 空状态容器（可选，现在由状态行统一提示）
   * @param {(time: number) => void} [options.onSeek] 点击歌词跳转回调
   * @param {number|null} [options.ratio] 上下留白占高度的比例（null = 按屏幕宽度自动）
   */
  constructor({ listEl, emptyEl = null, onSeek, ratio = null }) {
    this.#listEl = listEl;
    this.#emptyEl = emptyEl;
    this.#ratio = Number.isFinite(ratio) ? ratio : null;
    this.#onSeek = typeof onSeek === 'function' ? onSeek : () => {};

    this.#listEl.addEventListener('click', (event) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }
      const item = target.closest('.lyrics__line');
      if (!item || item.dataset.gap === '1') {
        return;
      }
      const time = Number(item.dataset.time);
      if (!Number.isFinite(time)) {
        return;
      }
      // 点击视为主动定位，立刻恢复自动跟随
      this.#releaseManualScroll();
      this.#onSeek(time);
    });

    // 用户手动滚动时先让出控制权，停手一段时间后再自动回到当前行
    const beginManual = () => this.#beginManualScroll();
    this.#listEl.addEventListener('wheel', beginManual, { passive: true });
    this.#listEl.addEventListener('touchmove', beginManual, { passive: true });
    this.#listEl.addEventListener('pointerdown', beginManual);

    // 窗口 / 面板尺寸变化后，居中偏移量要重算，否则高亮行会偏出中心
    if (typeof ResizeObserver === 'function') {
      this.#resizeObserver = new ResizeObserver(() => {
        if (!this.#hasLyrics) {
          return;
        }
        this.#syncPadding();
        this.#scrollToActive(false);
      });
      this.#resizeObserver.observe(this.#listEl);
    }
  }

  /** 当前曲目是否有歌词。 @returns {boolean} */
  get hasLyrics() {
    return this.#hasLyrics;
  }

  /** 当前高亮行下标（无歌词为 -1）。 @returns {number} */
  get activeIndex() {
    return this.#activeIndex;
  }

  /** 当前歌词是否带时间轴。 @returns {boolean} */
  get synced() {
    return this.#synced;
  }

  /**
   * 切换曲目：解析并重建歌词行。
   *
   * 两种形态：
   * - 有时间轴（`track.lyrics`，LRC 文本）→ 逐行高亮同步；
   * - 只有纯文本（`track.lyricsPlain`，第三方库只提供 plain 时）→ 静态展示，不做同步。
   * @param {object|null} track 曲目对象
   * @returns {void}
   */
  setTrack(track) {
    const trackId = track?.id ?? '';
    const source = track?.lyrics ?? '';
    const plain = track?.lyricsPlain ?? '';
    // 同一首歌、同一份歌词就不重建（updateNowPlaying 会被多次调用）
    if (trackId === this.#trackId && source === this.#lyricsSource && plain === this.#plainSource) {
      return;
    }
    this.#releaseManualScroll();
    this.#trackId = trackId;
    this.#lyricsSource = source;
    this.#plainSource = plain;
    this.#activeIndex = -1;

    const parsed = parseLRC(source, { title: track?.title, artist: track?.artist });
    if (parsed.lines.length > 0) {
      this.#lines = parsed.lines;
      this.#synced = true;
      this.#hasLyrics = true;
      this.#renderSynced();
    } else if (plain.trim() !== '') {
      this.#lines = [];
      this.#synced = false;
      this.#hasLyrics = true;
      this.#renderPlain(plain);
    } else {
      this.#lines = [];
      this.#synced = false;
      this.#hasLyrics = false;
      this.#listEl.replaceChildren();
    }

    this.#listEl.scrollTop = 0;
    this.#listEl.setAttribute('aria-busy', 'false');
    if (this.#emptyEl) {
      this.#emptyEl.hidden = this.#hasLyrics;
    }
    // 没有歌词时把滚动容器也收起来，空状态才能在面板里正常居中
    this.#listEl.toggleAttribute('hidden', !this.#hasLyrics);
    this.#syncPadding();
  }

  /**
   * 渲染带时间轴的歌词。
   * @returns {void}
   */
  #renderSynced() {
    const fragment = document.createDocumentFragment();
    this.#lines.forEach((line, index) => {
      const item = document.createElement('li');
      item.className = 'lyrics__line';
      item.dataset.time = String(line.time);
      item.dataset.index = String(index);
      // 纯音乐段落（无文字）只保留留白，不可点击
      if (line.text === '') {
        item.dataset.gap = '1';
        item.classList.add('lyrics__line--gap');
      }
      const text = document.createElement('span');
      text.className = 'lyrics__text';
      text.textContent = line.text || '·';
      item.append(text);
      fragment.append(item);
    });
    this.#listEl.replaceChildren(fragment);
  }

  /**
   * 渲染无时间轴的纯文本歌词（不可点击、不高亮）。
   * @param {string} text 纯文本歌词
   * @returns {void}
   */
  #renderPlain(text) {
    const fragment = document.createDocumentFragment();
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line, index, all) => !(line === '' && (index === 0 || index === all.length - 1)))
      .forEach((line) => {
        const item = document.createElement('li');
        item.className = 'lyrics__line lyrics__line--plain';
        if (line === '') {
          item.classList.add('lyrics__line--gap');
        }
        const span = document.createElement('span');
        span.className = 'lyrics__text';
        span.textContent = line || '·';
        item.append(span);
        fragment.append(item);
      });
    this.#listEl.replaceChildren(fragment);
  }

  /**
   * 重新测量容器并立刻对齐当前行。
   * 标签页从隐藏切回可见、或窗口尺寸变化后调用。
   * @returns {void}
   */
  refresh() {
    if (!this.#hasLyrics) {
      return;
    }
    this.#syncPadding();
    this.#scrollToActive(false);
  }

  /**
   * 按容器高度设置上下对称内边距，让首尾行也能滚到垂直中央。
   *
   * 前提：容器高度必须是确定的（见 styles.css 里的 height 设定）。
   * 若高度由内容撑开，这里会形成「内边距 → 高度 → 内边距」的自激循环。
   * @returns {void}
   */
  #syncPadding() {
    const height = this.#listEl.clientHeight;
    if (height <= 0) {
      return;
    }
    // 纯文本歌词不需要居中留白，只留一点点呼吸空间
    const ratio = this.#synced ? this.#centerRatio() : 0.05;
    const pad = Math.max(8, Math.round(height * ratio));
    const current = parseFloat(this.#listEl.style.paddingTop || '0');
    // 变化不大就不写，避免触发多余的布局与 ResizeObserver 抖动
    if (Math.abs(current - pad) < 2) {
      return;
    }
    this.#listEl.style.paddingTop = `${pad}px`;
    this.#listEl.style.paddingBottom = `${pad}px`;
  }

  /**
   * 上下留白占容器高度的比例。
   * 0.5 才是「当前行精确居中」，但那样上下会空掉一半；0.36 让当前行落在
   * 约 1/3 高度处，视觉上更饱满，也能多看到几行。手机再降一点。
   * @returns {number}
   */
  #centerRatio() {
    if (this.#ratio !== null) {
      return this.#ratio;
    }
    return typeof window.matchMedia === 'function'
      && window.matchMedia('(min-width: 900px)').matches ? 0.36 : 0.3;
  }

  /**
   * 清空（无当前曲目时调用）。
   * @returns {void}
   */
  clear() {
    this.#lines = [];
    this.#activeIndex = -1;
    this.#hasLyrics = false;
    this.#synced = false;
    this.#trackId = '';
    this.#lyricsSource = '';
    this.#plainSource = '';
    this.#listEl.replaceChildren();
    this.#listEl.scrollTop = 0;
    if (this.#emptyEl) {
      this.#emptyEl.hidden = false;
    }
    this.#listEl.toggleAttribute('hidden', true);
  }

  /**
   * 根据播放时间推进高亮。高频调用，内部做了「下标没变就直接返回」的短路。
   * @param {number} seconds 当前播放位置（秒）
   * @returns {void}
   */
  setTime(seconds) {
    if (!this.#hasLyrics || !this.#synced || !Number.isFinite(seconds)) {
      return;
    }

    const next = this.#findIndex(seconds + ACTIVE_TOLERANCE);
    if (next === this.#activeIndex) {
      return;
    }

    const items = this.#listEl.children;
    if (this.#activeIndex >= 0 && items[this.#activeIndex]) {
      items[this.#activeIndex].classList.remove('is-active');
      items[this.#activeIndex].removeAttribute('aria-current');
    }

    this.#activeIndex = next;

    for (let i = 0; i < items.length; i += 1) {
      items[i].classList.toggle('is-past', i < next);
    }

    if (next >= 0 && items[next]) {
      items[next].classList.add('is-active');
      items[next].setAttribute('aria-current', 'true');
      this.#scheduleFollow();
    }
  }

  /**
   * 二分查找最后一个时间 <= 目标时间的行。
   * @param {number} seconds 目标时间
   * @returns {number} 行下标（未到第一行为 -1）
   */
  #findIndex(seconds) {
    const lines = this.#lines;
    let low = 0;
    let high = lines.length - 1;
    let found = -1;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (lines[mid].time <= seconds) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  /**
   * 把当前行滚动到容器垂直中央（合并到下一帧，避免频繁布局）。
   * @returns {void}
   */
  #scheduleFollow() {
    if (this.#userScrolling || this.#scrollFrame) {
      return;
    }
    this.#scrollFrame = requestAnimationFrame(() => {
      this.#scrollFrame = 0;
      this.#scrollToActive(true);
    });
  }

  /**
   * 实际执行滚动。
   * @param {boolean} smooth 是否平滑滚动
   * @returns {void}
   */
  #scrollToActive(smooth) {
    const item = this.#listEl.children[this.#activeIndex];
    if (!item) {
      return;
    }
    const box = this.#listEl;
    // 让当前行的垂直中心对齐容器中心；容器上下留了等量内边距，首尾行也能滚到中央
    const target = item.offsetTop + item.offsetHeight / 2 - box.clientHeight / 2;
    box.scrollTo({
      top: Math.max(0, target),
      behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto',
    });
  }

  /**
   * 进入「用户手动浏览」状态。
   * @returns {void}
   */
  #beginManualScroll() {
    this.#userScrolling = true;
    window.clearTimeout(this.#holdTimer);
    this.#holdTimer = window.setTimeout(() => {
      this.#userScrolling = false;
      this.#holdTimer = 0;
      this.#scrollToActive(true);
    }, MANUAL_SCROLL_HOLD);
  }

  /**
   * 退出「用户手动浏览」状态并立刻恢复跟随。
   * @returns {void}
   */
  #releaseManualScroll() {
    window.clearTimeout(this.#holdTimer);
    this.#holdTimer = 0;
    this.#userScrolling = false;
  }
}
