/**
 * spin.ts —— 三张圆碟的相位对齐
 *
 * CSS 动画在被 `display:none` 时会销毁、重新显示时从 0deg 重来。曲目区主封面、
 * 歌词页头部封面、控制条小圆碟是三个不同元素，不处理的话切一次页就能看到
 * 封面「啪」地转回原位。
 *
 * 做法：以**始终可见的控制条小圆碟**为母钟，其它碟在挂载或切视图后把
 * `animation.currentTime` 对齐到母钟。三者速率相同（同一个 --cover-spin-duration），
 * 对齐一次之后就一直同相。
 */

import { useEffect } from 'react';

/** 把一个元素的动画时间对齐到母钟元素。 */
export function syncToMaster(master: HTMLElement | null, follower: HTMLElement | null): void {
  if (!master || !follower) {
    return;
  }
  const source = master.getAnimations()[0];
  const target = follower.getAnimations()[0];
  const at = source?.currentTime;
  if (target && typeof at === 'number' && Number.isFinite(at)) {
    target.currentTime = at;
  }
}

/**
 * 注册一个「从属圆碟」：挂载后与母钟对齐一次。
 * @param ref 目标元素
 * @param masterRef 母钟元素
 * @param deps 触发重新对齐的依赖（如视图切换）
 * @returns void
 */
export function useSpinFollower(
  ref: { current: HTMLElement | null },
  master: { current: HTMLElement | null },
  deps: unknown[] = [],
): void {
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    // 等一帧：刚切视图时目标元素的动画还没被创建
    const id = window.requestAnimationFrame(() => syncToMaster(master.current, ref.current));
    return () => window.cancelAnimationFrame(id);
  }, deps);
}
