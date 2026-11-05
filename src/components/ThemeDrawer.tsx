/**
 * ThemeDrawer.tsx —— 换肤抽屉
 *
 * 菜单里点「换肤」后弹出的二级抽屉。外观分成两个独立维度：
 * · 明暗模式：系统 / 浅色 / 深色
 * · 主题色：薄荷 / 粉色 / 蓝色
 * 选中即时生效，抽屉不关，可以来回比对。
 */

import { Drawer } from './Drawer';
import { COLOR_OPTIONS, MODE_OPTIONS, useTheme } from '../state/theme';

export function ThemeDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { mode, color, resolvedMode, setMode, setColor } = useTheme();

  return (
    <Drawer open={open} onClose={onClose} title="换肤" hint="明暗和主题色分开设置，选择会记住">
      <section className="theme-group" aria-label="明暗模式">
        <p className="theme-group__title">明暗模式</p>
        <div className="theme-seg" role="group" aria-label="明暗模式">
          {MODE_OPTIONS.map((option) => (
            <button
              key={option.id}
              className="theme-seg__item"
              type="button"
              aria-pressed={mode === option.id}
              title={option.hint}
              onClick={() => setMode(option.id)}
            >
              {option.name}
            </button>
          ))}
        </div>
        {mode === 'system' && (
          <p className="theme-group__hint" role="status">当前跟随系统：{resolvedMode === 'dark' ? '深色' : '浅色'}</p>
        )}
      </section>

      <section className="theme-group" aria-label="主题色">
        <p className="theme-group__title">主题色</p>
        <div className="theme-swatches" role="group" aria-label="主题色">
          {COLOR_OPTIONS.map((option) => (
            <button
              key={option.id}
              className={`theme-swatch theme-swatch--${option.id}`}
              type="button"
              aria-pressed={color === option.id}
              title={option.hint}
              onClick={() => setColor(option.id)}
            >
              <span className="theme-swatch__dot" aria-hidden="true" />
              <span>{option.name}</span>
            </button>
          ))}
        </div>
      </section>
    </Drawer>
  );
}
