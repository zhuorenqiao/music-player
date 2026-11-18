"""make_app_icons.py —— 从左上角 logo 的 1024px 母版切出各平台图标。

母版由 Flutter 自己渲染（`tool/brand/render_brand_master_test.dart` +
`--update-goldens`），所以与界面里 `ui/header.dart` 的 `_Brand` **逐像素同源**：
深色底 + 13/40 圆角 + 1px accentLine 描边 + accentSoft→cardB 渐变 + 18/40 的
`graphic_eq` 图标。

产出：
  android/app/src/main/res/mipmap-*/ic_launcher.png              旧版（API<26）整块 logo
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png   自适应前景（只有图标条）
  android/app/src/main/res/mipmap-*/ic_launcher_monochrome.png   主题化图标（单色）
  android/app/src/main/res/drawable/ic_launcher_background.xml   自适应背景渐变
  android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml     自适应图标声明
  windows/runner/resources/app_icon.ico                          桌面快捷方式 / 任务栏图标

用法（在 flutter-app 目录）：python tool/make_app_icons.py
"""
from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
MASTER_TILE = os.path.join(ROOT, "tool", "brand", "app_icon_master.png")
MASTER_GLYPH = os.path.join(ROOT, "tool", "brand", "app_icon_glyph.png")
ICO_PATH = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")

# logo 的圆角是 13/40，等比放大即是 32.5%。
CORNER_RATIO = 13.0 / 40.0

# 旧版图标（API < 26）：48dp 起每档 +1/2。
LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# 自适应图标：前景是 108dp 画布，内容须落在中间 66dp 安全区内。
ADAPTIVE = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# 图标条在自适应画布里的高度占比：0.48 × 108 ≈ 52dp，落在 66dp 安全区内。
GLYPH_RATIO = 0.48


def rounded_tile(master: Image.Image, size: int) -> Image.Image:
    """整块 logo：等比缩放 + 圆角蒙版（4× 超采样消除锯齿）。"""
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(round(CORNER_RATIO * size * scale))
    draw.rounded_rectangle(
        [0, 0, size * scale - 1, size * scale - 1], radius=radius, fill=255
    )
    mask = mask.resize((size, size), Image.LANCZOS)
    out = master.resize((size, size), Image.LANCZOS).convert("RGBA")
    out.putalpha(mask)
    return out


def glyph_layer(glyph: Image.Image, size: int, color: tuple[int, int, int] | None) -> Image.Image:
    """自适应前景：只留图标条，居中、透明底。color=None 时保留薄荷原色。"""
    bbox = glyph.getbbox()
    if bbox is None:
        raise SystemExit("glyph master 是空的")
    bars = glyph.crop(bbox)
    if color is not None:
        alpha = bars.getchannel("A")
        solid = Image.new("RGBA", bars.size, color + (255,))
        solid.putalpha(alpha)
        bars = solid
    target = size * GLYPH_RATIO
    ratio = target / bars.height
    scaled = bars.resize(
        (max(1, round(bars.width * ratio)), max(1, round(bars.height * ratio)),
        ), Image.LANCZOS
    )
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2), scaled)
    return canvas


def hex_color(pixel: tuple[int, int, int, int]) -> str:
    return "#{:02X}{:02X}{:02X}".format(*pixel[:3])


def main() -> int:
    if not (os.path.exists(MASTER_TILE) and os.path.exists(MASTER_GLYPH)):
        print("缺少母版：先跑 flutter test --update-goldens tool/brand/render_brand_master_test.dart",
              file=sys.stderr)
        return 1

    tile_master = Image.open(MASTER_TILE).convert("RGBA")
    glyph_master = Image.open(MASTER_GLYPH).convert("RGBA")

    # 渐变两端从母版取样：取圆角块内部的左上 / 右下两点（避开描边与图标条）。
    tl = hex_color(tile_master.getpixel((160, 160)))
    br = hex_color(tile_master.getpixel((864, 864)))
    print(f"渐变端点：{tl} → {br}")

    for folder, size in LEGACY.items():
        out_dir = os.path.join(RES, folder)
        os.makedirs(out_dir, exist_ok=True)
        rounded_tile(tile_master, size).save(os.path.join(out_dir, "ic_launcher.png"))
        print(f"legacy  {folder}/ic_launcher.png ({size}px)")

    for folder, size in ADAPTIVE.items():
        out_dir = os.path.join(RES, folder)
        os.makedirs(out_dir, exist_ok=True)
        glyph_layer(glyph_master, size, None).save(
            os.path.join(out_dir, "ic_launcher_foreground.png")
        )
        glyph_layer(glyph_master, size, (255, 255, 255)).save(
            os.path.join(out_dir, "ic_launcher_monochrome.png")
        )
        print(f"adaptive {folder}/ic_launcher_foreground.png ({size}px)")

    drawable_dir = os.path.join(RES, "drawable")
    os.makedirs(drawable_dir, exist_ok=True)
    background_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- 自适应图标底色：取 ui/header.dart 那颗 logo 圆角块的渐变两端\n"
        "     （深色薄荷底 + accentSoft→cardB），由 tool/make_app_icons.py 生成。 -->\n"
        '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:shape="rectangle">\n'
        f'    <gradient android:type="linear" android:angle="315"\n'
        f"        android:startColor=\"{tl}\" android:endColor=\"{br}\" />\n"
        "</shape>\n"
    )
    with open(os.path.join(drawable_dir, "ic_launcher_background.xml"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(background_xml)

    anydpi_dir = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi_dir, exist_ok=True)
    adaptive_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        '    <background android:drawable="@drawable/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
        "</adaptive-icon>\n"
    )
    with open(os.path.join(anydpi_dir, "ic_launcher.xml"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(adaptive_xml)

    ico_dir = os.path.dirname(ICO_PATH)
    os.makedirs(ico_dir, exist_ok=True)
    rounded_tile(tile_master, 256).save(
        ICO_PATH,
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"windows app_icon.ico")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
