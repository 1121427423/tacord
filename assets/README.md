# TACORD 美术素材包

从 `assets/Defilade_Steam_Trailer_720p_part1|2.mp4`（蒸汽页预告片）里提取的**画风锚点**，
据此生成的 2D 俯视角素材。当前**只产出素材，尚未接线**——游戏里跑的仍是
`ColorRect` + `_draw()` 占位渲染，接入方案见文末「接线映射」。

---

## 一、目录

```
assets/
├── terrain/                       # 无缝地表瓦片（各 3 个变体）
│   ├── desert_ground{,_2,_3}.png  # 沙漠空地  128×128
│   ├── desert_rubble{,_2,_3}.png  # 沙漠掩体  128×128
│   ├── snow_ground{,_2,_3}.png    # 雪地空地  128×128
│   └── snow_churned{,_2,_3}.png   # 雪地掩体  128×128
├── units/                         # 单位（中性色，靠 modulate 上阵营色）
│   └── _hd/                       # 同名的 4~8 倍原图，做图标/宣传图时用
├── props/                         # 场景道具（同上）
│   └── _hd/
├── ui/
│   ├── icons/                     # 16 枚 256×256 UI 图标
│   │   └── small/                 # 同款 64×64（HUD 行内用）
│   ├── keyart_1920.png            # 主视觉图（带字标，1920×1072）
│   ├── keyart_1280.png            # 主视觉图（带字标，README 用）
│   ├── keyart_clean_1920.png      # 无字标版（自己排版用）
│   └── keyart_clean_1280.png
└── _source/                       # 素材的来源与流水线（可复现）
    ├── refs/                      # 从预告片抽的 6 张参考帧
    ├── sheets/                    # 生成模型出的原始素材表与地表原图
    ├── derived/                   # 拆图中间产物 + 验收图
    └── tools/                     # 三个脚本，见下
```

---

## 二、单位与道具（游戏内 1:1 像素尺寸）

游戏里 **1 格 = 32 px**（`battle_map.cell_size`）。下表的尺寸就是贴图进游戏后的
真实像素尺寸，直接对齐现有的碰撞体与 `_draw()` 占位轮廓。

| 贴图 | 尺寸 | 对应代码 | 说明 |
| --- | --- | --- | --- |
| `units/soldier.png` | 19×24 | `soldier.tscn` 的 `Body`（14×14 方块） | 冬装步枪兵，中立色（灰白大衣） |
| `units/medic.png` | 17×24 | 同上，`is_medic` | 白盔红十字，一眼区分医疗兵 |
| `units/mg_gunner.png` | 14×30 | 暂无 | 趴射机枪手，备用 |
| `units/grenade.png` | 4×16 | `grenade.tscn` `_draw()` | 掷弹筒造型 |
| `units/drone.png` | 26×24 | `drone.tscn` `_draw()` | 侦察无人机 M11 |
| `units/fpv_drone.png` | 26×24 | `fpv_drone.tscn` `_draw()` | FPV 自杀机 M13（机头带战斗部） |
| `units/tank.png` | 19×42 | `tank.tscn`（26×20 车体） | 装甲车 M10，炮管朝上 |
| `units/truck.png` | 19×44 | `truck.tscn` `_draw()` | 补给卡车 M15，车头朝上 |
| `units/tank_wreck.png` | 23×42 | 坦克 `is_dead` 分支 | 烧毁残骸 |
| `props/sandbag_wall.png` | 44×34 | `battle_map.add_obstacle()` 的 `cover` | 沙袋掩体 |
| `props/crate_stack.png` | 36×29 | 同上（木箱） | 三只木箱堆 |
| `props/ruined_wall.png` | 48×26 | `blocked` 地形 | 断墙 |
| `props/fob.png` | 39×40 | `build_site.tscn`（`kind == "fob"`） | 前进作战基地，建成态 |
| `props/medic_tent.png` | 39×40 | 同上（`kind == "tent"`） | 医疗帐篷，建成态 |
| `props/build_site.png` | 40×36 | 同上（未建成） | 工地：木料 + 沙袋 |
| `props/truck_wreck.png` | 44×31 | 卡车 `is_dead` 分支 | 断供残骸 |
| `props/crater.png` | 48×42 | 暂无（装饰） | 弹坑 |
| `props/barbed_wire.png` | 48×47 | 暂无（装饰） | 铁丝网 + 拒马 |

