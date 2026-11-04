/**
 * generated-cover.js —— 按歌手名本地生成一张封面卡（最后一道兜底）
 *
 * 什么时候用：内嵌标签没有封面、在线也没匹配到专辑图 / 歌手照片时。
 * 与其显示一张跟这首歌毫无关系的通用音符图，不如显示一张**属于这位歌手**的图：
 * 配色、装饰都从歌手名派生，同一个人永远得到同一张，换首歌才变。
 *
 * 实现约束：
 * - 纯字符串拼 SVG，不联网、不用 canvas、不依赖字体测量，离线可用；
 * - 结果是 data URL，能直接进 <img src>，也能原样存进 IndexedDB 记录；
 * - **不要**把它写回 track.cover：那是「已经有封面」的标志，会让后续的在线匹配
 *   永久跳过。它只作为「显示时的替身」存在。
 */

/** 生成图尺寸（与封面显示尺寸同量级，缩放到任意大小都不糊）。 */
const SIZE = 600;

/**
 * FNV-1a 32 位哈希：够散、够快，且跨浏览器结果一致。
 * @param {string} text 输入
 * @returns {number} 无符号 32 位整数
 */
function hash(text) {
  let value = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 0x01000193);
  }
  return value >>> 0;
}

/**
 * 归一化歌手名（大小写、空格、常见前后缀差异都并到同一张图上）。
 * @param {string} artist 歌手名
 * @returns {string}
 */
function normalizeArtist(artist) {
  return String(artist ?? '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/[\u3000]/g, ' ')
    .replace(/\s*[-–—]\s*$/g, '');
}

/**
 * XML 文本转义（歌手名里出现 & < > 也不能把 SVG 打断）。
 * @param {string} text 原文
 * @returns {string}
 */
function escapeXml(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * 取首字：CJK 用一个字（「周」），拉丁字母取最多两个首字母（「JAY CHOU」→「JC」）。
 * @param {string} artist 歌手名
 * @returns {string}
 */
function initialsOf(artist) {
  const value = String(artist ?? '').trim();
  if (!value) {
    return '♪';
  }
  const chars = [...value.replace(/[^\p{L}\p{N}]/gu, ' ')].filter((char) => char.trim());
  if (chars.length === 0) {
    return '♪';
  }
  const isCjk = /[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]/u.test(chars[0]);
  if (isCjk) {
    return chars[0];
  }
  return chars.slice(0, 2).map((char) => char.toUpperCase()).join('');
}

/**
 * 生成歌手封面卡。
 * @param {string} artist 歌手名（配色与首字都来自它）
 * @param {string} [title] 曲名（只用于底部小字，不参与配色）
 * @returns {string} SVG data URL；同一歌手 + 同一曲名恒定返回同一串
 */
export function generatedCoverUrl(artist, title = '') {
  const key = normalizeArtist(artist) || 'unknown';
  const seed = hash(key);
  const hue = seed % 360;
  const hue2 = (hue + 32 + (seed % 26)) % 360;
  const rotation = seed % 4;
  const initials = initialsOf(artist);
  const label = String(artist ?? '').trim() || '未知歌手';
  const sub = String(title ?? '').trim();

  // 声波：用 seed 派生一串确定性的柱高，换歌手就换形状
  const bars = Array.from({ length: 27 }, (_, index) => {
    const wave = Math.sin((index + 1) * (1 + (seed % 5)) * 0.6) * 0.5 + 0.5;
    const jitter = ((hash(`${key}#${index}`) % 100) / 100) * 0.5;
    return 18 + Math.round((wave + jitter) * 46);
  });
  // 内容全部落在「安全圆」内：界面把封面裁成正圆后，靠边和靠底的像素会被剪掉，
  // 所以声波横向只占中间 68%，文字也放在圆心偏上，不再贴着底边
  const barSpan = SIZE * 0.68;
  const barStart = (SIZE - barSpan) / 2;
  const barWidth = barSpan / (bars.length * 1.9);
  const barsMarkup = bars
    .map((height, index) => {
      const x = barStart + (index * barSpan) / (bars.length - 1) - barWidth / 2;
      return `<rect x="${x.toFixed(1)}" y="${(SIZE * 0.6 - height / 2).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${height}" rx="${(barWidth / 2).toFixed(1)}" fill="hsl(${hue2} 85% 62% / 0.5)"/>`;
    })
    .join('');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}" role="img" aria-label="${escapeXml(label)}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="${rotation % 2 ? '1' : '0.35'}" y2="1">
    <stop offset="0" stop-color="hsl(${hue} 68% 22%)"/>
    <stop offset="0.55" stop-color="hsl(${hue2} 72% 34%)"/>
    <stop offset="1" stop-color="hsl(${(hue2 + 18) % 360} 78% 48%)"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.42" r="0.62">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.22"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
  </radialGradient>
</defs>
<rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>
<rect width="${SIZE}" height="${SIZE}" fill="url(#glow)"/>
<g fill="none" stroke="#ffffff" stroke-opacity="0.12">
  <circle cx="${SIZE / 2}" cy="${SIZE * 0.38}" r="150"/>
  <circle cx="${SIZE / 2}" cy="${SIZE * 0.38}" r="196"/>
  <circle cx="${SIZE / 2}" cy="${SIZE * 0.38}" r="242"/>
</g>
<text x="${SIZE / 2}" y="${SIZE * 0.38}" text-anchor="middle" dominant-baseline="central"
      font-family="'PingFang SC','Microsoft YaHei','Noto Sans SC',system-ui,sans-serif"
      font-size="${initials.length > 1 ? 168 : 216}" font-weight="700"
      fill="#ffffff" fill-opacity="0.92">${escapeXml(initials)}</text>
<g>${barsMarkup}</g>
<text x="${SIZE / 2}" y="${SIZE * 0.75}" text-anchor="middle"
      font-family="'PingFang SC','Microsoft YaHei','Noto Sans SC',system-ui,sans-serif"
      font-size="28" font-weight="600" letter-spacing="1"
      fill="#ffffff" fill-opacity="0.86">${escapeXml(label.slice(0, 14))}</text>
${sub ? `<text x="${SIZE / 2}" y="${SIZE * 0.845}" text-anchor="middle" font-family="'PingFang SC','Microsoft YaHei','Noto Sans SC',system-ui,sans-serif" font-size="18" fill="#ffffff" fill-opacity="0.55">${escapeXml(sub.slice(0, 16))}</text>` : ''}
</svg>`;

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg.replace(/\n\s*/g, ' '))}`;
}

/**
 * 这张封面是不是本地生成的兜底卡（用来区分「真封面」与「占位图」）。
 * @param {string} [cover] 封面的 src
 * @returns {boolean}
 */
export function isGeneratedCover(cover) {
  return typeof cover === 'string' && cover.startsWith('data:image/svg+xml');
}
