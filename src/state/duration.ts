/**
 * duration.ts —— 探本地文件的时长并落库
 *
 * 单独成模块是因为有**两个**入口都要它：
 *   1. 导入时（library.tsx）—— 刚入列、duration 还是 NaN；
 *   2. 启动还原时（player.tsx）—— 早于「时长落库」这版逻辑导出的老记录，
 *      IndexedDB 里 duration 是 null，不补探就永远显示「总时长 0:00」，
 *      而且歌词匹配会一直卡在「正在读取音频信息…」（它要求时长有限）。
 *
 * 只丢弃临时 audio 的 src，绝不 revoke 主地址（那会打断正在播的音频）。
 */

import { patchTrack as patchLocalRecord } from '../lib/local-store.js';
import { DURATION_PROBE_TIMEOUT } from './constants';
import type { Track } from './types';

/**
 * 用临时 audio 预读时长。
 * @param track 已入列的曲目
 * @returns 是否真的填上了一个有效时长
 */
export function probeTrackDuration(track: Track): Promise<boolean> {
  if (!track || Number.isFinite(track.duration)) {
    return Promise.resolve(false);
  }
  return new Promise((resolve) => {
    let probe: HTMLAudioElement;
    try {
      probe = new Audio();
    } catch (error) {
      console.error('[duration] 无法创建临时 audio：', error);
      resolve(false);
      return;
    }
    probe.preload = 'metadata';
    let settled = false;

    const finish = (value: number) => {
      if (settled) {
        return;
      }
      settled = true;
      window.clearTimeout(timer);
      try {
        probe.removeAttribute('src');
        probe.load();
      } catch (error) {
        console.error('[duration] 释放临时 audio 失败：', error);
      }
      if (!Number.isFinite(value) || value <= 0) {
        resolve(false);
        return;
      }
      track.duration = value;
      // 必须写回 IndexedDB：本地曲目的 localStorage 序列化会跳过它们，
      // 不补这一刀，刷新后时长又变 NaN。
      void patchLocalRecord(track.id, { duration: value });
      resolve(true);
    };

    const timer = window.setTimeout(() => finish(Number.NaN), DURATION_PROBE_TIMEOUT);
    probe.addEventListener('loadedmetadata', () => finish(probe.duration), { once: true });
    probe.addEventListener('error', () => finish(Number.NaN), { once: true });
    probe.src = track.src;
  });
}

/**
 * 批量探时长。
 * @param tracks 候选曲目
 * @returns 填上了时长的曲目数
 */
export async function probeDurations(tracks: Track[]): Promise<number> {
  let filled = 0;
  // 串行：几十个 Audio 元素同时解码会抢媒体线程，反而更慢
  for (const track of tracks) {
    if (await probeTrackDuration(track)) {
      filled += 1;
    }
  }
  return filled;
}
