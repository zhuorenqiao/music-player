/**
 * BilingualToggle.tsx —— 非中文歌词的「双语」开关
 *
 * 只在当前歌词判出来是外语时出现；关掉了就只留原文一行。
 * 偏好写在 localStorage，下次打开还在。重新打开时绕过缓存再要一次译文，
 * 所以「译文获取失败」不必刷新整页。
 *
 * 播放页和歌词页都跟在歌名右侧，统一小一号（26px 高），两处规格一致。
 */

import { useLyrics } from '../state/lyrics';

const BilingualIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M3.5 6.5h7M6.8 4.6v1.9M8.6 6.5c-.5 3.4-2.4 6-5.1 7.4" />
    <path d="M6.2 11.2l2.3 3.5M10.2 11.2L7.9 14.7" />
    <path d="M13.4 19.4l3.3-8 3.3 8M14.6 16.6h4.2" />
  </svg>
);

export function BilingualToggle() {
  const { translatable, bilingual, setBilingual, transState, transNote } = useLyrics();
  if (!translatable) {
    return null;
  }
  const titleMap: Record<string, string> = {
    loading: '正在获取中文译文…',
    none: '译文库里没有这首歌的中文译文',
    unavailable: '中文译文依赖本地代理服务（npm run dev）',
    error: transNote || '中文译文获取失败',
  };
  return (
    <button
      className="lyrics-bilingual"
      type="button"
      role="switch"
      aria-checked={bilingual}
      title={titleMap[transState] || (bilingual ? '关闭中文译文对照' : '开启中文译文对照')}
      onClick={() => setBilingual(!bilingual)}
    >
      <BilingualIcon />
      <span>双语</span>
    </button>
  );
}
