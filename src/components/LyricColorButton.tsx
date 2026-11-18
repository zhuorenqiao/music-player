/**
 * LyricColorButton.tsx —— 歌词高亮色 + 字号 + 字体
 *
 * 频谱条左端一个「T」小按钮，点开是三排：色板 / 字号滑杆 / 字体：
 *   · 色板选中的颜色同时作用于当前行歌词（文字 + 辉光）和非彩色频谱的色相；
 *   · 字号滑杆缩放歌词字号（70% ~ 150%，100% = 设计稿原值），
 *     首页紧凑歌词与歌词页一起生效；
 *   · 字体那一排每颗按钮用它自己的字体渲染名字，选中的字体同样作用于两处歌词。
 * 三项都写进 localStorage，下次进来还是上次的设置。
 * 第一颗「薄荷」是主题默认（不写死颜色，主题换了它也跟着换）。
 */

import { useEffect, useRef, useState } from 'react';
import {
  LYRIC_SCALE_DEFAULT, LYRIC_SCALE_MAX, LYRIC_SCALE_MIN, useWaveStyle,
} from '../state/wave-style';
import { LYRIC_FONTS, ensureAllLyricWebFonts } from '../lib/lyric-fonts';
import { highlightOnLight, useTheme } from '../state/theme';

/** 色板顺序按色相排，默认那颗放最前面。 */
const PRESETS: Array<{ name: string; color: string }> = [
  { name: '薄荷（默认）', color: '' },
  { name: '青', color: '#7de3ff' },
  { name: '蓝', color: '#8aa9ff' },
  { name: '紫', color: '#b98cff' },
  { name: '玫红', color: '#ff8fc7' },
  { name: '橙', color: '#ffb066' },
  { name: '金', color: '#ffe066' },
  { name: '白', color: '#f2f7fb' },
];

export function LyricColorButton() {
  const {
    lyricColor, setLyricColor, lyricScale, setLyricScale, lyricFont, setLyricFont,
  } = useWaveStyle();
  const { resolvedMode } = useTheme();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  /** 白色主题下预览要跟实际效果一致：浅色会被自动压暗到白底读得清 */
  const swatchColor = (color: string): string => {
    if (!color) {
      return 'var(--accent-light)';
    }
    return resolvedMode === 'light' ? highlightOnLight(color) : color;
  };

  /**
   * 面板一打开就先挂上内置字体（文楷 / 得意黑）的样式表：
   * 每颗字体按钮要用它自己的字体渲染名字，等选中再加载的话按钮会先显示成兜底字。
   */
  useEffect(() => {
    if (open) {
      ensureAllLyricWebFonts();
    }
  }, [open]);

  /** 点面板以外收起；捕获阶段监听，免得先被别的点击处理掉。 */
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        setOpen(false);
      }
    };
    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('keydown', onKeyDown, true);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('keydown', onKeyDown, true);
    };
  }, [open]);

  return (
    <div className="lyric-color" ref={rootRef}>
      <button
        className="lyric-color__trigger"
        type="button"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label="歌词高亮颜色、字号与字体"
        title="歌词高亮颜色、字号与字体"
        onClick={() => setOpen((value) => !value)}
      >
        T
      </button>

      {open && (
        <div
          className="lyric-color__panel"
          role="group"
          aria-label="歌词高亮颜色、字号与字体"
          /* 拖字号滑杆时别让手势冒泡到页面（滑切歌 / 翻封面），
             也别触发浏览器的文字拖动和长按菜单 */
          onPointerDown={(event) => event.stopPropagation()}
          onTouchStart={(event) => event.stopPropagation()}
          onDragStart={(event) => event.preventDefault()}
          onContextMenu={(event) => event.preventDefault()}
        >
          <div className="lyric-color__swatches">
            {PRESETS.map((preset) => {
              const active = lyricColor === preset.color;
              return (
                <button
                  key={preset.name}
                  className="lyric-color__swatch"
                  type="button"
                  style={{ background: swatchColor(preset.color) }}
                  aria-label={preset.name}
                  aria-pressed={active}
                  title={preset.name}
                  data-active={active || undefined}
                  onClick={() => {
                    setLyricColor(preset.color);
                    // 选完颜色不再自动收起：用户常常接着调字号
                  }}
                />
              );
            })}
          </div>

          {/* 字号滑杆：默认 100%，左右分别是缩小 / 放大。
              百分比本身就是按钮：点一下回到默认大小。 */}
          <label className="lyric-color__size">
            <span className="lyric-color__size-icon" aria-hidden="true">A</span>
            <input
              className="lyric-color__size-slider"
              type="range"
              min={LYRIC_SCALE_MIN}
              max={LYRIC_SCALE_MAX}
              step={5}
              value={lyricScale}
              aria-label="歌词字号"
              aria-valuetext={`${lyricScale}%`}
              style={{
                ['--size-percent' as string]:
                  `${((lyricScale - LYRIC_SCALE_MIN) / (LYRIC_SCALE_MAX - LYRIC_SCALE_MIN)) * 100}%`,
              }}
              onChange={(event) => setLyricScale(Number(event.target.value))}
            />
            <span className="lyric-color__size-icon" aria-hidden="true">A</span>
            <button
              className="lyric-color__size-value"
              type="button"
              title={lyricScale === LYRIC_SCALE_DEFAULT ? '当前为默认字号' : '点击恢复默认字号'}
              aria-label={`歌词字号 ${lyricScale}%，点击恢复默认`}
              data-default={lyricScale === LYRIC_SCALE_DEFAULT || undefined}
              onClick={() => setLyricScale(LYRIC_SCALE_DEFAULT)}
            >
              {lyricScale}%
            </button>
          </label>

          {/* 字体那一排：每颗按钮用它自己的字体渲染名字，点哪颗两处歌词都换成那颗字。
              「默认」不写 font-family，回到界面字体。 */}
          <div className="lyric-color__fonts" role="group" aria-label="歌词字体">
            {LYRIC_FONTS.map((font) => {
              const active = lyricFont === font.id;
              return (
                <button
                  key={font.id}
                  className="lyric-color__font"
                  type="button"
                  style={font.stack ? { fontFamily: font.stack } : undefined}
                  aria-label={`歌词字体：${font.name}（${font.hint}）`}
                  aria-pressed={active}
                  title={`${font.name} · ${font.hint}`}
                  data-active={active || undefined}
                  onClick={() => setLyricFont(font.id)}
                >
                  {font.name}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
