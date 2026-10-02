//! 程序化地形生成。
//!
//! **为什么放在 `sim_core` 而不是 CLI**："命令行里验收过的那张图"和"编辑器里
//! 跑的那张图"必须是同一个 —— 否则验收过的行为和玩家看到的行为是两回事（A6）。
//!
//! M1 阶段这就是唯一的地图来源（`build_city`）；真地图加载接上后这里只留
//! 测试与 bench 用的生成函数。

use sim_math::Pcg32;

use crate::world::{mat, Segment, World};

/// 一张"能验收的巷战图"：楼块 + 院墙 + 残骸 + 瓦砾 + 沙袋。
///
/// 密度是**验收的一部分**：§20.1.8 要求"3 秒内 blocking ≥ 0.7"，冲刺 3 m/s
/// ⇒ 直线 9 m 以内必须有掩体，绕路还要再乘 1.5~2 倍。瓦砾那一段（0.5~0.9 m，
/// 只能卧倒利用）专门用来填楼与楼之间的开阔地 —— 少了它，广场中央出生的
/// 士兵最近掩体在 10 m 开外，怎么调评分都过不了。
pub fn build_city(rng: &mut Pcg32, dim_cells: u32) -> World {
    let mut w = World::new_flat(dim_cells, 32, -8000);
    let dim = dim_cells as i64;
    let put = |w: &mut World, x: i64, z: i64, s: Segment| {
        if x >= 0 && z >= 0 && x < dim && z < dim {
            w.push_segment(x as u32, z as u32, s);
        }
    };

    // 建筑：矩形块（4..13 柱 ≈ 2..6.5 m 宽），高 3..7.5 m；1/3 带窗洞
    let blocks = (dim / 6).max(8);
    for _ in 0..blocks {
        let bw = 6 + rng.next_range(11) as i64;
        let bd = 6 + rng.next_range(11) as i64;
        let x0 = rng.next_range(dim_cells) as i64;
        let z0 = rng.next_range(dim_cells) as i64;
        let h = 3000 + rng.next_range(4) as i32 * 1500;
        if rng.next_range(3) == 0 {
            for z in z0..(z0 + bd) {
                for x in x0..(x0 + bw) {
                    put(&mut w, x, z, Segment::new(0, 1100, mat::BRICK, 400));
                    put(&mut w, x, z, Segment::new(1900, h, mat::BRICK, 400));
                }
            }
        } else {
            for z in z0..(z0 + bd) {
                for x in x0..(x0 + bw) {
                    put(&mut w, x, z, Segment::new(0, h, mat::CONCRETE, 700));
                }
            }
        }
    }

    // 院墙：成排矮墙（0.9..1.3 m），是"蹲下全藏、起身探头"的主力掩体
    let walls = (dim / 10).max(5);
    for _ in 0..walls {
        let len = 6 + rng.next_range(14) as i64;
        let x0 = rng.next_range(dim_cells) as i64;
        let z0 = rng.next_range(dim_cells) as i64;
        let horizontal = rng.next_range(2) == 0;
        let h = 900 + rng.next_range(3) as i32 * 200;
        for k in 0..len {
            let (x, z) = if horizontal { (x0 + k, z0) } else { (x0, z0 + k) };
            put(&mut w, x, z, Segment::new(0, h, mat::BRICK, 220));
        }
    }

    // 车辆残骸：2×2 柱、1.2 m 金属（会被打穿）
    for _ in 0..(dim / 12).max(6) {
        let x = rng.next_range(dim_cells) as i64;
        let z = rng.next_range(dim_cells) as i64;
        for dz in 0..2 {
            for dx in 0..2 {
                put(&mut w, x + dx, z + dz, Segment::new(0, 1200, mat::WRECK, 150));
            }
        }
    }

    // 散落瓦砾：0.5..0.9 m，只能卧倒利用 —— 专门用来填建筑之间的开阔地。
    // 少了这些，广场中央出生的士兵最近掩体在 10 m 外，3 秒根本到不了。
    for _ in 0..(dim / 3) {
        let x = rng.next_range(dim_cells) as i64;
        let z = rng.next_range(dim_cells) as i64;
        let h = 500 + rng.next_range(7) as i32 * 100;
        let n = 1 + rng.next_range(3) as i64;
        for k in 0..n {
            put(
                &mut w,
                x + (k % 2),
                z + (k / 2),
                Segment::new(0, h, mat::BRICK, 120),
            );
        }
    }

    // 沙袋掩体：短墙 0.9 m
    for _ in 0..(dim / 8).max(6) {
        let len = 2 + rng.next_range(4) as i64;
        let x0 = rng.next_range(dim_cells) as i64;
        let z0 = rng.next_range(dim_cells) as i64;
        let horizontal = rng.next_range(2) == 0;
        for k in 0..len {
            let (x, z) = if horizontal { (x0 + k, z0) } else { (x0, z0 + k) };
            put(&mut w, x, z, Segment::new(0, 900, mat::SANDBAG, 90));
        }
    }
    w
}
