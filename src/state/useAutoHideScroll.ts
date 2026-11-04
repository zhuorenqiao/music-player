/**
 * useAutoHideScroll.ts —— 滚动条「滚动时才出现」
 *
 * Windows 上 Chrome 的滚动条是常驻的，静止时那根灰条会一直压在内容边上（歌词页尤其明显）。
 * 这里在滚动事件里给容器挂一个 `is-scrolling`，CSS 侧平时把滑块设成透明、滚动时才显色。
 *
 * 为什么用 state 而不是直接在 DOM 上 classList.add：
 * 这些容器都是 React 渲染的，className 由 props 决定；命令式加的类在某些重渲染路径下会被覆盖。
 * 顺带用 ref 记一份当前态，避免滚动过程中每个 scroll 事件都 setState（一次滚动只重渲染两次：开始、结束）。
 */

import { useEffect, useRef, useState } from 'react';

/** 停止滚动多久后收回滚动条（毫秒）。 */
const HIDE_DELAY = 900;

export function useAutoHideScroll<T extends HTMLElement>(): {
  ref: React.RefObject<T>;
  scrolling: boolean;
} {
  const ref = useRef<T>(null);
  const [scrolling, setScrolling] = useState(false);
  const active = useRef(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) {
      return;
    }
    let timer = 0;
    const onScroll = () => {
      if (!active.current) {
        active.current = true;
        setScrolling(true);
      }
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        active.current = false;
        setScrolling(false);
      }, HIDE_DELAY);
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      el.removeEventListener('scroll', onScroll);
      window.clearTimeout(timer);
    };
  }, []);

  return { ref, scrolling };
}
