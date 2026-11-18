/**
 * lyric-fonts.ts —— 「T」面板里可选的歌词字体
 *
 * 两种来源：
 *   · 系统已装字体 —— 即时生效、零下载，缺了就按降级栈落到同气质的字上；
 *   · 随包内置的开源字体（霞鹜文楷 / 得意黑）—— 放在 public/fonts 下、本地加载，
 *     不依赖任何外网 CDN，但体积大（得意黑 1.1MB、文楷按 unicode-range 切了 97 片），
 *     所以**按需注入**：打开面板或上次选的就是它，才把样式表挂进 <head>。
 * 家族名统一加 'Lyric ' 前缀，避免和用户系统里装的同名开源字体打架 ——
 * 否则系统字体可能抢在我们这份前面被用上，效果就不受控了。
 */

export interface LyricFontOption {
  /** 存进 localStorage 的 id；改名会让旧值失效，由 findLyricFont 兜回默认 */
  id: string;
  /** 面板按钮上的文字（用该字体自己渲染）与无障碍名称 */
  name: string;
  /** 提示里的补充说明：这款字是什么气质 */
  hint: string;
  /** CSS font-family；空字符串表示跟随界面默认字体 */
  stack: string;
  /** 需要按需注入的本地字体样式表（相对当前页面，dev 在根路径下也是对的）；系统字体不填 */
  webFont?: string;
}

export const LYRIC_FONTS: readonly LyricFontOption[] = Object.freeze([
  {
    id: 'default',
    name: '默认',
    hint: '界面字体',
    stack: '',
  },
  {
    id: 'song',
    name: '思源宋',
    hint: '粗衬线，海报/杂志感',
    stack: '"Source Han Serif SC Heavy", "Source Han Serif SC", "Noto Serif SC", "Songti SC", SimSun, serif',
  },
  {
    id: 'hyhei',
    name: '汉仪黑',
    hint: '商业黑体，块面硬朗',
    stack: '"HYZhongHei 197", "Noto Sans SC", "Microsoft YaHei", sans-serif',
  },
  {
    id: 'noto',
    name: 'Noto 黑',
    hint: '中性无衬线，干净',
    stack: '"Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif',
  },
  {
    id: 'deng',
    name: '等线细',
    hint: '极细笔画，轻盈',
    stack: '"DengXian Light", DengXian, "Noto Sans SC", "Microsoft YaHei", sans-serif',
  },
  {
    id: 'kai',
    name: '楷体',
    hint: '手写书法，笔锋',
    stack: 'KaiTi, STKaiti, "Kaiti SC", "Noto Serif SC", serif',
  },
  {
    id: 'mono',
    name: '等宽码',
    hint: '终端等宽，科技感',
    stack: '"Cascadia Code", "Noto Sans SC", "Microsoft YaHei", monospace',
  },
  {
    id: 'smiley',
    name: '得意黑',
    hint: '倾斜显示体，最有潮流感',
    stack: "'Lyric Smiley', 'Smiley Sans Oblique', 'Noto Sans SC', 'Microsoft YaHei', sans-serif",
    webFont: 'fonts/smiley-sans/smiley-sans.css',
  },
  {
    id: 'wenkai',
    name: '霞鹜文楷',
    hint: '文楷手写体，温润有笔锋',
    stack: "'Lyric WenKai', 'LXGW WenKai', 'Noto Serif SC', KaiTi, serif",
    webFont: 'fonts/lxgw-wenkai/lxgw-wenkai.css',
  },
]);

/** 默认那款（跟随界面字体），也是找不到已存 id 时的兜底。 */
export const DEFAULT_LYRIC_FONT: LyricFontOption = LYRIC_FONTS[0];

export function findLyricFont(id: string | null | undefined): LyricFontOption {
  return LYRIC_FONTS.find((font) => font.id === id) ?? DEFAULT_LYRIC_FONT;
}

/**
 * 把一款内置字体需要的样式表挂进 <head>，同一个 href 只挂一次。
 * 用 <link> 而不是 JS 里读文件：交给浏览器自己去解析 @font-face 和 unicode-range，
 * 该下哪几片由它按实际字符决定。
 */
export function ensureLyricWebFont(href: string | undefined): void {
  if (!href || typeof document === 'undefined') {
    return;
  }
  if (document.head.querySelector(`link[data-lyric-web-font="${href}"]`)) {
    return;
  }
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = href;
  link.setAttribute('data-lyric-web-font', href);
  document.head.appendChild(link);
}

/** 面板一打开就把所有内置字体的样式表挂上：每颗按钮要用自己的字体渲染名字。 */
export function ensureAllLyricWebFonts(): void {
  for (const font of LYRIC_FONTS) {
    ensureLyricWebFont(font.webFont);
  }
}
