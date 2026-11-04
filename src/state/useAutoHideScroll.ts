/**
 * useAutoHideScroll.ts —— 滚动条「滚动时才出现」
 *
 * Windows 上 Chrome 的滚动条是常驻的，静止时那根灰条会一直压在内容边上（歌词页尤其明显）。
 * 这里在滚动事件里给容器挂一个 `is-scrolling`，CSS 侧平时把滑块设成透明、滚动时才显色。
 *
 * 「滚动」只认用户滚动：歌词跟随播放会自动 scrollTo 居中，如果连这种程序化滚动
 * 也算，每换一行滚动条就会闪一下。所以先用滚轮 / 触摸 / 按键 / 按下这些输入事件
 * 打点，只有打点之后（或已经开始显示的这一次滚动里）的 scroll 才点亮滚动条。
 *
 * 为什么用 state 而不是直接在 DOM 上 classList.add：
 * 这些容器都是 React 渲染的，className 由 props 决定；命令式加的类在某些重渲染路径下会被覆盖。
 * 顺带用 ref 记一份当前态，避免滚动过程中每个 scroll 事件都 setState（一次滚动只重渲染两次：开始、结束）。
 */

import { useEffect, useRef, useState } from 'react';

/** 停止滚动多久后收回滚动条（毫秒）。 */
const HIDE_DELAY = 900;

/** 用户输入之后多久内的滚动算「用户滚动」（毫秒）。滚轮惯性、触摸拖动都落在窗口内。 */
const USER_INPUT_WINDOW = 700;

/** 真正会把容器滚起来的按键；点歌词行是定位播放，不能算。 */
const SCROLL_KEYS = new Set(['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' ']);

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
    let lastInputAt = 0;
    const markInput = () => {
      lastInputAt = Date.now();
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (SCROLL_KEYS.has(event.key)) {
        markInput();
      }
    };
    const onScroll = () => {
      // 没有用户输入的滚动（歌词自动居中）= 不显示滚动条；
      // 但已经因用户滚动亮起的这一次，要跟着滚完再收（拖动滚动条、惯性都在这里）
      const userDriven = Date.now() - lastInputAt <= USER_INPUT_WINDOW;
      if (!userDriven && !active.current) {
        return;
      }
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
    el.addEventListener('wheel', markInput, { passive: true });
    el.addEventListener('touchmove', markInput, { passive: true });
    el.addEventListener('keydown', onKeyDown);
    return () => {
      el.removeEventListener('scroll', onScroll);
      el.removeEventListener('wheel', markInput);
      el.removeEventListener('touchmove', markInput);
      el.removeEventListener('keydown', onKeyDown);
      window.clearTimeout(timer);
    };
  }, []);

  return { ref, scrolling };
}
