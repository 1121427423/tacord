#!/usr/bin/env python3
"""生成两张验收图：
  1. derived/pack_scale_check.png —— 单位/道具在「游戏 1:1 尺度」下叠在地形上的样子
     （整幅放大 4 倍显示，方便肉眼判断 24~48 px 是不是还认得出来）。
  2. derived/pack_overview.png —— 素材包总览（高清缩略 + 文件名 + 用途）。
"""

from __future__ import annotations

import glob
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ASSETS = os.path.join(ROOT, "assets")
OUT = os.path.join(ASSETS, "_source", "derived")

UNITS_SCALE_ROW = [
    ("units/soldier.png", "soldier"),
    ("units/medic.png", "medic"),
    ("units/mg_gunner.png", "mg_gunner"),
    ("units/grenade.png", "grenade"),
    ("units/drone.png", "drone"),
    ("units/fpv_drone.png", "fpv_drone"),
    ("units/tank.png", "tank"),
    ("units/truck.png", "truck"),
    ("units/tank_wreck.png", "tank_wreck"),
]

PROPS_SCALE_ROW = [
    ("props/sandbag_wall.png", "sandbag_wall"),
    ("props/crate_stack.png", "crate_stack"),
    ("props/ruined_wall.png", "ruined_wall"),
    ("props/fob.png", "fob"),
    ("props/medic_tent.png", "medic_tent"),
    ("props/build_site.png", "build_site"),
    ("props/truck_wreck.png", "truck_wreck"),
    ("props/crater.png", "crater"),
    ("props/barbed_wire.png", "barbed_wire"),
]


def tiled(tile_path: str, w: int, h: int) -> Image.Image:
    tile = Image.open(tile_path).convert("RGBA")
    out = Image.new("RGBA", (w, h))
    for y in range(0, h, tile.height):
        for x in range(0, w, tile.width):
            out.paste(tile, (x, y))
    return out


def scale_check(theme: str, ground: str, rows: list[tuple[str, str]], path: str) -> None:
    zoom = 4
    cell = 32 * zoom  # 一格 = 32 px，放大 4 倍
    pad = 24
    width = cell * 9 + pad * 2
    height = pad * 2 + (cell + 26) * 2 + 60
    canvas = tiled(os.path.join(ASSETS, ground), width, height).convert("RGB")
    canvas = Image.blend(canvas, Image.new("RGB", canvas.size, (10, 12, 16)), 0.25)
    draw = ImageDraw.Draw(canvas)

    y = pad + 46
    for label, items in (("UNITS (game scale 1:1, shown at 4x)", rows[0]), ("PROPS (game scale 1:1, shown at 4x)", rows[1])):
        draw.text((pad, y - 34), f"{label}   theme={theme}   cell=32px @ {zoom}x", fill=(255, 232, 150))
        x = pad + (cell - 32) // 2
        for rel, name in items:
            img = Image.open(os.path.join(ASSETS, rel)).convert("RGBA")
            big = img.resize((img.width * zoom, img.height * zoom), Image.LANCZOS)
            canvas.paste(big, (x + (64 - big.width) // 2, y + (cell - big.height) // 2), big)
            draw.text((x + 2, y + cell + 4), name, fill=(236, 236, 240))
            x += cell
        y += cell + 58

    canvas.save(path)
    print("wrote", path, canvas.size)


def overview(path: str) -> None:
    groups = [
        ("units", sorted(glob.glob(os.path.join(ASSETS, "units", "*.png")))),
        ("props", sorted(glob.glob(os.path.join(ASSETS, "props", "*.png")))),
        ("terrain", sorted(glob.glob(os.path.join(ASSETS, "terrain", "*.png")))[:4]),
        ("ui/icons", sorted(glob.glob(os.path.join(ASSETS, "ui", "icons", "*.png")))),
    ]
    cell = 132
    cols = 12
    row_h = cell + 20
    total_rows = sum((len(items) + cols - 1) // cols + 1 for _, items in groups)
    canvas = Image.new("RGB", (cols * cell, total_rows * row_h + 16), (22, 24, 28))
    draw = ImageDraw.Draw(canvas)
    y = 8
    for name, items in groups:
        draw.text((8, y + 2), f"--- {name} ({len(items)} files) ---", fill=(255, 210, 120))
        y += 20
        for i, f in enumerate(items):
            img = Image.open(f).convert("RGBA")
            s = min(cell - 20, max(img.size))
            small = img.resize(
                (max(1, round(img.width * s / max(img.size))), max(1, round(img.height * s / max(img.size)))),
                Image.LANCZOS,
            )
            x = (i % cols) * cell
            for yy in range(y, y + cell - 16, 12):
                for xx in range(x, x + cell - 4, 12):
                    c = (58, 58, 64) if ((xx // 12 + yy // 12) % 2 == 0) else (44, 44, 50)
                    draw.rectangle([xx, yy, xx + 11, yy + 11], fill=c)
            canvas.paste(small, (x + (cell - 4 - small.width) // 2, y + (cell - 16 - small.height) // 2), small)
            label = os.path.splitext(os.path.basename(f))[0]
            draw.text((x + 3, y + cell - 16), label, fill=(226, 226, 232))
            if i % cols == cols - 1:
                y += row_h
        y += row_h
    canvas.save(path)
    print("wrote", path, canvas.size)


if __name__ == "__main__":
    scale_check(
        "snow",
        "terrain/snow_ground.png",
        [UNITS_SCALE_ROW, PROPS_SCALE_ROW],
        os.path.join(OUT, "pack_scale_snow.png"),
    )
    scale_check(
        "desert",
        "terrain/desert_ground.png",
        [UNITS_SCALE_ROW, PROPS_SCALE_ROW],
        os.path.join(OUT, "pack_scale_desert.png"),
    )
    overview(os.path.join(OUT, "pack_overview.png"))
