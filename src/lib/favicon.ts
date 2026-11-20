/**
 * favicon.ts —— 站点图标（浏览器页签 / 收藏夹 / 地址栏里的那个小图标）
 *
 * 图形就是页头左上角的 logo：圆角方块 + 五条音柱（src/App.tsx 里 .brand__logo 的那段 path
 * `M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4`），这里按 24 网格等比放大到 512。
 * 底色固定用深色（与 Windows / Android 桌面图标 tool/brand/app_icon_master.png 一致），
 * 音柱和描边用当前主题色 —— 换肤时页签图标跟着变，不用再去改图标文件。
 *
 * 静态兜底是 public/favicon.svg（薄荷绿默认色），JS 起来后由这里接管 href。
 */

const VIEW = 512;

/** 音柱：x 中心 / 高度，取自页头 logo 的 24 网格 path，等比换算到 512 */
const BARS: { cx: number; height: number }[] = [
  { cx: 4, height: 4 },
  { cx: 8, height: 12 },
  { cx: 12, height: 18 },
  { cx: 16, height: 10 },
  { cx: 20, height: 4 },
];

/** 音柱粗细：页头是 1.8 的描边（圆头），这里当实心圆角矩形画 */
const BAR_WIDTH = 1.9;

/**
 * 生成图标 SVG 源码。
 * @param accent 当前主题色（#rrggbb），来自 CSS 变量 --accent
 */
export function faviconSvg(accent: string): string {
  if (!/^#[0-9a-f]{6}$/i.test(accent)) {
    return '';
  }
  const scale = VIEW / 24;
  const barW = BAR_WIDTH * scale;
  const bars = BARS.map(({ cx, height }) => {
    const x = cx * scale - barW / 2;
    const h = height * scale;
    const y = VIEW / 2 - h / 2;
    return `<rect x="${round(x)}" y="${round(y)}" width="${round(barW)}" height="${round(h)}" rx="${round(barW / 2)}" fill="${accent}"/>`;
  }).join('');

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="流光音乐">',
    '<defs>',
    `<linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${accent}" stop-opacity="0.26"/><stop offset="1" stop-color="${accent}" stop-opacity="0.06"/></linearGradient>`,
    '</defs>',
    '<rect x="6" y="6" width="500" height="500" rx="140" fill="#0a0e14"/>',
    '<rect x="6" y="6" width="500" height="500" rx="140" fill="url(#g)"/>',
    `<rect x="6" y="6" width="500" height="500" rx="140" fill="none" stroke="${accent}" stroke-opacity="0.55" stroke-width="8"/>`,
    bars,
    '</svg>',
  ].join('');
}

const round = (value: number): number => Math.round(value * 100) / 100;

/** 把 <link rel="icon"> 的 href 换成当前主题色的图标（同一元素复用，不重复插） */
export function applyFavicon(accent: string): void {
  const svg = faviconSvg(accent);
  if (!svg) {
    return;
  }
  const href = `data:image/svg+xml,${encodeURIComponent(svg)}`;
  const head = document.head;
  let link = head.querySelector<HTMLLinkElement>('link[id="app-favicon"]');
  if (!link) {
    link = document.createElement('link');
    link.id = 'app-favicon';
    link.rel = 'icon';
    link.type = 'image/svg+xml';
    head.appendChild(link);
  }
  if (link.getAttribute('href') !== href) {
    link.setAttribute('href', href);
  }
}
