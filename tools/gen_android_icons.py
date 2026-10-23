# -*- coding: utf-8 -*-
"""从 harmonyos/icons/icon.png 生成安卓 mipmap 各密度图标 + 自适应图标背景"""
from PIL import Image, ImageDraw
import os

SRC = "harmonyos/icons/icon.png"
RES = "android/app/src/main/res"

src = Image.open(SRC).convert("RGBA")

def full_bleed(size):
    """圆角透明角填黑，得到全出血方形图（自适应图标 background 用）"""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    im.alpha_composite(src.resize((size, size), Image.LANCZOS))
    return im

def circle_crop(size):
    """圆形裁切（roundIcon 用）"""
    im = full_bleed(size)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out

# 1) 各密度静态图标（launcher=圆角原图, round=圆形裁切）
densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
for dpi, size in densities.items():
    d = os.path.join(RES, f"mipmap-{dpi}")
    os.makedirs(d, exist_ok=True)
    src.resize((size, size), Image.LANCZOS).save(os.path.join(d, "ic_launcher.png"))
    circle_crop(size).save(os.path.join(d, "ic_launcher_round.png"))
    print(f"mipmap-{dpi}: {size}x{size} ok")

# 2) 自适应图标背景：108dp @xxxhdpi = 432px，全出血
d = os.path.join(RES, "mipmap-xxxhdpi")
full_bleed(432).save(os.path.join(d, "ic_launcher_background.png"))
print("adaptive background 432x432 ok")
