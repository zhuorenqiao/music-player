/**
 * LibraryMenu.tsx —— 右上角的「更多」按钮 + 从右侧滑出的抽屉
 *
 * 抽屉里只放一级入口：添加音乐 / 清空播放列表 / 换肤。
 * 换肤再点一下才弹出二级抽屉（ThemeDrawer），主题选项不混在一级菜单里。
 */

import { useState } from 'react';
import { Drawer } from './Drawer';
import { ThemeDrawer } from './ThemeDrawer';

const MoreIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="currentColor" aria-hidden="true">
    <circle cx="12" cy="5.5" r="1.7" />
    <circle cx="12" cy="12" r="1.7" />
    <circle cx="12" cy="18.5" r="1.7" />
  </svg>
);

const PlusIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden="true">
    <path d="M12 5v14M5 12h14" />
  </svg>
);

const TrashIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13" />
  </svg>
);

const PaletteIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M12 3a9 9 0 1 0 0 18h1.3a1.9 1.9 0 0 0 1.5-3.1 1.9 1.9 0 0 1 1.5-3.1h1.4A3.3 3.3 0 0 0 21 11.5C21 6.8 17 3 12 3Z" />
    <circle cx="7.6" cy="11.4" r="1.05" fill="currentColor" stroke="none" />
    <circle cx="10.4" cy="7.6" r="1.05" fill="currentColor" stroke="none" />
    <circle cx="15" cy="8" r="1.05" fill="currentColor" stroke="none" />
  </svg>
);

export function LibraryMenu({ onAdd, onClear }: {
  /** 打开本地文件选择（音频 / .lrc） */
  onAdd: () => void;
  /** 清空播放列表（内部还有一次确认） */
  onClear: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [themeOpen, setThemeOpen] = useState(false);

  return (
    <>
      <button
        className="btn app__menu"
        type="button"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label="更多"
        title="更多"
        onClick={() => setOpen(true)}
      >
        <MoreIcon />
        <span className="btn__text">更多</span>
      </button>

      <Drawer open={open} onClose={() => setOpen(false)} title="更多" width="narrow">
        <div className="menu-list">
          <button
            className="menu-row"
            type="button"
            onClick={() => {
              setOpen(false);
              onAdd();
            }}
          >
            <span className="menu-row__icon" aria-hidden="true"><PlusIcon /></span>
            <span className="menu-row__title">添加音乐</span>
          </button>

          <button
            className="menu-row menu-row--danger"
            type="button"
            onClick={() => {
              setOpen(false);
              onClear();
            }}
          >
            <span className="menu-row__icon" aria-hidden="true"><TrashIcon /></span>
            <span className="menu-row__title">清空播放列表</span>
          </button>

          {/* 二级入口：再点一下才弹换肤抽屉，一级菜单里不混主题选项 */}
          <button
            className="menu-row menu-row--sub"
            type="button"
            aria-haspopup="dialog"
            onClick={() => setThemeOpen(true)}
          >
            <span className="menu-row__icon" aria-hidden="true"><PaletteIcon /></span>
            <span className="menu-row__title">换肤</span>
          </button>
        </div>
      </Drawer>

      <ThemeDrawer open={themeOpen} onClose={() => setThemeOpen(false)} />
    </>
  );
}
