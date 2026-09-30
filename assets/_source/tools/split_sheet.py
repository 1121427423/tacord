#!/usr/bin/env python3
"""把 AI 生成的「洋红底素材表」拆成带 alpha 的独立 PNG。

用法：
    python3 split_sheet.py SHEET.png OUTDIR [--grid 3x3] [--prefix name]
                        [--min-area 1500] [--merge-gap 10] [--pad 2]

两种切分模式：
  * 默认自动模式：按连通域找 sprite，再把彼此靠得很近的块合并成一个 sprite。
  * --grid RxC：先按等分格子切开，每格内部再去洋红底 + 自动裁边。
    模型排版很整齐时这个模式更稳（不会把两个挨着的 sprite 粘成一个）。

去底：用四条边框像素的中位数估背景色，按色彩距离算 alpha，再做反预乘
（pixel = fg*a + bg*(1-a)）把边缘的粉边解掉，避免缩小时出现洋红描边。

输出：OUTDIR/name_01.png ... 以及 OUTDIR/name_index.json（顺序为「先上后下、先左后右」）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import deque

import numpy as np
from PIL import Image


def _bg_color(arr: np.ndarray) -> np.ndarray:
    """用四条边框像素的中位数估计背景色（比写死 #FF00FF 更稳）。"""
    h, w, _ = arr.shape
    border = np.concatenate(
        [
            arr[0:3].reshape(-1, 3),
            arr[-3:].reshape(-1, 3),
            arr[:, 0:3].reshape(-1, 3),
            arr[:, -3:].reshape(-1, 3),
        ]
    )
    return np.median(border, axis=0)


def despill(rgb: np.ndarray) -> np.ndarray:
    """去洋红溢色：半透明像素（旋翼、烟尘、弹坑边）总带着背景的品红，
    按「品红程度」把它往该像素的灰度拉回去，缩放后就不会出现粉边。"""
    r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    mag = np.clip(((r + b) * 0.5 - g) / 96.0, 0.0, 1.0)
    lum = (0.299 * r + 0.587 * g + 0.114 * b)[:, :, None]
    return rgb * (1.0 - mag * 0.9)[:, :, None] + lum * (mag * 0.9)[:, :, None]


def cutout(arr: np.ndarray, t0: float = 40.0, t1: float = 105.0) -> np.ndarray:
    """返回 RGBA float 图：背景 -> alpha 0，边缘反预乘 + 去溢色。"""
    bg = _bg_color(arr)
    dist = np.linalg.norm(arr - bg, axis=2)
    alpha = np.clip((dist - t0) / (t1 - t0), 0.0, 1.0)
    a = np.maximum(alpha, 1e-4)[:, :, None]
    fg = (arr - bg * (1.0 - alpha)[:, :, None]) / a
    fg = despill(np.clip(fg, 0.0, 255.0))
    out = np.dstack([fg, alpha * 255.0])
    out[alpha <= 0.02] = 0.0
    return out


def label_components(mask: np.ndarray) -> tuple[np.ndarray, int]:
    """4 邻域连通域标记（不依赖 scipy）。"""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    current = 0
    for y in range(h):
        row = mask[y]
        for x in range(w):
            if not row[x] or labels[y, x]:
                continue
            current += 1
            q = deque([(y, x)])
            labels[y, x] = current
            while q:
                cy, cx = q.popleft()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not labels[ny, nx]:
                        labels[ny, nx] = current
                        q.append((ny, nx))
    return labels, current


def merge_boxes(boxes: list[list[int]], gap: int) -> list[list[int]]:
    """把间距小于 gap 的包围盒合并（旋翼、枪管这类分离零件会重新长回一起）。"""
    changed = True
    while changed:
        changed = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                ax0, ay0, ax1, ay1 = boxes[i]
                bx0, by0, bx1, by1 = boxes[j]
                if (
                    ax0 - gap <= bx1
                    and bx0 - gap <= ax1
                    and ay0 - gap <= by1
                    and by0 - gap <= ay1
                ):
                    boxes[i] = [min(ax0, bx0), min(ay0, by0), max(ax1, bx1), max(ay1, by1)]
                    boxes.pop(j)
                    changed = True
                    break
            if changed:
                break
    return boxes


