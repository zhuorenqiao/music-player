/**
 * recent-store.js —— 最近播放记录
 *
 * 只记录「播放历史」这件事本身：存快照（标题/歌手/封面/时长）+ 曲目 id +
 * 播放时间，最多保留 50 条。不碰 DOM，也不依赖播放列表对象，
 * 由调用方负责把 id 映射回真实的曲目。
 */

import { Storage } from './storage.js';

/** localStorage 键名。 */
const STORAGE_KEY = 'recent';

/** 最多保留的条数。 */
const MAX_ENTRIES = 50;

/**
 * 同一首歌在这段时间内的重复触发直接忽略（毫秒）。
 *
 * 只防「一次播放被连续派发多次」这类事件级抖动；窗口必须很小，
 * 否则用户快速切回刚播过的歌时不会置顶（3 秒就足以挡住真实操作）。
 */
const NOOP_WINDOW = 500;

/**
 * 一条记录是否结构完整。
 * @param {*} value 待判断的值
 * @returns {boolean}
 */
function isEntryLike(value) {
  return Boolean(value)
    && typeof value.id === 'string'
    && value.id.length > 0
    && typeof value.playedAt === 'number'
    && Number.isFinite(value.playedAt);
}

/**
 * 读取最近播放列表（已按时间倒序，损坏数据自动过滤）。
 * @returns {Array<object>}
 */
export function loadRecent() {
  const raw = Storage.read(STORAGE_KEY, []);
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .filter(isEntryLike)
    .map((entry) => ({
      id: entry.id,
      title: typeof entry.title === 'string' && entry.title ? entry.title : '未知曲目',
      artist: typeof entry.artist === 'string' ? entry.artist : '',
      album: typeof entry.album === 'string' ? entry.album : '',
      cover: typeof entry.cover === 'string' ? entry.cover : '',
      duration: typeof entry.duration === 'number' && Number.isFinite(entry.duration) ? entry.duration : Number.NaN,
      isLocal: entry.isLocal === true,
      playedAt: entry.playedAt,
    }))
    .sort((a, b) => b.playedAt - a.playedAt)
    .slice(0, MAX_ENTRIES);
}

/**
 * 记录一次播放：同一首歌会挪到最前面，短时间内重复触发只更新时间。
 * @param {object} track 曲目
 * @param {number} [now] 当前时间戳（便于测试）
 * @returns {Array<object>} 更新后的列表
 */
export function recordPlay(track, now = Date.now()) {
  if (!track || typeof track.id !== 'string' || !track.id) {
    return loadRecent();
  }

  const entries = loadRecent();
  const existing = entries.find((entry) => entry.id === track.id);

  // 刚记过（暂停后又恢复播放这类抖动）：直接忽略，不写盘也不重排
  if (existing && now - existing.playedAt < NOOP_WINDOW) {
    return entries;
  }

  const entry = {
    id: track.id,
    title: track.title || '未知曲目',
    artist: track.artist || '',
    album: track.album || '',
    cover: track.cover || '',
    duration: Number.isFinite(track.duration) ? track.duration : Number.NaN,
    isLocal: track.isLocal === true,
    playedAt: now,
  };

  // 再次播放同一首歌：复用旧条目并置顶，绝不产生重复项
  const next = [
    entry,
    ...entries.filter((item) => item.id !== track.id),
  ].slice(0, MAX_ENTRIES);

  Storage.write(STORAGE_KEY, next);
  return next;
}

/**
 * 从最近播放里移除一条记录。
 * @param {string} id 曲目 id
 * @returns {Array<object>} 更新后的列表
 */
export function removeRecent(id) {
  if (typeof id !== 'string' || !id) {
    return loadRecent();
  }
  const entries = loadRecent();
  const next = entries.filter((entry) => entry.id !== id);
  if (next.length === entries.length) {
    return entries;
  }
  if (next.length === 0) {
    Storage.remove(STORAGE_KEY);
  } else {
    Storage.write(STORAGE_KEY, next);
  }
  return next;
}

/**
 * 清空最近播放记录。
 * @returns {void}
 */
export function clearRecent() {
  Storage.remove(STORAGE_KEY);
}

/**
 * 把时间戳格式化成中文相对时间。
 * @param {number} timestamp 时间戳
 * @param {number} [now] 当前时间戳
 * @returns {string}
 */
export function formatRelativeTime(timestamp, now = Date.now()) {
  if (!Number.isFinite(timestamp)) {
    return '';
  }
  const diff = Math.max(0, now - timestamp);
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;

  if (diff < minute) {
    return '刚刚';
  }
  if (diff < hour) {
    return `${Math.floor(diff / minute)} 分钟前`;
  }
  if (diff < day) {
    return `${Math.floor(diff / hour)} 小时前`;
  }

  const date = new Date(timestamp);
  const today = new Date(now);
  const yesterday = new Date(now - day);
  const sameDay = (a, b) => a.getFullYear() === b.getFullYear()
    && a.getMonth() === b.getMonth()
    && a.getDate() === b.getDate();

  if (sameDay(date, yesterday)) {
    return '昨天';
  }
  if (diff < 7 * day) {
    return `${Math.floor(diff / day)} 天前`;
  }

  const pad = (value) => String(value).padStart(2, '0');
  const stamp = `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return date.getFullYear() === today.getFullYear() ? stamp : `${date.getFullYear()}-${stamp}`;
}
