#!/usr/bin/env python3
"""把 _source/derived 里的原始拆分图，出成可直接进游戏的素材包。

规则：
  * 尺度锚点：游戏里 1 格 = 32 px（battle_map.cell_size）。每张图给一个
    「目标长边」，缩放到该尺寸后，贴图里的 1 px 就等于游戏世界的 1 px。
  * 中性色：素材本身不带阵营色，阵营用 Sprite2D.modulate 叠色（蓝方/红方）。
  * 同时留一份高分辨率原图在 _hd/ 下，供做图标、商店页、宣传图时另取。

用法：python3 promote_assets.py            # 在仓库根目录跑
"""

from __future__ import annotations

import json
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SRC = os.path.join(ROOT, "assets", "_source", "derived")
DST = os.path.join(ROOT, "assets")

# (源文件, 目标路径, 目标长边 px, 中文说明)
ASSETS: list[tuple[str, str, int, str]] = [
    # ---- 单位 ----
    ("units_v1/units_v1_01.png", "units/soldier.png", 24, "步兵（冬装步枪兵）"),
    ("units_v1/units_v1_02.png", "units/medic.png", 24, "医疗兵（白盔红十字）"),
    ("units_v1/units_v1_03.png", "units/mg_gunner.png", 30, "机枪手（趴射，备用）"),
    ("units_v1/units_v1_04.png", "units/tank.png", 42, "装甲车 M10"),
    ("units_v1/units_v1_05.png", "units/drone.png", 26, "侦察无人机 M11"),
    ("units_v1/units_v1_06.png", "units/fpv_drone.png", 26, "FPV 自杀无人机 M13"),
    ("units_v1/units_v1_07.png", "units/grenade.png", 16, "手榴弹 M12"),
    ("units_v1/units_v1_08.png", "units/truck.png", 44, "补给卡车 M15"),
    ("units_v1/units_v1_09.png", "units/tank_wreck.png", 42, "坦克残骸（击毁态）"),
    # ---- 场景道具 ----
    ("props_v1/props_v1_01.png", "props/sandbag_wall.png", 44, "沙袋掩体（cover 地形）"),
    ("props_v1/props_v1_02.png", "props/crate_stack.png", 36, "木箱堆"),
    ("props_v1/props_v1_03.png", "props/ruined_wall.png", 48, "断墙"),
    ("props_v1/props_v1_04.png", "props/fob.png", 40, "前进作战基地（建成态）"),
    ("props_v1/props_v1_05.png", "props/medic_tent.png", 40, "医疗帐篷（建成态）"),
    ("props_v1/props_v1_06.png", "props/build_site.png", 40, "工地（施工中）"),
    ("props_v1/props_v1_07.png", "props/truck_wreck.png", 44, "卡车残骸（断供）"),
    ("props_v1/props_v1_08.png", "props/crater.png", 48, "弹坑（装饰）"),
    ("props_v1/props_v1_09.png", "props/barbed_wire.png", 48, "铁丝网与拒马（装饰）"),
]


def fit(img: Image.Image, long_side: int) -> Image.Image:
    scale = long_side / max(img.size)
    size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
    return img.resize(size, Image.LANCZOS)


def main() -> None:
    manifest = []
    for src_rel, dst_rel, long_side, note in ASSETS:
        src = os.path.join(SRC, src_rel)
        img = Image.open(src).convert("RGBA")
        out = os.path.join(DST, dst_rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        fit(img, long_side).save(out)
        hd = os.path.join(os.path.dirname(out), "_hd", os.path.basename(out))
        os.makedirs(os.path.dirname(hd), exist_ok=True)
        img.save(hd)
        manifest.append(
            {
                "file": dst_rel,
                "note": note,
                "game_size": list(Image.open(out).size),
                "hd_size": list(img.size),
            }
        )
        print(f"{dst_rel:34s} {Image.open(out).size}  (hd {img.size})  {note}")

    with open(os.path.join(DST, "_source", "derived", "pack_manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