**朝向约定**：所有单位贴图都是**朝上（-Y）**画的。游戏里用 `rotation = facing.angle() + PI/2`
即可与现有的 `facing` 向量对齐。

**阵营色**：素材本身不带阵营色。蓝/红用 `Sprite2D.modulate` 或
`self_modulate` 叠色（现有配色见 `soldier.gd` 的 `TEAM_COLORS`：
蓝 `Color(0.404, 0.635, 1.0)`、红 `Color(1.0, 0.427, 0.345)`）。

---

## 三、地形瓦片

四张地表各自**无缝**（边界能对上），各 3 个变体，拼大图时轮换避免「同一块砖重复」。

| 瓦片 | 对应地形 | 说明 |
| --- | --- | --- |
| `terrain/snow_ground.png` | `open` | 雪地空地 |
| `terrain/snow_churned.png` | `cover`（也不可走） | 被踩烂的雪地 + 冻泥 |
| `terrain/desert_ground.png` | `open` | 沙漠沙地 |
| `terrain/desert_rubble.png` | `cover`（也不可走） | 碎石砾 |

> 现有代码里 `TERRAIN_COLORS` 还区分 `high`（蓝色高台）与 `blocked`（深色）。
> 这两类暂时没有对应瓦片——`high` 是纯逻辑标记（不改视线也不挡路），
> 接线上建议保留纯色叠加，或用 `units/` 里没有用到的道具顶替。

---

## 四、UI 图标

`ui/icons/*.png`（256）与 `ui/icons/small/*.png`（64），命名与游戏概念一一对应：

| 图标 | 用途 | 图标 | 用途 |
| --- | --- | --- | --- |
| `attack` | 进攻命令（键 `1`） | `intel` | 情报行（审讯出的工事） |
| `defend` | 防守命令（`2`） | `suppressed` | 被压制 |
| `flank` | 包抄命令（`3`） | `heal` | 治疗中 |
| `hold` | 待命命令（`4`） | `wounded` | 倒地/失血 |
| `fob` | 前进作战基地（`5`） | `tank` | 装甲行 |
| `sandbag` | 沙袋工事（`6`） | `drone` | 空中行 |
| `medic_tent` | 医疗帐篷（`7`） | `fpv` | FPV 行 |
| `ammo` | 弹药/补给 | `truck` | 补给卡车 |

HUD 目前是纯 `Label` 文本（`main.gd` 的 `_update_hud`），接图标时用
`TextureRect` 或 `Label` 的 `RichTextEffect` 都可以，`small/` 就是给行内 16~20px 准备的。

---

## 五、复现流水线

素材不是手绘的，是从参考帧 + 生成模型出来、再用三个脚本加工的可复现流程：

```bash
# 0) 依赖
pip3 install --system pillow numpy imageio-ffmpeg

cd assets/_source

# 1) 从预告片抽参考帧（画风锚点）
ffmpeg -ss 20 -i ../../assets/Defilade_Steam_Trailer_720p_part1.mp4 -frames:v 1 \
       -vf "crop=720:720:280:0,scale=512:512" refs/ref_desert_units.png

# 2) 生成模型产出 sheets/*.png（洋红底素材表 / 地表原图）后，拆图
python3 tools/split_sheet.py sheets/units_v1.png derived/units_v1 --cells 3x3 --prefix units_v1 --min-area 400
python3 tools/split_sheet.py sheets/props_v1.png derived/props_v1 --cells 3x3 --prefix props_v1 --min-area 400
python3 tools/split_sheet.py sheets/icons_v1.png derived/icons_v1 --cells 4x4 --prefix icons_v1 --min-area 400

# 3) 地表 -> 无缝瓦片（--flatten 压掉大块明暗斑，--mix 压低掩体瓦片对比度）
python3 tools/make_tile.py sheets/terrain_snow_open.png  ../../assets/terrain/snow_ground.png  --size 128 --seamless --variants 3 --flatten 0.85
python3 tools/make_tile.py sheets/terrain_snow_cover.png ../../assets/terrain/snow_churned.png --size 128 --seamless --variants 3 --flatten 0.95 --mix ../../assets/terrain/snow_ground.png --mix-weight 0.72
python3 tools/make_tile.py sheets/terrain_desert_open.png  ../../assets/terrain/desert_ground.png  --size 128 --seamless --variants 3 --flatten 0.85
python3 tools/make_tile.py sheets/terrain_desert_cover.png ../../assets/terrain/desert_rubble.png --size 128 --seamless --variants 3 --flatten 0.92

# 4) 图标打包（等比缩放 + 居中，一排图标视觉大小一致）
python3 tools/pack_icons.py derived/icons_v1 ../../assets/ui/icons --names icon_names.txt --sheet derived/check_icons.png

# 5) 单位/道具按游戏尺度出图（同时留 _hd/ 原图）
python3 tools/promote_assets.py

# 6) 验收图
python3 tools/make_previews.py
```

