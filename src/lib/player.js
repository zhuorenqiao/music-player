/**
 * player.js —— Audio 元素封装
 *
 * 职责：加载曲目、播放/暂停、跳转、音量与静音、把原生事件归一化成
 * 业务事件（并做错误分类）。不关心 UI，也不关心播放列表顺序。
 */

/** 原生 MediaError.code 到中文提示的映射。 */
export const AUDIO_ERROR_MESSAGES = Object.freeze({
  1: '音频加载被中断，请重试',
  2: '网络错误，无法获取音频文件',
  3: '音频解码失败，文件可能已损坏',
  4: '格式不支持或音频文件不存在',
});

/** 无法归类时的兜底提示。 */
export const UNKNOWN_ERROR_MESSAGE = '音频播放失败，请稍后重试';

/** 播放被浏览器自动播放策略拦截时的提示。 */
export const AUTOPLAY_BLOCKED_MESSAGE = '浏览器阻止了自动播放，请点击播放按钮开始';

/**
 * 把数字夹到 0 ~ 1。
 * @param {number} value 原始值
 * @returns {number}
 */
function clamp01(value) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(1, Math.max(0, value));
}

/**
 * 播放器封装。
 *
 * 通过 `on(事件名, 回调)` 订阅业务事件，事件列表：
 *   loading / canplay / timeupdate / durationchange / progress /
 *   statechange / volumechange / ended / error / playblocked
 */
export class Player {
  /** @type {HTMLAudioElement} 被包装的 audio 元素 */
  #audio;

  /** @type {Map<string, Set<Function>>} 事件订阅表 */
  #listeners = new Map();

  /** @type {object|null} 当前加载的曲目 */
  #track = null;

  /** @type {boolean} 是否处于加载中 */
  #loading = false;

  /** @type {number} 静音前的音量，用于恢复 */
  #lastVolume = 0.7;

  /** @type {boolean} 是否已销毁 */
  #disposed = false;

  /** @type {number|null} 元数据就绪前收到的跳转请求，就绪后补做 */
  #pendingSeek = null;

  /** @type {{target: number, timer: number}|null} 刚提交的跳转，播放真正开始时做一次单向校验 */
  #seekGuard = null;

  /**
   * @param {HTMLAudioElement} audio 页面上的 audio 元素
   */
  constructor(audio) {
    if (!(audio instanceof HTMLAudioElement)) {
      throw new TypeError('Player 需要一个 <audio> 元素');
    }
    this.#audio = audio;
    this.#lastVolume = clamp01(audio.volume || 0.7) || 0.7;
    this.#bindNativeEvents();
  }

  /** @returns {HTMLAudioElement} 原生 audio 元素 */
  get audio() {
    return this.#audio;
  }

  /** @returns {object|null} 当前曲目 */
  get track() {
    return this.#track;
  }

  /** @returns {boolean} 是否正在播放 */
  get playing() {
    return !this.#audio.paused && !this.#audio.ended && this.#audio.currentTime > 0;
  }

  /** @returns {boolean} 是否暂停 */
  get paused() {
    return this.#audio.paused;
  }

  /** @returns {boolean} 是否加载中 */
  get loading() {
    return this.#loading;
  }

