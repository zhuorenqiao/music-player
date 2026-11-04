/**
 * chinese.ts —— 繁体歌词转简体
 *
 * 用 OpenCC 的 t2cn 包（台湾繁体 → 简体），只做显示层转换：
 * 原始歌词、LRCLIB 缓存都保持原样，手动导入的 .lrc 也不动。
 */

import { Converter } from 'opencc-js/t2cn';

const convert = Converter({ from: 'tw', to: 'cn' });

/** 同一段歌词只转一次（切歌来回不会重复跑词典） */
const cache = new Map<string, string>();
const CACHE_LIMIT = 64;

/**
 * 把繁体中文转成简体。已经是简体时原样返回。
 * @param text 原始歌词文本
 */
export function toSimplified(text: string): string {
  if (!text) {
    return text;
  }
  const hit = cache.get(text);
  if (hit !== undefined) {
    return hit;
  }
  // OpenCC 保留的常用异体字，按大陆简体习惯统一
  const converted = convert(text).replace(/妳/g, '你').replace(/甚么/g, '什么');
  cache.set(text, converted);
  if (cache.size > CACHE_LIMIT) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) {
      cache.delete(oldest);
    }
  }
  return converted;
}
