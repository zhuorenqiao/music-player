/**
 * storage.js —— localStorage 的安全封装
 *
 * 目标：任何一次读写都不允许把异常抛给调用方（隐私模式、配额超限、
 * 存储的数据被手动改坏都可能抛错），损坏的数据一律回退到默认值。
 */

/** 命名空间前缀，避免和其它页面/版本的数据互相污染。 */
const NAMESPACE = 'light-music-player:v1:';

/** 把任意值序列化成字符串后写入，失败只记录不抛出。 */
function writeRaw(fullKey, serialized) {
  try {
    window.localStorage.setItem(fullKey, serialized);
    return true;
  } catch (error) {
    console.error('[storage] 写入失败：', fullKey, error);
    return false;
  }
}

/**
 * localStorage 门面对象。
 * 所有方法都自带 try/catch，返回值一定可用。
 */
export const Storage = {
  /**
   * 读取并反序列化一个键。
   * @param {string} key 业务键名（不含命名空间）
   * @param {*} fallback 读取失败 / 数据缺失 / 数据损坏时返回的默认值
   * @returns {*} 反序列化后的值或默认值
   */
  read(key, fallback) {
    const fullKey = NAMESPACE + key;
    let raw = null;
    try {
      raw = window.localStorage.getItem(fullKey);
    } catch (error) {
      console.error('[storage] 读取失败：', fullKey, error);
      return fallback;
    }
    if (raw === null) {
      return fallback;
    }
    try {
      return JSON.parse(raw);
    } catch (error) {
      // 数据被改坏：顺手清掉，避免每次启动都报错
      console.error('[storage] 数据损坏，已回退默认值：', fullKey, error);
      Storage.remove(key);
      return fallback;
    }
  },

  /**
   * 序列化并写入一个键。
   * @param {string} key 业务键名（不含命名空间）
   * @param {*} value 任意可 JSON 化的值
   * @returns {boolean} 是否写入成功
   */
  write(key, value) {
    let serialized = '';
    try {
      serialized = JSON.stringify(value);
    } catch (error) {
      console.error('[storage] 序列化失败：', key, error);
      return false;
    }
    return writeRaw(NAMESPACE + key, serialized);
  },

  /**
   * 删除一个键。
   * @param {string} key 业务键名（不含命名空间）
   * @returns {boolean} 是否删除成功
   */
  remove(key) {
    try {
      window.localStorage.removeItem(NAMESPACE + key);
      return true;
    } catch (error) {
      console.error('[storage] 删除失败：', key, error);
      return false;
    }
  },
};

/**
 * 读取数字并做区间校验，类型不对或越界时返回默认值。
 * @param {string} key 业务键名
 * @param {number} fallback 默认值
 * @param {number} min 允许的最小值
 * @param {number} max 允许的最大值
 * @returns {number}
 */
export function readNumber(key, fallback, min = -Infinity, max = Infinity) {
  const value = Storage.read(key, fallback);
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, value));
}

/**
 * 读取布尔值，仅接受真正的 true / false。
 * @param {string} key 业务键名
 * @param {boolean} fallback 默认值
 * @returns {boolean}
 */
export function readBoolean(key, fallback) {
  const value = Storage.read(key, fallback);
  return typeof value === 'boolean' ? value : fallback;
}
