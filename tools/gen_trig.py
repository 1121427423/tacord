#!/usr/bin/env python3
"""
生成 sim_math 的确定性查找表（sin 与 atan），并输出 PCG32 的参考序列。

为什么必须"烘焙"而不是运行时/构建时计算：
    多平台 bit-exact lockstep 要求每台机器得到**逐位相同**的表。
    如果在 build.rs 里用 libm 的 sin()，不同平台的 libm 可能有 1ulp 差异，
    表就不同，两台机器会静默 desync。
    → 表由本脚本在**开发机一次性生成并提交进仓库**，运行时只做查表 + 整数插值。

    sin：只存 [0, π/2] 的四分之一波，1025 个 Q16 采样点，靠对称性得到全圆。
    atan：存 atan(r) for r ∈ [0,1]，1025 个 Q16 采样点（单位是弧度/π，见下）。

用法：
    python3 tools/gen_trig.py            # 生成 sim/crates/sim_math/src/tables.rs
    python3 tools/gen_trig.py --check    # 只校验已生成的表与重新计算的一致（CI 用）
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "crates" / "sim_math" / "src" / "tables.rs"

N = 1024                 # 区间数：0..1024 → 1025 个采样点
Q16_ONE = 1 << 16
TWO_PI_INV_ANG = 65536.0


def q16(x: float) -> int:
    """四舍五入到最近的 Q16 定点值（不是截断，截断会造成系统性偏差）。"""
    return int(math.floor(x * Q16_ONE + 0.5))


def gen_sin_table() -> list[int]:
    """sin(x), x ∈ [0, π/2]，共 N+1 个点，Q16。"""
    return [q16(math.sin(math.pi / 2 * i / N)) for i in range(N + 1)]


def gen_atan_table() -> list[int]:
    """atan(r) / (π/4), r ∈ [0,1]，共 N+1 个点，Q16。

    存归一化值（0 → 0，1 → Q16_ONE 表示 π/4）让 atan2 只需一次查表 + 象限修正，
    且整个表的值域正好是 [0,1]，Q16 精度被充分利用。
    """
    return [q16(math.atan(i / N) / (math.pi / 4)) for i in range(N + 1)]


# ─────────────────────────── PCG32 参考实现（与 Rust 逐位一致）────────────────────────
M64 = (1 << 64) - 1
MULT = 6364136223846793005


def pcg32_next(state: int, inc: int) -> tuple[int, int]:
    old = state
    state = (old * MULT + inc) & M64
    xorshifted = (((old >> 18) ^ old) >> 27) & 0xFFFFFFFF
    rot = (old >> 59) & 0xFFFFFFFF
    out = ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & 0xFFFFFFFF
    return state, out


def pcg32_stream(seed: int, stream: int, n: int) -> list[int]:
    inc = ((stream << 1) | 1) & M64
    state = (seed + inc) & M64
    state, _ = pcg32_next(state, inc)          # 预热一步（与 Rust new() 一致）
    outs = []
    for _ in range(n):
        state, o = pcg32_next(state, inc)
        outs.append(o)
    return outs


def render(sin_t: list[int], atan_t: list[int]) -> str:
    def block(name: str, ty: str, values: list[int], doc: str) -> str:
        lines = []
        per_line = 8
        for i in range(0, len(values), per_line):
            chunk = ", ".join(f"{v}" for v in values[i : i + per_line])
            lines.append(f"    {chunk},")
        body = "\n".join(lines)
        return (
            f"/// {doc}\n"
            f"///\n"
            f"/// 由 `tools/gen_trig.py` 生成 —— **禁止手改**，改表请改生成脚本并重新生成。\n"
            f"pub static {name}: [{ty}; {len(values)}] = [\n{body}\n];\n"
        )

    return (
        "// 确定性查找表（烘焙进仓库，保证多平台逐位一致）\n"
        "//\n"
        "// ⚠ 本文件由 tools/gen_trig.py 生成，请勿手工编辑。\n"
        "//    CI 会用 `python3 tools/gen_trig.py --check` 校验它与重新计算的结果一致。\n"
        "//\n"
        "// 为什么不用 build.rs 生成：build.rs 依赖宿主机 libm 的 sin()/atan()，\n"
        "// 不同平台可能有 1ulp 差异 → 表不同 → 多平台 lockstep 静默 desync。\n"
        "\n"
        + block(
            "SIN_QUARTER",
            "i32",
            sin_t,
            "sin(x), x ∈ [0, π/2]，Q16 定点，共 1025 点（索引 i 对应 x = i/N × π/2）。",
        )
        + "\n"
        + block(
            "ATAN_RATIO",
            "i32",
            atan_t,
            "atan(r) / (π/4), r ∈ [0,1]，Q16 定点，共 1025 点（索引 i 对应 r = i/N）。",
        )
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验已生成的表是否最新")
    ap.add_argument("--emit-pcg", action="store_true", help="打印 PCG32 参考序列（用于 Rust 单测）")
    args = ap.parse_args()

    sin_t = gen_sin_table()
    atan_t = gen_atan_table()
    text = render(sin_t, atan_t)

    if args.check:
        if not OUT.exists():
            print(f"缺少 {OUT}", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != text:
            print("表已过期：请运行 `python3 tools/gen_trig.py` 重新生成", file=sys.stderr)
            return 1
        print(f"✓ 查找表一致（{OUT.relative_to(ROOT)}，sin {len(sin_t)} 点 / atan {len(atan_t)} 点）")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"✓ 已生成 {OUT.relative_to(ROOT)}")
    print(f"  sin  : {len(sin_t)} 点，sin(0)={sin_t[0]}, sin(π/2)={sin_t[-1]} (期望 0 / 65536)")
    print(f"  atan : {len(atan_t)} 点，atan(0)={atan_t[0]}, atan(1)={atan_t[-1]} (期望 0 / 65536)")
    if args.emit_pcg:
        print("\n  PCG32 参考序列（seed=0x1234_5678_9ABC_DEF0, stream=7 的前 4 个输出）：")
        for v in pcg32_stream(0x123456789ABCDEF0, 7, 4):
            print(f"    0x{v:08X}  ({v})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
