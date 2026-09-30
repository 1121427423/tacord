#!/usr/bin/env python3
"""给主视觉图排版字标（不靠生成模型写字，避免乱码字母）。

用法：
    python3 make_keyart.py IN.png OUTDIR [--font-latin ...] [--font-cjk ...]

排版：
  * 左侧压一层从左到右渐隐的暗角，保证白字在雪地上也压得住；
  * 主标题 TACORD：拉丁字体加宽字距；
  * 细分隔线 + 中文副标 + 一行拉丁小字（游戏定位）。
输出 OUTDIR/keyart_1920.png（商店/宣传）与 OUTDIR/keyart_1280.png（README）
以及一张不放字的 OUTDIR/keyart_clean.png（给后续自己排版用）。
"""

from __future__ import annotations

import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

LATIN = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
CJK = "/usr/local/lib/python3.11/dist-packages/mplfonts/fonts/NotoSansCJKsc-Regular.otf"

TITLE = "TACORD"
SUBTITLE_CN = "指挥官只下达命令，士兵自己判断战场"
SUBTITLE_EN = "2D TOP-DOWN TACTICAL RTS  ·  GODOT 4"


def tracked(draw: ImageDraw.ImageDraw, xy, text, font, fill, tracking: int):
    """逐字画，做出加宽字距的效果；返回结束位置。"""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + tracking
    return x


def gradient(w: int, h: int, strength: float) -> Image.Image:
    """左暗右亮的横向渐变，叠加时用。"""
    ramp = np.linspace(1.0, 0.0, w, dtype=np.float32) ** 0.8
    alpha = (ramp * strength * 255.0).astype(np.uint8)
    col = np.zeros((h, w, 4), dtype=np.uint8)
    col[:, :, 0:3] = np.array([7, 10, 14], dtype=np.uint8)
    col[:, :, 3] = alpha[None, :]
    return Image.fromarray(col, mode="RGBA")


def compose(src: Image.Image, latin: str, cjk: str) -> Image.Image:
    w, h = src.size
    base = src.convert("RGBA")
    base.alpha_composite(gradient(w, h, 0.78))

    draw = ImageDraw.Draw(base)
    scale = h / 768.0
    f_title = ImageFont.truetype(latin, int(96 * scale))
    f_cn = ImageFont.truetype(cjk, int(30 * scale))
    f_en = ImageFont.truetype(latin, int(15 * scale))

    x0 = int(72 * scale)
    y = int(h - 250 * scale)

    tracked(draw, (x0, y), TITLE, f_title, (240, 240, 236, 255), int(9 * scale))
    y += int(120 * scale)

    draw.line([(x0, y), (x0 + int(430 * scale), y)], fill=(214, 176, 96, 210), width=max(2, int(2 * scale)))
    y += int(22 * scale)

    draw.text((x0, y), SUBTITLE_CN, font=f_cn, fill=(238, 238, 240, 255), stroke_width=1,
              stroke_fill=(10, 12, 16, 160))
    y += int(50 * scale)
    draw.text((x0, y), SUBTITLE_EN, font=f_en, fill=(206, 208, 212, 235))
    return base.convert("RGB")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("outdir")
    ap.add_argument("--font-latin", default=LATIN)
    ap.add_argument("--font-cjk", default=CJK)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    src = Image.open(args.src).convert("RGB")
    art1920 = src.resize((1920, round(1920 * src.height / src.width)), Image.LANCZOS)
    art = compose(art1920, args.font_latin, args.font_cjk)
    art.save(os.path.join(args.outdir, "keyart_1920.png"))
    art.resize((1280, round(1280 * art.height / art.width)), Image.LANCZOS).save(
        os.path.join(args.outdir, "keyart_1280.png")
    )
    src.resize((1280, round(1280 * src.height / src.width)), Image.LANCZOS).save(
        os.path.join(args.outdir, "keyart_clean_1280.png")
    )
    src.save(os.path.join(args.outdir, "keyart_clean_1920.png"))
    print("keyart -> keyart_1920.png / keyart_1280.png / keyart_clean_*.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
