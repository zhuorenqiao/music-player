/**
 * local-store.js —— 把用户添加的本地音频持久化到 IndexedDB
 *
 * 为什么需要它：
 * `URL.createObjectURL(file)` 得到的是 `blob:` 地址，只在当前页面会话内有效，
 * 刷新即失效 —— 所以只把元数据存进 localStorage 是不够的，歌单刷新后必然丢失。
 * 这里把 File/Blob 本身写进 IndexedDB（浏览器允许存 Blob，且容量远大于
 * localStorage），刷新后重新 createObjectURL 就能完整还原歌单。
 *
 * 全部接口都不抛异常，失败以 { ok, error } 返回，由调用方决定怎么提示。
 */

/** 数据库与对象仓库名。 */
const DB_NAME = 'light-music-player';
const DB_VERSION = 1;
const STORE = 'local-tracks';

/** 单曲大小上限（128MB），避免误存超大文件把配额吃光。 */
const MAX_TRACK_BYTES = 128 * 1024 * 1024;

/** @type {Promise<IDBDatabase>|null} 连接缓存 */
let dbPromise = null;

/**
 * IndexedDB 是否可用（隐私模式 / 老旧浏览器可能没有）。
 * @returns {boolean}
 */
export function isSupported() {
  try {
    return typeof indexedDB !== 'undefined' && indexedDB !== null;
  } catch {
    return false;
  }
}

/**
 * 打开数据库（带连接缓存），首次使用自动建对象仓库。
 * @returns {Promise<IDBDatabase>}
 */
function openDb() {
  if (dbPromise) {
    return dbPromise;
  }
  dbPromise = new Promise((resolve, reject) => {
    if (!isSupported()) {
      reject(new Error('当前浏览器不支持 IndexedDB'));
      return;
    }
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: 'id' });
      }
    };
    request.onsuccess = () => {
      const db = request.result;
      // 连接被别的标签页升级时主动让路，避免卡死
      db.onversionchange = () => {
        db.close();
        dbPromise = null;
      };
      resolve(db);
    };
    request.onerror = () => {
      dbPromise = null;
      reject(request.error ?? new Error('打开 IndexedDB 失败'));
    };
    request.onblocked = () => {
      dbPromise = null;
      reject(new Error('IndexedDB 被其它页面占用'));
    };
  });
  return dbPromise;
}

/**
 * 在一个事务里执行操作并等待事务完成。
 * @param {IDBTransactionMode} mode 事务模式
 * @param {(store: IDBObjectStore) => void} run 操作
 * @returns {Promise<void>}
 */
async function withStore(mode, run) {
  const db = await openDb();
  await new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, mode);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error('IndexedDB 事务失败'));
    transaction.onabort = () => reject(transaction.error ?? new Error('IndexedDB 事务被中断'));
    run(transaction.objectStore(STORE));
  });
}

/**
 * 读取全部已保存的本地曲目。
 * @returns {Promise<object[]>} 记录数组（按 addedAt 升序）
 */
export async function loadAll() {
  if (!isSupported()) {
    return [];
  }
  try {
    const db = await openDb();
    const records = await new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE, 'readonly');
      const request = transaction.objectStore(STORE).getAll();
      request.onsuccess = () => resolve(request.result ?? []);
      request.onerror = () => reject(request.error ?? new Error('读取本地曲目失败'));
    });
    return records
      .filter((record) => record && record.id && record.blob)
      .sort((a, b) => (a.addedAt ?? 0) - (b.addedAt ?? 0));
  } catch (error) {
    console.error('[local-store] 读取本地曲目失败：', error);
    return [];
  }
}

/**
 * 把一条记录转成播放器使用的曲目对象（重新生成 objectURL）。
 * @param {object} record IndexedDB 记录
 * @param {string} fallbackCover 兜底封面
 * @returns {object|null}
 */