def sort_boxes(boxes: list[list[int]], rows: int) -> list[list[int]]:
    """先按行分带、再按列排序：保证输出顺序是「先上后下、先左后右」。"""
    if rows > 1 and len(boxes) > rows:
        boxes = sorted(boxes, key=lambda b: (b[1] + b[3]) / 2)
        per_row = max(1, len(boxes) // rows)
        bands = [boxes[i : i + per_row] for i in range(0, len(boxes), per_row)]
        ordered: list[list[int]] = []
        for band in bands:
            ordered.extend(sorted(band, key=lambda b: (b[0] + b[2]) / 2))
        return ordered
    return sorted(boxes, key=lambda b: (b[0] + b[2]) / 2)


def slice_cells(rgba: np.ndarray, rows: int, cols: int) -> list[np.ndarray]:
    h, w, _ = rgba.shape
    out = []
    for r in range(rows):
        for c in range(cols):
            y0, y1 = round(r * h / rows), round((r + 1) * h / rows)
            x0, x1 = round(c * w / cols), round((c + 1) * w / cols)
            out.append(rgba[y0:y1, x0:x1])
    return out


def trim(rgba: np.ndarray, pad: int = 2) -> np.ndarray | None:
    mask = rgba[:, :, 3] > 8
    if not mask.any():
        return None
    ys, xs = np.where(mask)
    y0, y1 = max(0, ys.min() - pad), min(rgba.shape[0], ys.max() + 1 + pad)
    x0, x1 = max(0, xs.min() - pad), min(rgba.shape[1], xs.max() + 1 + pad)
    return rgba[y0:y1, x0:x1]


def grid_group(rgba: np.ndarray, rows: int, cols: int, min_area: int) -> list[np.ndarray]:
    """按 3x3 之类的排版网格归属 sprite：先找连通域，再按质心扔进对应格子，
    每格把命中的块求并集后裁边。比「整格切」稳（不会把跨格的枪管切掉），
    也比「按行分带排序」稳（包围盒高矮不一时不会串行）。"""
    h, w, _ = rgba.shape
    labels, count = label_components(rgba[:, :, 3] > 40)
    cell_boxes: dict[tuple[int, int], list[int]] = {}
    for idx in range(1, count + 1):
        ys, xs = np.where(labels == idx)
        if len(ys) < min_area:
            continue
        cy, cx = ys.mean() / h, xs.mean() / w
        key = (min(rows - 1, int(cy * rows)), min(cols - 1, int(cx * cols)))
        box = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
        if key in cell_boxes:
            cur = cell_boxes[key]
            box = [
                min(cur[0], box[0]),
                min(cur[1], box[1]),
                max(cur[2], box[2]),
                max(cur[3], box[3]),
            ]
        cell_boxes[key] = box

    pieces: list[np.ndarray] = []
    for r in range(rows):
        for c in range(cols):
            box = cell_boxes.get((r, c))
            if box is None:
                continue
            x0, y0, x1, y1 = box
            pieces.append(rgba[y0 : y1 + 1, x0 : x1 + 1])
    return pieces


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet")
    ap.add_argument("outdir")
    ap.add_argument("--cells", default="", help="RxC，按排版网格归属，例如 3x3")
    ap.add_argument("--prefix", default="")
    ap.add_argument("--min-area", type=int, default=1500)
    ap.add_argument("--merge-gap", type=int, default=10)
    ap.add_argument("--pad", type=int, default=2)
    args = ap.parse_args()

    prefix = args.prefix or os.path.splitext(os.path.basename(args.sheet))[0]
    img = Image.open(args.sheet).convert("RGB")
    rgba = cutout(np.asarray(img).astype(np.float32))
    os.makedirs(args.outdir, exist_ok=True)

    if args.cells:
        rows, cols = (int(v) for v in args.cells.split("x"))
        pieces = grid_group(rgba, rows, cols, args.min_area)
    else:
        labels, count = label_components(rgba[:, :, 3] > 40)
        boxes = []
        for idx in range(1, count + 1):
            ys, xs = np.where(labels == idx)
            if len(ys) < args.min_area:
                continue
            boxes.append([int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())])
        boxes = merge_boxes(boxes, args.merge_gap)
        boxes.sort(key=lambda b: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2))
        pieces = [
            rgba[
                max(0, y0 - args.pad) : y1 + 1 + args.pad,
                max(0, x0 - args.pad) : x1 + 1 + args.pad,
            ]
            for x0, y0, x1, y1 in boxes
        ]

    index = []
    for i, piece in enumerate(pieces, start=1):
        name = f"{prefix}_{i:02d}.png"
        Image.fromarray(piece.astype(np.uint8), mode="RGBA").save(
            os.path.join(args.outdir, name)
        )
        index.append({"file": name, "w": int(piece.shape[1]), "h": int(piece.shape[0])})

    with open(os.path.join(args.outdir, f"{prefix}_index.json"), "w") as fh:
        json.dump(index, fh, indent=1, ensure_ascii=False)
    print(f"{prefix}: {len(pieces)} sprites -> {args.outdir}")
    for item in index:
        print(f"   {item['file']}  {item['w']}x{item['h']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
