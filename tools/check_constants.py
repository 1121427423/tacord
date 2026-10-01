#!/usr/bin/env python3
"""
tacord 参数一致性自检（CI 用）

设计文档 docs/design/05-frozen-parameters.md 是给人看的，
sim/data/constants.ron 是给机器看的。两者必须一致，否则 CI 失败。

本脚本做三类检查：
  A. 派生量校验：GRID_DIM / CHUNK_GRID 等必须由 WORLD_SIZE 与 COLUMN_SIZE 推导且自洽
  B. 分频校验：所有 AI 周期必须整除 60，且是 30Hz 的整数分频（保证摊还桶无余数）
  C. 规模与预算校验：内存估算、单位上限、性能预算的粗一致性
  D. 文档 ↔ ron 对照：抽查若干 T0 常量在两处出现且数值一致

用法：
    python3 tools/check_constants.py            # 检查
    python3 tools/check_constants.py --verbose  # 打印所有受检项
退出码：0 通过，1 失败。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RON = ROOT / "sim" / "data" / "constants.ron"
DOC = ROOT / "docs" / "design" / "05-frozen-parameters.md"

errors: list[str] = []
checks: list[str] = []


def ok(msg: str) -> None:
    checks.append(msg)


def err(msg: str) -> None:
    errors.append(msg)
    checks.append(f"FAIL: {msg}")


def check(cond: bool, msg: str, detail: str = "") -> None:
    if cond:
        ok(msg)
    else:
        err(f"{msg}{(' — ' + detail) if detail else ''}")


# ───────────────────────── 极简 RON 解析（只取 key: value 对）─────────────────────────

STRIP_COMMENTS = re.compile(r"//.*?$", re.MULTILINE)


def parse_ron(text: str) -> dict[str, str]:
    """把 ron 的 `key: value` 对（含嵌套 struct）拉平成一个扁平 dict。
    只解析数字、字符串、布尔与简单数组，足够做常量校验。"""
    text = STRIP_COMMENTS.sub("", text)
    flat: dict[str, str] = {}
    # 匹配 key: value，value 到行尾（数组可能跨行，这里单独处理）
    for m in re.finditer(
        r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
        r"(\"[^\"]*\"|\[[^\]]*\]|\([^)]*\)|[Tt]rue|[Ff]alse|-?\d+(?:\.\d+)?)\s*,?",
        text,
    ):
        flat.setdefault(m.group(1), m.group(2).strip())
    return flat


def as_int(v: str | None) -> int | None:
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def ints_in(v: str | None) -> list[int]:
    if not v:
        return []
    return [int(x) for x in re.findall(r"-?\d+", v)]


# ───────────────────────────────── 检查项 ─────────────────────────────────

def main() -> int:
    if not RON.exists():
        print(f"缺少 {RON}", file=sys.stderr)
        return 1
    if not DOC.exists():
        print(f"缺少 {DOC}", file=sys.stderr)
        return 1

    ron = parse_ron(RON.read_text(encoding="utf-8"))
    # 去掉 markdown 强调符号，便于用纯文本对照常量
    doc = DOC.read_text(encoding="utf-8").replace("**", "").replace("`", "")

    # ── A. 世界派生量（T0，全 2 的幂）──────────────────────────────────
    size = as_int(ron.get("size_mm"))
    col = as_int(ron.get("column_size_mm"))
    grid = as_int(ron.get("grid_dim"))
    chunk = as_int(ron.get("chunk_dim_cells"))
    chunk_grid = as_int(ron.get("chunk_grid"))

    check(size == 1024000, "world.size_mm = 1024 m (2^10 m)", f"实际 {size}")
    check(col == 500, "world.column_size_mm = 0.5 m", f"实际 {col}")
    check(grid is not None and size and col and grid == size // col,
          "grid_dim = size_mm / column_size_mm", f"{grid} vs {size // col if size and col else '?'}")
    check(grid is not None and grid & (grid - 1) == 0, "grid_dim 是 2 的幂（可位移索引）", f"{grid}")
    check(chunk is not None and chunk & (chunk - 1) == 0, "chunk_dim_cells 是 2 的幂", f"{chunk}")
    check(chunk_grid is not None and grid and chunk and chunk_grid == grid // chunk,
          "chunk_grid = grid_dim / chunk_dim_cells", f"{chunk_grid} vs {grid // chunk if grid and chunk else '?'}")
    check(chunk_grid is not None and chunk_grid & (chunk_grid - 1) == 0, "chunk_grid 是 2 的幂", f"{chunk_grid}")

    # 高度范围
    hmin, hmax = as_int(ron.get("height_min_mm")), as_int(ron.get("height_max_mm"))
    check(hmin is not None and hmax is not None and hmin < 0 < hmax,
          "高度范围覆盖地下与地上", f"{hmin}..{hmax}")

    # ── B. 时间分频 ────────────────────────────────────────────────────
    hz = as_int(ron.get("sim_hz"))
    check(hz == 30, "sim_hz = 30", f"实际 {hz}")
    if hz:
        for key in ("soldier_period", "cover_period", "perception_period",
                    "squad_period", "command_period", "checksum_period"):
            v = as_int(ron.get(key))
            check(v is not None and v > 0 and hz % v == 0,
                  f"time.{key} 是 {hz}Hz 的整数分频", f"{v}")
        snap = as_int(ron.get("snapshot_period"))
        check(snap is not None and snap % hz == 0, "snapshot_period 是整秒", f"{snap} ticks")

    # 单局时长换算（30Hz）
    for key, expect_min in (("match_skirmish_ticks", 25), ("match_campaign_ticks", 45),
                            ("match_slice_ticks", 5)):
        v = as_int(ron.get(key))
        check(v is not None and hz and abs(v / hz / 60 - expect_min) < 0.01,
              f"time.{key} = {expect_min} 分钟", f"{v} ticks")

    # ── C. 规模与预算 ─────────────────────────────────────────────────
    max_units = as_int(ron.get("sim_max_units"))
    target = as_int(ron.get("perf_target_units"))
    check(max_units == 512, "sim_max_units = 512（SoA 预分配，T0）", f"{max_units}")
    check(target is not None and max_units is not None and target <= max_units,
          "perf_target_units ≤ sim_max_units", f"{target} / {max_units}")

    # 编制自洽：squad = 2*fire_team + 1；platoon = 3*squad + 2；company = 3*platoon + 3
    ft, sq, pl, co = (as_int(ron.get("fire_team")), as_int(ron.get("squad")),
                      as_int(ron.get("platoon")), as_int(ron.get("company")))
    check(ft and sq == 2 * ft + 1, "squad = 2 × fire_team + 1", f"{sq} vs {2 * ft + 1 if ft else '?'}")
    check(sq and pl == 3 * sq + 2, "platoon = 3 × squad + 2", f"{pl} vs {3 * sq + 2 if sq else '?'}")
    check(pl and co == 3 * pl + 3, "company = 3 × platoon + 3", f"{co} vs {3 * pl + 3 if pl else '?'}")

    # 内存粗估：柱段 12B × 平均 1.3 段 × grid²
    if grid:
        est_mb = grid * grid * 1.3 * 12 / 1024 / 1024
        mem_sim = as_int(ron.get("mem_sim_mb"))
        check(est_mb < mem_sim, "柱数据内存估算 < sim 内存预算",
              f"估算 {est_mb:.0f} MB vs 预算 {mem_sim} MB")
        ok(f"柱数据内存估算 ≈ {est_mb:.0f} MB（{grid}² 柱 × 1.3 段 × 12B）")

    # 性能预算：tick 预算必须小于 tick 周期
    p99 = ron.get("tick_p99_ms")
    check(p99 is not None and float(p99) < 1000 / (hz or 30),
          "tick p99 预算 < tick 周期", f"{p99} ms vs {1000 / (hz or 30):.1f} ms")

    # 威胁场网格：cell 必须整除世界尺寸
    tcell = as_int(ron.get("threat_cell_mm"))
    check(tcell and size and size % tcell == 0,
          "threat_cell_mm 整除 world.size_mm", f"{tcell} / {size}")

    # ── D. 文档 ↔ ron 对照（T0 抽查）───────────────────────────────────
    pairs = [
        ("1024 m × 1024 m", size == 1024000, "地图尺寸"),
        ("SIM_HZ", hz == 30, "模拟频率(30Hz)"),
        ("512", max_units == 512, "单位硬上限"),
        ("9 人", sq == 9, "班编制"),
        ("Lockstep", "lockstep" in (ron.get("model") or "").lower(), "网络模型"),
        ("6 tick", as_int(ron.get("input_delay_ticks")) == 6, "输入延迟"),
        ("定点数", "fixed_point" in (ron.get("strategy") or ""), "确定性策略"),
        ("HTN", "htn" in (ron.get("architecture") or "").lower(), "AI 架构"),
    ]
    for needle, cond, label in pairs:
        check(needle in doc, f"文档包含 T0 常量「{label}」({needle})")
        if not cond:
            err(f"ron 中「{label}」与文档不一致")

    # 文档版本行
    check("schema_version" in ron or "constants_schema" in ron, "ron 带 schema 版本")
    check(ron.get("record_constants_hash", "").lower() in ("true", "yes"),
          "回放记录 constants_hash（调参后旧回放自动失效）")

    # ── 输出 ──────────────────────────────────────────────────────────
    if "--verbose" in sys.argv:
        for c in checks:
            print(("  " if not c.startswith("FAIL") else "") + c)

    n_ok = sum(1 for c in checks if not c.startswith("FAIL"))
    print(f"\n参数自检：{n_ok}/{len(checks)} 通过")
    if errors:
        print(f"\n{len(errors)} 项失败：")
        for e in errors:
            print(f"  ✗ {e}")
        return 1
    print("✓ constants.ron 与设计文档一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