export function recordToTrack(record, fallbackCover) {
  try {
    return {
      id: record.id,
      title: record.title || '未命名音频',
      artist: record.artist || '本地文件',
      album: record.album || '',
      cover: record.cover || fallbackCover,
      src: URL.createObjectURL(record.blob),
      duration: typeof record.duration === 'number' ? record.duration : Number.NaN,
      isLocal: true,
      lyrics: record.lyrics || '',
      lyricsPlain: record.lyricsPlain || '',
      lyricsSource: record.lyricsSource || '',
      restored: true,
    };
  } catch (error) {
    console.error('[local-store] 还原曲目失败：', record?.title, error);
    return null;
  }
}

/**
 * 保存一批本地曲目。
 * @param {Array<{track: object, file: File}>} entries 曲目与对应文件
 * @returns {Promise<{ok: boolean, saved: number, error?: string}>}
 */
export async function saveMany(entries) {
  const valid = (entries ?? []).filter((entry) => entry && entry.track && entry.file);
  if (valid.length === 0) {
    return { ok: true, saved: 0 };
  }
  if (!isSupported()) {
    return { ok: false, saved: 0, error: 'unsupported' };
  }

  let saved = 0;
  try {
    await withStore('readwrite', (store) => {
      valid.forEach(({ track, file }) => {
        if (file.size > MAX_TRACK_BYTES) {
          return;
        }
        store.put({
          id: track.id,
          blob: file,
          name: file.name,
          type: file.type,
          size: file.size,
          lastModified: file.lastModified,
          addedAt: Date.now(),
          title: track.title,
          artist: track.artist,
          album: track.album,
          cover: track.cover,
          duration: Number.isFinite(track.duration) ? track.duration : null,
          lyrics: track.lyrics || '',
          lyricsPlain: track.lyricsPlain || '',
          lyricsSource: track.lyricsSource || '',
        });
        saved += 1;
      });
    });
    return { ok: true, saved };
  } catch (error) {
    const quota = error?.name === 'QuotaExceededError' || /quota/i.test(error?.message ?? '');
    console.error('[local-store] 保存本地曲目失败：', error);
    return { ok: false, saved: 0, error: quota ? 'quota' : 'unknown' };
  }
}

/**
 * 更新某首本地曲目的元数据（例如歌词匹配结果、时长回填）。
 * @param {string} id 曲目 id
 * @param {Partial<object>} patch 需要更新的字段
 * @returns {Promise<boolean>}
 */
export async function patchTrack(id, patch) {
  if (!isSupported() || !id) {
    return false;
  }
  try {
    const db = await openDb();
    const record = await new Promise((resolve, reject) => {
      const request = db.transaction(STORE, 'readonly').objectStore(STORE).get(id);
      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => reject(request.error);
    });
    if (!record) {
      return false;
    }
    await withStore('readwrite', (store) => {
      store.put({ ...record, ...patch });
    });
    return true;
  } catch (error) {
    console.error('[local-store] 更新本地曲目失败：', error);
    return false;
  }
}

/**
 * 删除一条本地曲目记录。
 * @param {string} id 曲目 id
 * @returns {Promise<void>}
 */
export async function remove(id) {
  if (!isSupported() || !id) {
    return;
  }
  try {
    await withStore('readwrite', (store) => {
      store.delete(id);
    });
  } catch (error) {
    console.error('[local-store] 删除本地曲目失败：', error);
  }
}

/**
 * 清空所有本地曲目记录。
 * @returns {Promise<void>}
 */
export async function clear() {
  if (!isSupported()) {
    return;
  }
  try {
    await withStore('readwrite', (store) => {
      store.clear();
    });
  } catch (error) {
    console.error('[local-store] 清空本地曲目失败：', error);
  }
}

/**
 * 申请持久化存储权限，降低被浏览器自动清理的概率（不支持时静默跳过）。
 * @returns {Promise<boolean>}
 */
export async function requestPersistentStorage() {
  try {
    if (navigator.storage && typeof navigator.storage.persist === 'function') {
      if (await navigator.storage.persisted?.()) {
        return true;
      }
      return await navigator.storage.persist();
    }
  } catch (error) {
    console.error('[local-store] 申请持久化存储失败：', error);
  }
  return false;
}
