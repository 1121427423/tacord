#!/usr/bin/env python3
"""把拆出来的图标整理成游戏可直接用的命名资源。

用法：
    python3 pack_icons.py SRCDIR OUTDIR --size 256 --names names.txt

做的事：
  * 每个图标按「最长边缩放到 size 的 88%」贴进正方形画布并居中——
    这样一排图标摆在一起时视觉大小一致（原始拆图里坦克扁、子弹细长）。
  * 多尺寸导出：OUTDIR/<name>.png（默认 256）与 OUTDIR/small/<name>.png（64）。
  * 输出一张 contact sheet 便于肉眼验收。

names.txt：每行 `<文件名前缀><空格><游戏内名字>`，顺序与拆图顺序一致。
"""

from __future__ import annotations

import argparse
import glob
import os

from PIL import Image, ImageDraw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("srcdir")
    ap.add_argument("outdir")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--small", type=int, default=64)
    ap.add_argument("--names", required=True)
    ap.add_argument("--sheet", default="")
    args = ap.parse_args()

    # 行格式：`<拆图文件名> <游戏内名字> [注释]`，注释用 # 起。
    names: dict[str, str] = {}
    ordered: list[str] = []
    with open(args.names, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = line.split()
            key = parts[0]
            value = parts[1] if len(parts) > 1 else parts[0]
            names[key] = value
            ordered.append(value)

    files = sorted(glob.glob(os.path.join(args.srcdir, "*.png")))
    files = [f for f in files if not f.endswith("_index.json")]
    resolved = [names.get(os.path.basename(f)) for f in files]
    if any(r is None for r in resolved):
        missing = [os.path.basename(f) for f, r in zip(files, resolved) if r is None]
        raise SystemExit(f"这些拆图文件没有对应名字：{missing}")

    os.makedirs(os.path.join(args.outdir, "small"), exist_ok=True)
    previews = []
    for path, name in zip(files, resolved):
        img = Image.open(path).convert("RGBA")
        inner = int(args.size * 0.88)
        scale = inner / max(img.size)
        img = img.resize(
            (max(1, round(img.width * scale)), max(1, round(img.height * scale))),
            Image.LANCZOS,
        )
        canvas = Image.new("RGBA", (args.size, args.size), (0, 0, 0, 0))
        canvas.paste(img, ((args.size - img.width) // 2, (args.size - img.height) // 2), img)
        canvas.save(os.path.join(args.outdir, f"{name}.png"))
        canvas.resize((args.small, args.small), Image.LANCZOS).save(
            os.path.join(args.outdir, "small", f"{name}.png")
        )
        previews.append((name, canvas))

    if args.sheet:
        cols, cell = 6, 140
        rows = (len(previews) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell, rows * (cell + 18)), (26, 28, 32))
        draw = ImageDraw.Draw(sheet)
        for i, (name, img) in enumerate(previews):
            thumb = img.resize((cell - 20, cell - 20), Image.LANCZOS)
            x = (i % cols) * cell + 10
            y = (i // cols) * (cell + 18) + 10
            draw.rectangle([x - 2, y - 2, x + cell - 22, y + cell - 22], outline=(70, 72, 80))
            sheet.paste(thumb, (x, y), thumb)
            draw.text((x, y + cell - 20), name, fill=(226, 226, 226))
        sheet.save(args.sheet)
        print(f"contact sheet -> {args.sheet}")

    print(f"{len(previews)} icons -> {args.outdir} (+ small/)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