### 三个工具各自解决的问题

- **`split_sheet.py`**：洋红底素材表 → 带 alpha 的独立 PNG。
  边框取中位数估背景色 → 按色彩距离算 alpha → 反预乘去粉边 →
  **去洋红溢色**（旋翼、烟尘这类半透明像素会把背景品红带进来，
  第一次出的无人机旋翼是紫的，就是这一步修掉的）→ 按 `--cells 3x3`
  的排版网格归属连通域（跨格的枪管不会被切掉）。
- **`make_tile.py`**：地表原图 → 游戏瓦片。
  ① 半幅平移 + 接缝带融合 + 亮度校正；② **低频压平**（高通后乘回平均色）
  抹掉厘米级明暗团块——不然平铺时「同一块砖反复出现」一眼看穿；
  ③ 与空地瓦片按权重混合，把掩体瓦片的对比度压到与地面同一档；④ 出 3 个变体。
- **`promote_assets.py` / `pack_icons.py`**：按游戏尺度出图 + 命名 + 留高清原图。

### 验收图（在 `_source/derived/`）

| 文件 | 看什么 |
| --- | --- |
| `pack_scale_snow.png` / `pack_scale_desert.png` | 所有单位/道具在 **1:1 游戏尺度**（放大 4 倍显示）叠在雪地/沙漠地形上的样子 |
| `pack_overview.png` | 素材包总览：单位 9 + 道具 9 + 地形 4 + 图标 16 |
| `check_terrain.png` | 每张瓦片按 2×2 平铺，看接缝与重复感 |
| `check_units_v1.png` / `check_props_v1.png` / `check_icons.png` | 拆图结果，确认洋红去干净、没有串图 |

---

## 六、接线映射（下一步，尚未实施）

| 现状 | 接线做法 |
| --- | --- |
| `soldier.tscn` 的 `ColorRect` `Body` | 换成 `Sprite2D`（`units/soldier.png`，医疗兵换 `medic.png`），保留 `body_rect.modulate` 那套受击闪白（改名到 sprite 即可） |
| `tank.tscn` / `drone.tscn` / `fpv_drone.tscn` / `grenade.tscn` / `truck.tscn` / `build_site.gd` 的 `_draw()` | 这些是程序化绘制：加一个 `Sprite2D` 子节点画贴图，`_draw()` 只留血条/进度环/旗帜等**动态元素**；`is_dead` 分支换 `*_wreck.png` |
| `battle_map.gd` 的 `_draw_terrain()` | 铺 `TileMapLayer`（4 类地形各一套瓦片，按坐标取变体）；`TERRAIN_COLORS` 仅作后备 |
| HUD `Label` | 行首加 `ui/icons/small/*.png` 的 `TextureRect` |

> 注意：本仓库所有美术改动都是「**headless CI 不渲染**」的部分——
> `.github/workflows/ci.yml` 里九个测试场景只看逻辑与数值，换贴图不会碰到断言；
> 但 `gdparse` / `gdlint` 仍会对脚本做语法与风格检查，改场景文件要顺带跑一遍。
