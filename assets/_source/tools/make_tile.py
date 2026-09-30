#!/usr/bin/env python3
"""把「一次性生成的地表原图」处理成游戏用瓦片。

用法：
    python3 make_tile.py IN.png OUT.png --size 128 [--seamless] [--variants 3] [--prefix out/name]

做三件事：
  1. 无缝化（--seamless）：把图像按半幅平移后，在接缝附近做加权融合，
     再把接缝带整体按差值校正回原亮度——生成模型给的「无缝」原图往往在
     边缘还有轻微台阶，这一步能把接缝压到看不见。
  2. 缩到 --size（游戏里一格 32px，128 就是 4 倍冗余，够 200% 缩放看）。
  3. 出 --variants 个变体（同图不同平移 + 轻微明暗），给大图拼贴时防止
     「同一块砖重复」被一眼看穿。

输出命名：OUT.png 为变体 1，其余为 OUT_2.png、OUT_3.png ...
"""

from __future__ import annotations

import argparse

import numpy as np
from PIL import Image


def seamless(arr: np.ndarray, band: int = 96) -> np.ndarray:
    """半幅平移 + 接缝带融合：让左右、上下边界连续。"""
    h, w = arr.shape[:2]
    shifted = np.roll(arr, (h // 2, w // 2), axis=(0, 1))

    ramp_x = np.ones(w, dtype=np.float32)
    ramp_x[:band] = np.linspace(0.5, 1.0, band, dtype=np.float32)
    ramp_x[-band:] = np.linspace(1.0, 0.5, band, dtype=np.float32)
    ramp_y = np.ones(h, dtype=np.float32)
    ramp_y[:band] = np.linspace(0.5, 1.0, band, dtype=np.float32)
    ramp_y[-band:] = np.linspace(1.0, 0.5, band, dtype=np.float32)

    weight = ramp_y[:, None] * ramp_x[None, :]
    weight = np.clip(weight, 1e-3, None)[:, :, None]
    out = (arr * weight + shifted * (1.0 - weight)) / 1.0
    # 融合会把整体亮度往中间拉，按两者均值做一个整体校正，避免变暗/变亮。
    out *= (arr.mean() + shifted.mean()) / max(1e-3, 2.0 * out.mean())
    return np.clip(out, 0.0, 255.0)


def flatten(arr: np.ndarray, strength: float, base: int = 16) -> np.ndarray:
    """低频压平：把「大块明暗斑」压掉、只留细颗粒。

    生成模型给的地表图总带着若干厘米级的明暗团块，平铺时这些团块会变成
    「同一块砖反复出现」的破绽。做法是把它除以自己的重度模糊版本（高通），
    再乘回平均色——细节保留，大尺度不均匀被抹平。
    """
    img = Image.fromarray(arr.astype(np.uint8))
    low = img.resize((base, base), Image.BOX).resize(img.size, Image.BICUBIC)
    low_arr = np.asarray(low).astype(np.float32)
    mean = arr.mean(axis=(0, 1), keepdims=True)
    ratio = (arr + 1.0) / (low_arr + 1.0)
    ratio = 1.0 + (ratio - 1.0) * strength
    out = ratio * np.maximum(low_arr * 0.0 + mean, 1.0)
    return np.clip(out, 0.0, 255.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--size", type=int, default=128)
    ap.add_argument("--seamless", action="store_true")
    ap.add_argument("--band", type=int, default=96)
    ap.add_argument("--variants", type=int, default=3)
    ap.add_argument("--flatten", type=float, default=0.0, help="低频压平强度 0~1，0=不处理")
    ap.add_argument("--mix", default="", help="与另一张瓦片混合（例如把掩体瓦片压淡一点）")
    ap.add_argument("--mix-weight", type=float, default=0.4)
    args = ap.parse_args()

    img = Image.open(args.src).convert("RGB")
    if args.seamless:
        img = Image.fromarray(seamless(np.asarray(img).astype(np.float32), args.band).astype(np.uint8))

    base = img.resize((args.size, args.size), Image.LANCZOS)
    data = np.asarray(base).astype(np.float32)
    if args.flatten > 0.0:
        data = flatten(data, args.flatten)
    if args.mix:
        other = np.asarray(
            Image.open(args.mix).convert("RGB").resize((args.size, args.size), Image.LANCZOS)
        ).astype(np.float32)
        data = data * (1.0 - args.mix_weight) + other * args.mix_weight

    outs = [args.dst]
    for i in range(1, args.variants):
        outs.append(args.dst.replace(".png", f"_{i + 1}.png"))

    for i, path in enumerate(outs):
        if i == 0:
            variant = data
        else:
            # 变体：半幅平移打散 + 极轻微明暗，肉眼几乎看不出是同一块
            variant = np.roll(data, (i * args.size // (args.variants), i * args.size // (2 * args.variants)), axis=(0, 1))
            variant = np.clip(variant * (1.0 + 0.02 * i), 0.0, 255.0)
        Image.fromarray(variant.astype(np.uint8)).save(path)
    print(f"{args.src} -> {', '.join(outs)} ({args.size}x{args.size})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
