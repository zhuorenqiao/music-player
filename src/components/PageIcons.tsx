/**
 * components/PageIcons.tsx —— 页面之间互跳的三枚图标
 *
 * 休眠页要一枚「电台」广播图标，电台页要一枚「休眠」月亮图标，两页又都要
 * 「音乐」音符 —— 三枚各自只有一条路径，抽到这里共用；顺带避免
 * SleepPage 与 RadioPage 互相 import 成环（两页已经通过 PlayGlyph 单向
 * 认识彼此）。
 *
 * 与 Flutter 侧同一套规格：月亮 = `lib/ui/sleep_moon.dart` 的 SleepMoonIcon，
 * 广播 / 音符 = `lib/ui/page_link_chip.dart` 的 BroadcastPainter / MusicNotePainter。
 * 改一处必须改另一处。
 */

/** 月亮图标：Feather 的 moon 路径，实心。顶栏入口与页面 logo 共用。 */
export function MoonIcon({ className = 'icon' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true">
      <path
        d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"
        fill="currentColor"
      />
    </svg>
  );
}

/** 广播波图标：下方实心点 + 上方三道同心弧（与 Flutter `BroadcastPainter` 同规格）。 */
export function BroadcastIcon({ className = 'icon' }: { className?: string }) {
  const arcs = [4.6, 7.2, 9.8].map((radius) => (
    `M ${12 - radius} 17.2 A ${radius} ${radius} 0 0 1 ${12 + radius} 17.2`
  ));
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true">
      <circle cx="12" cy="17.2" r="1.9" fill="currentColor" stroke="none" />
      {arcs.map((d) => <path key={d} d={d} />)}
    </svg>
  );
}

/** 音符图标（回音乐播放器）。 */
export function MusicNoteIcon({ className = 'icon' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M9 16.6V5.4l9-1.6v10.4" />
      <circle cx="6.6" cy="16.8" r="2.6" />
      <circle cx="15.6" cy="14.4" r="2.6" />
    </svg>
  );
}
