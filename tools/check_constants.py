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


def s(v: str | None) -> str:
    """去掉 ron 字符串的引号。"""
    return (v or "").strip().strip('"')


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

    # ── C2. 导航（M0.3，T1）────────────────────────────────────────────
    h_stand = as_int(ron.get("height_stand_mm"))
    h_crouch = as_int(ron.get("height_crouch_mm"))
    h_prone = as_int(ron.get("height_prone_mm"))
    clearance = as_int(ron.get("clearance_mm"))
    shoulder = as_int(ron.get("shoulder_width_mm"))
    slot = as_int(ron.get("slot_capacity_mm"))
    step_up = as_int(ron.get("step_up_mm"))
    step_down = as_int(ron.get("step_down_mm"))
    slope = as_int(ron.get("max_slope_deg"))
    nav_rebuild = as_int(ron.get("rebuild_ticks"))
    nav_radius = as_int(ron.get("radius_mm"))
    c_ortho = as_int(ron.get("cost_orthogonal"))
    c_diag = as_int(ron.get("cost_diagonal"))
    unreach = as_int(ron.get("unreachable"))

    check(h_prone is not None and h_crouch is not None and h_stand is not None
          and h_prone < h_crouch < h_stand,
          "nav 姿态高度单调：卧 < 蹲 < 站", f"{h_prone} / {h_crouch} / {h_stand}")
    check(clearance is not None and h_stand is not None
          and h_stand < clearance <= h_stand + 200,
          "nav.clearance_mm = 站高 + 小余量(≤200mm)", f"{clearance} vs {h_stand}")
    check(shoulder is not None and slot is not None and shoulder == slot,
          "nav.shoulder_width_mm = cover.slot_capacity_mm（同一条约束）",
          f"{shoulder} / {slot}")
    check(step_up is not None and h_crouch is not None and step_up < h_crouch,
          "nav.step_up_mm < 蹲姿身高（能跨上的台阶不该高过蹲姿）", f"{step_up} / {h_crouch}")
    check(step_up is not None and step_down is not None and step_up <= step_down,
          "nav.step_up_mm ≤ step_down_mm", f"{step_up} / {step_down}")
    check(slope == 30, "nav.max_slope_deg = 30（R4 阶梯近似的美术约束）", f"{slope}")
    check(nav_rebuild is not None and hz and hz % nav_rebuild == 0,
          "nav.rebuild_ticks 是 30Hz 的整数分频", f"{nav_rebuild}")
    check(nav_radius is not None and size is not None and nav_radius <= size,
          "nav.radius_mm ≤ 地图边长", f"{nav_radius} / {size}")
    check(c_ortho is not None and c_diag is not None
          and abs(c_diag - round(c_ortho * 2 ** 0.5)) <= 1,
          "nav.cost_diagonal = cost_orthogonal × √2", f"{c_diag} vs {round((c_ortho or 0) * 2 ** 0.5)}")
    check(unreach == 4294967295, "nav.unreachable = u32::MAX", f"{unreach}")
    # 与掩体采样点自洽：最高采样点必须低于该姿态的头顶高度
    for key, top in (("samples_stand_mm", h_stand), ("samples_crouch_mm", h_crouch),
                     ("samples_prone_mm", h_prone)):
        vals = ints_in(ron.get(key))
        check(bool(vals) and top is not None and max(vals) < top,
              f"nav 头顶高度 > cover.{key} 的最大值", f"{max(vals) if vals else '?'} vs {top}")

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

    # ── E. 审查修复项的不变量（R1/R2/R3/R4/R5/R8/R10）────────────────────
    # R1：模拟 LOD 只能依赖 sim 状态，禁止相机/选中进入 sim
    check(s(ron.get("lod_basis")) == "sim_state", "R1 模拟 LOD 依据 = sim_state", s(ron.get("lod_basis")))
    check("camera" in (ron.get("forbid_lod_inputs") or ""), "R1 禁止相机作为 LOD 输入")
    # R2：模拟无秘密 / 呈现有迷雾
    check(s(ron.get("visibility")) == "render_fog", "R2 信息可见性 = render_fog", s(ron.get("visibility")))
    # R3：命中判定逐点
    check(s(ron.get("hit_granularity")) == "per_point", "R3 命中判定 = per_point", s(ron.get("hit_granularity")))
    # R4：几何与导航
    check(s(ron.get("geo_authority")) == "voxel", "R4 权威几何 = voxel")
    check(s(ron.get("segments_allow_gaps")).lower() == "true", "R4 段之间允许空隙（悬挑/桥下）")
    nav = s(ron.get("nav_model"))
    check("field_2d" in nav and "explicit_graph" in nav, "R4 导航 = 2D 流场 + 显式图", nav)
    slope = as_int(ron.get("slope_max_deg"))
    check(slope is not None and 0 < slope <= 45, "R4 斜面阶梯近似的坡度上限合理", f"{slope}°")

    # R5：伤员状态机时间线自洽
    bmin, bmax, bdef = (as_int(ron.get("bleed_ms_min")), as_int(ron.get("bleed_ms_max")),
                        as_int(ron.get("bleed_ms_default")))
    check(bmin and bmax and bdef and bmin <= bdef <= bmax, "R5 bleed 默认值落在 [min, max]",
          f"{bdef} ∈ [{bmin}, {bmax}]")
    crit = as_int(ron.get("critical_window_ms"))
    check(crit is not None and crit > 0, "R5 Critical 窗口 > 0（CPR 才有意义）", f"{crit}")
    cpr_v = as_int(ron.get("cpr_vitality_loss"))
    check(cpr_v is not None and cpr_v > 0, "R5 CPR 成功要扣 vitality", f"{cpr_v}")
    check(as_int(ron.get("critical_bleed_reset_ms")) is not None
          and as_int(ron.get("critical_bleed_reset_ms")) > 0, "R5 CPR 后重置失血时间 > 0")

    # R5：救援决策必须是 risk 的全函数，分区严格递增且都 < 1
    r_direct, r_low, r_sup = (ron.get("rescue_risk_direct"), ron.get("rescue_risk_low"),
                              ron.get("rescue_risk_suppress"))
    try:
        vals = [float(r_direct), float(r_low), float(r_sup)]
    except (TypeError, ValueError):
        vals = []
    check(len(vals) == 3 and vals[0] < vals[1] < vals[2] < 1.0,
          "R5 救援风险分区严格递增且 < 1（无未定义区间）", f"{vals}")
    check(s(ron.get("rescue_risk_force_on_critical")).lower() == "true",
          "R5 Critical 时强制救援（绝不丢下任何人）")
    b7 = ron.get("rescue_b7_risk_ceiling")
    check(b7 is not None and float(b7) == float(r_sup), "R5 B7 验收上限 = 强制救援阈值", f"{b7} vs {r_sup}")

    # R8：预算口径自洽（每 tick 与每帧摊销）
    p50, amort = ron.get("tick_p50_ms"), ron.get("frame_amort_ms")
    if p99 and amort:
        expect = float(p99) * 0.5
        check(abs(float(amort) - expect) < 0.2, "R8 每帧摊销 = p99 × 0.5（60fps）",
              f"{amort} vs {expect:.2f}")
    mtpf = as_int(ron.get("max_ticks_per_frame"))
    check(mtpf is not None and mtpf >= 1, "R8 追帧上限 ≥ 1", f"{mtpf}")
    check(as_int(ron.get("catchup_stall_ticks")) is not None
          and as_int(ron.get("catchup_stall_ticks")) > mtpf, "R8 降级阈值 > 追帧上限")

    # R10：覆盖角按半角判定
    cbase, cmax = as_int(ron.get("coverage_base_deg")), as_int(ron.get("coverage_max_deg"))
    check(cbase and cmax and cbase <= cmax <= 180, "R10 覆盖角范围合理", f"{cbase}..{cmax}")
    check(s(ron.get("coverage_is_full_angle")).lower() == "true",
          "R10 coverage 标记为全角（判定时取半角）")
    fm = as_int(ron.get("flank_margin_deg"))
    check(fm is not None and 0 < fm <= 45, "R10 侧翼 margin 合理", f"{fm}°")

    # 文档同步：关键裁定必须在设计文档里出现
    for needle, label in [("Critical", "R5 伤员状态机"), ("render_fog", "R2 信息可见性"),
                          ("angular_factor", "R10 侧翼判定"), ("per_point", "R3 逐点命中"),
                          ("sim_state", "R1 LOD 依据")]:
        check(needle.lower() in doc.lower(), f"文档包含「{label}」裁定 ({needle})")

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