  /** @returns {number} 当前播放位置（秒） */
  get currentTime() {
    return Number.isFinite(this.#audio.currentTime) ? this.#audio.currentTime : 0;
  }

  /** @returns {number} 总时长（未知时为 NaN） */
  get duration() {
    const value = this.#audio.duration;
    return Number.isFinite(value) && value > 0 ? value : Number.NaN;
  }

  /** @returns {number} 当前音量 0 ~ 1 */
  get volume() {
    return clamp01(this.#audio.volume);
  }

  /** @returns {boolean} 是否静音 */
  get muted() {
    return this.#audio.muted;
  }

  /** @returns {number} 已缓冲到的时间点（秒），没有缓冲返回 0 */
  get bufferedEnd() {
    const { buffered } = this.#audio;
    if (!buffered || buffered.length === 0) {
      return 0;
    }
    try {
      return buffered.end(buffered.length - 1);
    } catch (error) {
      console.error('[player] 读取缓冲区间失败：', error);
      return 0;
    }
  }

  /**
   * 订阅事件。
   * @param {string} type 事件名
   * @param {Function} handler 回调
   * @returns {Function} 取消订阅函数
   */
  on(type, handler) {
    if (typeof handler !== 'function') {
      return () => {};
    }
    if (!this.#listeners.has(type)) {
      this.#listeners.set(type, new Set());
    }
    this.#listeners.get(type).add(handler);
    return () => this.off(type, handler);
  }

  /**
   * 取消订阅。
   * @param {string} type 事件名
   * @param {Function} handler 回调
   */
  off(type, handler) {
    this.#listeners.get(type)?.delete(handler);
  }

  /**
   * 加载一首曲目。
   * @param {object} track 曲目对象（必须含 src）
   * @param {object} [options]
   * @param {boolean} [options.autoplay] 加载后是否立即播放
   * @returns {boolean} 是否成功发起加载
   */
  load(track, { autoplay = false } = {}) {
    if (!track || typeof track.src !== 'string' || track.src.length === 0) {
      this.#emit('error', {
        code: 4,
        message: AUDIO_ERROR_MESSAGES[4],
        track: track ?? null,
        nativeMessage: '',
      });
      return false;
    }

    this.#track = track;
    this.#pendingSeek = null;
    this.#clearSeekGuard();
    this.#audio.pause();
    this.#setLoading(true);
    try {
      this.#audio.src = track.src;
      this.#audio.load();
    } catch (error) {
      console.error('[player] 设置音频地址失败：', error);
      this.#setLoading(false);
      this.#emit('error', {
        code: 4,
        message: AUDIO_ERROR_MESSAGES[4],
        track,
        nativeMessage: String(error?.message ?? ''),
      });
      return false;
    }

    if (autoplay) {
      // 不等待结果：失败会通过 playblocked 事件反馈给 UI
      void this.play();
    }
    return true;
  }

  /**
   * 播放当前曲目。
   * @returns {Promise<boolean>} 是否成功开始播放
   */
  async play() {
    if (!this.#audio.currentSrc && !this.#audio.getAttribute('src')) {
      return false;
    }
    try {
      await this.#audio.play();
      this.#setLoading(false);
      return true;
    } catch (error) {
      this.#setLoading(false);
      const name = error?.name ?? '';
      if (name === 'NotAllowedError') {
        this.#emit('playblocked', { reason: 'autoplay', message: AUTOPLAY_BLOCKED_MESSAGE });
      } else if (name === 'AbortError') {
        // 用户主动暂停 / 切换曲目导致的中断，属于正常流程，不提示
      } else {
        this.#emit('playblocked', {
          reason: 'unknown',
          message: `无法开始播放：${error?.message ?? '未知错误'}`,
        });
      }
      return false;
    }
  }

  /**
   * 暂停播放。
   * @returns {void}
   */
  pause() {
    this.#audio.pause();
  }

  /**
   * 在播放与暂停之间切换。
   * @returns {Promise<boolean>} 切换后是否处于播放状态
   */
  async toggle() {
    if (this.#audio.paused) {
      return this.play();
    }
    this.pause();
    return false;
  }

  /**
   * 跳转到指定秒数。
   * 若元数据尚未就绪（刚切歌时用户就拖动了进度条），会把请求暂存，
   * 等 loadedmetadata 之后自动补做。
   * @param {number} seconds 目标位置（秒）
   * @returns {boolean} 是否已接受该跳转
   */
  seek(seconds) {
    const requested = Math.max(0, Number(seconds) || 0);
    const total = this.duration;

    if (!Number.isFinite(total)) {
      if (this.#track && this.#audio.readyState === 0) {
        this.#pendingSeek = requested;
        return true;
      }
      return false;
    }

    const target = Math.min(total, requested);
    try {
      this.#audio.currentTime = target;
      // 记一次「刚跳转过」的标记：若浏览器随后才真正开始播放并把位置重置回 0，
      // playing 事件里会发现偏移并补一次，避免「点了立刻拖进度条」丢失跳转。
      this.#armSeekGuard(target);
      this.#emit('timeupdate', { currentTime: target, duration: total });
      return true;
    } catch (error) {
      console.error('[player] 跳转失败：', error);
      this.#pendingSeek = requested;
      return false;
    }
  }

  /**
   * 相对当前位置跳转。
   * @param {number} delta 相对秒数，负数表示后退
   * @returns {boolean} 是否成功跳转
   */
  seekBy(delta) {
    return this.seek(this.currentTime + (Number(delta) || 0));
  }

  /**
   * 从头重播当前曲目（单曲循环用）。
   * @returns {Promise<boolean>} 是否成功播放
   */
  async restart() {
    this.seek(0);
    return this.play();
  }

  /**
   * 设置音量。
   * @param {number} value 0 ~ 1
   * @returns {void}
   */
  setVolume(value) {
    const volume = clamp01(Number(value));
    this.#audio.volume = volume;
    if (volume > 0) {
      this.#audio.muted = false;
      this.#lastVolume = volume;
    } else {
      this.#audio.muted = false;
    }
  }

  /**
   * 设置静音状态。
   * @param {boolean} muted 是否静音
   * @returns {void}
   */
  setMuted(muted) {
    this.#audio.muted = Boolean(muted);
    if (!muted && this.#audio.volume === 0) {
      // 音量是 0 的情况下取消静音，恢复上一次的音量
      this.#audio.volume = this.#lastVolume > 0 ? this.#lastVolume : 0.7;
    }
  }

  /**
   * 切换静音，并记住 / 恢复静音前的音量。
   * @returns {boolean} 切换后是否静音
   */
  toggleMute() {
    const willMute = !this.#audio.muted;
    if (willMute) {
      if (this.#audio.volume > 0) {
        this.#lastVolume = this.#audio.volume;
      }
      this.#audio.muted = true;
    } else {
      this.#audio.muted = false;
      if (this.#audio.volume === 0) {
        this.#audio.volume = this.#lastVolume > 0 ? this.#lastVolume : 0.7;
      }
    }
    return this.#audio.muted;
  }

  /**
   * 停止播放并卸载音源（清空列表 / 移除当前曲目时用）。
   * @returns {void}
   */
  stop() {
    this.#audio.pause();
    this.#track = null;
    this.#pendingSeek = null;
    this.#clearSeekGuard();
    this.#setLoading(false);
    try {
      this.#audio.removeAttribute('src');
      this.#audio.load();
    } catch (error) {
      console.error('[player] 卸载音源失败：', error);
    }
  }

  /**
   * 解绑全部原生事件与业务订阅。
   * @returns {void}
   */
  dispose() {
    if (this.#disposed) {
      return;
    }
    this.#disposed = true;
    this.#listeners.clear();
    this.#clearSeekGuard();
    this.#pendingSeek = null;
    this.stop();
  }

  // -------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------

  /**
   * 绑定 audio 元素的原生事件，并转换为业务事件。
   * @returns {void}
   */
  #bindNativeEvents() {
    const audio = this.#audio;

    audio.addEventListener('loadstart', () => this.#setLoading(true));

    audio.addEventListener('loadedmetadata', () => {
      // 补做「元数据就绪前」的跳转请求
      if (this.#pendingSeek !== null) {
        const target = Math.min(this.duration || this.#pendingSeek, this.#pendingSeek);
        this.#pendingSeek = null;
        try {
          audio.currentTime = target;
        } catch (error) {
          console.error('[player] 补做跳转失败：', error);
        }
      }
      this.#emit('durationchange', { duration: this.duration });
    });

    audio.addEventListener('durationchange', () => {
      this.#emit('durationchange', { duration: this.duration });
    });

    ['canplay', 'canplaythrough', 'playing'].forEach((type) => {
      audio.addEventListener(type, () => {
        if (type === 'playing') {
          // 播放真正开始：确认刚才的跳转没有被浏览器重置（单向校验）
          this.#applySeekGuardOnPlay();
        }
        this.#setLoading(false);
        this.#emit('canplay', { duration: this.duration });
      });
    });

    audio.addEventListener('waiting', () => this.#setLoading(true));
    audio.addEventListener('stalled', () => this.#setLoading(true));

    audio.addEventListener('timeupdate', () => {
      this.#emit('timeupdate', {
        currentTime: this.currentTime,
        duration: this.duration,
      });
    });

    audio.addEventListener('progress', () => {
      this.#emit('progress', {
        bufferedEnd: this.bufferedEnd,
        duration: this.duration,
      });
    });

    audio.addEventListener('play', () => {
      this.#emit('statechange', { playing: true });
    });

    audio.addEventListener('pause', () => {
      this.#emit('statechange', { playing: false });
    });

    audio.addEventListener('volumechange', () => {
      if (this.#audio.volume > 0 && !this.#audio.muted) {
        this.#lastVolume = this.#audio.volume;
      }
      this.#emit('volumechange', { volume: this.volume, muted: this.muted });
    });

    audio.addEventListener('ended', () => {
      this.#emit('statechange', { playing: false });
      this.#emit('ended', { track: this.#track });
    });

    audio.addEventListener('error', () => this.#handleNativeError());
  }

  /**
   * 把原生 MediaError 归类成中文提示后抛出业务事件。
   * @returns {void}
   */
  #handleNativeError() {
    // 主动 stop() 卸载音源时浏览器也会抛 error，这里需要忽略
    if (this.#disposed || !this.#track) {
      return;
    }
    const mediaError = this.#audio.error;
    const code = Number(mediaError?.code ?? 0);
    const message = AUDIO_ERROR_MESSAGES[code] ?? UNKNOWN_ERROR_MESSAGE;
    this.#setLoading(false);
    this.#emit('error', {
      code,
      message,
      track: this.#track,
      nativeMessage: mediaError?.message ?? '',
    });
  }

  /**
   * 记一次「刚提交过跳转」，在随后的一小段时间内做单向校验。
   * 与 #pendingSeek（元数据未就绪时暂存、loadedmetadata 补做）生命周期不同，故分开存。
   * @param {number} seconds 目标位置
   * @returns {void}
   */
  #armSeekGuard(seconds) {
    this.#clearSeekGuard();
    const guard = { target: seconds, timer: 0, corrected: false };
    // 兜底校验：切歌瞬间浏览器可能在 play 真正开始后才把位置重置回 0，
    // 而 playing 事件往往早于这次重置，所以要晚一点再确认一次。
    guard.timer = window.setTimeout(() => this.#verifySeekGuard(guard), 900);
    this.#seekGuard = guard;
  }

  /**
   * 清掉跳转校验记忆。
   * @returns {void}
   */
  #clearSeekGuard() {
    if (this.#seekGuard) {
      window.clearTimeout(this.#seekGuard.timer);
      this.#seekGuard = null;
    }
  }

  /**
   * 单向校验：只在播放位置落在目标**之前**时才补做跳转，
   * 位置已经 >= 目标说明播放正常前进，绝不往回拉。每次跳转最多校验两次。
   * @returns {void}
   */
  #verifySeekGuard(guard = this.#seekGuard) {
    if (!guard || this.#seekGuard !== guard) {
      return;
    }
    this.#clearSeekGuard();
    if (guard.corrected || !this.#track || this.#audio.ended) {
      return;
    }
    if (this.#audio.currentTime < guard.target - 0.75) {
      try {
        this.#audio.currentTime = guard.target;
      } catch (error) {
        console.error('[player] 恢复跳转失败：', error);
      }
    }
  }

  /**
   * 播放真正开始时先校验一次；若此时还不准，把兜底校验提前再确认一次。
   *
   * 注意：给 currentTime 赋值本身会再次派发 playing 事件，所以每次记忆
   * 最多只允许补做一次（corrected 标记），否则会「赋值 → playing → 再赋值」
   * 自激成死循环，播放位置永远停在起点。
   * @returns {void}
   */
  #applySeekGuardOnPlay() {
    const guard = this.#seekGuard;
    if (!guard || guard.corrected) {
      return;
    }
    if (this.#audio.currentTime < guard.target - 0.75) {
      guard.corrected = true;
      try {
        this.#audio.currentTime = guard.target;
      } catch (error) {
        console.error('[player] 恢复跳转失败：', error);
      }
    }
    // play 起步后浏览器仍可能再重置一次位置，400ms 后再确认一遍
    window.clearTimeout(guard.timer);
    guard.timer = window.setTimeout(() => this.#verifySeekGuard(), 400);
  }

  /**
   * 更新加载状态并在变化时通知订阅者。
   * @param {boolean} loading 是否加载中
   * @returns {void}
   */
  #setLoading(loading) {
    if (this.#loading === loading) {
      return;
    }
    this.#loading = loading;
    this.#emit('loading', { loading });
  }

  /**
   * 分发业务事件。
   * @param {string} type 事件名
   * @param {object} [detail] 事件负载
   * @returns {void}
   */
  #emit(type, detail = {}) {
    const handlers = this.#listeners.get(type);
    if (!handlers) {
      return;
    }
    handlers.forEach((handler) => {
      try {
        handler(detail);
      } catch (error) {
        console.error(`[player] 事件处理异常（${type}）：`, error);
      }
    });
  }
}
