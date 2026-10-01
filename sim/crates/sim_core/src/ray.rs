//! 体素 DDA 射线（Amanatides–Woo）—— **全项目唯一的"这条线被挡住了吗"判定**。
//!
//! 掩体派生（我藏住了吗）、视线（我看得见他吗）、弹道（我打得中吗）都调用 `cast`，
//! 因此三者不可能出现规则分歧（设计文档 R3 / §20.1.3.1 / §30.3.2）。
//!
//! 实现约束：
//! - 全整数：参数 t 用**有理数** `t_num / t_den` 表示，跨轴比较 Cross-free（统一分母），
//!   不使用浮点、不使用除法求交点（除法只在最后算 y 时出现一次）。
//! - 越界格子视为空（继续遍历），因此射线可以从世界外进入 —— 不会出现"界外直接返回"。
//! - 每格内用**精确板式测试**（进入/离开时的 y 与段的 top/bottom 比较），
//!   而不是"y 区间重叠"的保守近似。
//!
//! 已知近似：段只在其所属柱内有效，因此斜穿薄板时可能有一格（0.5 m）级别的保守判定。
//! 这对掩体与命中都成立，且两者共用同一函数，所以不会造成规则不一致。

use super::world::{World, Segment};
use super::{floor_div, tdiv, CELL_MM};
use sim_math::{Mm, Vec3};

/// 遍历安全上限：一格 0.5 m，2^20 格 = 524 km，远超任何合法射线。
const MAX_STEPS: u64 = 1 << 20;
/// "永不选中"的 t 值（用于退化轴）。取 `i64::MAX/4` 以免累加溢出。
const INF: i64 = i64::MAX / 4;

/// 射线模式：视线与子弹的阻挡材质可以不同（铁丝网挡人挡视线但不挡子弹）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum RayMode {
    /// 看得见吗（用 `Material::blocks_sight`）
    Sight,
    /// 打得中吗（用 `Material::blocks_bullet`）
    Projectile,
}

/// 命中结果。`t` 以有理数 `t_num / t_den` 给出，调用方可精确求交点点。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct RayHit {
    pub cell_x: i32,
    pub cell_z: i32,
    /// 命中段在该柱中的索引（可直接喂给 `World::damage`）。
    pub seg_index: u32,
    pub t_num: i64,
    pub t_den: i64,
}

/// 投射一条射线，返回**第一个**命中（`None` = 通畅）。
pub fn cast(world: &World, a: Vec3, b: Vec3, mode: RayMode) -> Option<RayHit> {
    let ax = a.x.0 as i64;
    let ay = a.y.0 as i64;
    let az = a.z.0 as i64;
    let dx = b.x.0 as i64 - ax;
    let dy = b.y.0 as i64 - ay;
    let dz = b.z.0 as i64 - az;
    let adx = dx.abs();
    let adz = dz.abs();

    // 射线长度上限保护（避免 dy * t 溢出）：≤ 100 km
    debug_assert!(adx < 100_000_000 && adz < 100_000_000, "射线过长");

    let mut cx = floor_div(ax, CELL_MM);
    let mut cz = floor_div(az, CELL_MM);

    // 垂直射线（或零长度）：只测当前一格
    if adx == 0 && adz == 0 {
        return match hit_seg(world, cx, cz, a.y.0, b.y.0, mode) {
            Some(idx) => Some(RayHit {
                cell_x: cx as i32,
                cell_z: cz as i32,
                seg_index: idx,
                t_num: 0,
                t_den: 1,
            }),
            None => None,
        };
    }

    let (den, mut t_max_x, mut t_del_x, mut t_max_z, mut t_del_z, step_x, step_z);

    if adz == 0 {
        // 只沿 X：分母取 |dx|（t 的单位就是"沿 x 走过的毫米"）
        den = adx;
        step_x = if dx > 0 { 1 } else { -1 };
        step_z = 0;
        let nxb = if dx > 0 {
            (cx + 1) * CELL_MM
        } else {
            cx * CELL_MM
        };
        t_max_x = (nxb - ax).abs();
        t_del_x = CELL_MM;
        t_max_z = INF;
        t_del_z = INF;
    } else if adx == 0 {
        // 只沿 Z
        den = adz;
        step_x = 0;
        step_z = if dz > 0 { 1 } else { -1 };
        let nzb = if dz > 0 {
            (cz + 1) * CELL_MM
        } else {
            cz * CELL_MM
        };
        t_max_z = (nzb - az).abs();
        t_del_z = CELL_MM;
        t_max_x = INF;
        t_del_x = INF;
    } else {
        // 一般情况：统一分母 |dx|·|dz|
        den = adx * adz;
        step_x = if dx > 0 { 1 } else { -1 };
        step_z = if dz > 0 { 1 } else { -1 };
        let nxb = if dx > 0 {
            (cx + 1) * CELL_MM
        } else {
            cx * CELL_MM
        };
        let nzb = if dz > 0 {
            (cz + 1) * CELL_MM
        } else {
            cz * CELL_MM
        };
        t_max_x = (nxb - ax).abs() * adz;
        t_del_x = CELL_MM * adz;
        t_max_z = (nzb - az).abs() * adx;
        t_del_z = CELL_MM * adx;
    }

    let y_at = |t: i64| ay + tdiv(dy * t, den);
    let mut t_prev: i64 = 0;
    let mut steps: u64 = 0;

    loop {
        steps += 1;
        if steps > MAX_STEPS {
            return None; // 安全阀：正常射线不可能走到这里
        }
        let t_next = if t_max_x < t_max_z { t_max_x } else { t_max_z };
        let t_end = if t_next < den { t_next } else { den };
        let y0 = y_at(t_prev) as i32;
        let y1 = y_at(t_end) as i32;

        if let Some(idx) = hit_seg(world, cx, cz, y0, y1, mode) {
            return Some(RayHit {
                cell_x: cx as i32,
                cell_z: cz as i32,
                seg_index: idx,
                t_num: t_prev,
                t_den: den,
            });
        }
        if t_end >= den {
            return None; // 走完整条射线都没挡住
        }
        t_prev = t_next;
        if t_max_x < t_max_z {
            cx += step_x;
            t_max_x += t_del_x;
        } else if t_max_z < t_max_x {
            cz += step_z;
            t_max_z += t_del_z;
        } else {
            // 正好穿过格点：两轴同时前进（否则会"穿角而过"漏判）
            cx += step_x;
            cz += step_z;
            t_max_x += t_del_x;
            t_max_z += t_del_z;
        }
    }
}

/// 只关心"挡不挡"（比 `cast` 少一次结构体构造，热路径用这个）。
#[inline]
pub fn blocked(world: &World, a: Vec3, b: Vec3, mode: RayMode) -> bool {
    cast(world, a, b, mode).is_some()
}

/// 由命中结果求交点点（毫米，向下取整到毫米）。
pub fn hit_point(a: Vec3, b: Vec3, hit: &RayHit) -> Vec3 {
    let den = if hit.t_den == 0 { 1 } else { hit.t_den };
    let lerp = |p0: i32, p1: i32| -> i32 {
        let d = (p1 as i64 - p0 as i64) * hit.t_num;
        (p0 as i64 + tdiv(d, den)) as i32
    };
    Vec3::new(
        Mm(lerp(a.x.0, b.x.0)),
        Mm(lerp(a.y.0, b.y.0)),
        Mm(lerp(a.z.0, b.z.0)),
    )
}

/// 在**单格内**做精确板式测试：射线在该格内的 y 从 `y0` 走到 `y1`。
fn hit_seg(world: &World, cx: i64, cz: i64, y0: i32, y1: i32, mode: RayMode) -> Option<u32> {
    if cx < 0 || cz < 0 || cx >= world.dim_cells as i64 || cz >= world.dim_cells as i64 {
        return None; // 界外：没有几何体，自然不阻挡（但遍历会继续）
    }
    let segs: &[Segment] = world.segments(cx as u32, cz as u32);
    for (i, s) in segs.iter().enumerate() {
        let m = world.material(s.material);
        let blocks = match mode {
            RayMode::Sight => m.blocks_sight,
            RayMode::Projectile => m.blocks_bullet,
        };
        if !blocks {
            continue;
        }
        // 精确板式测试：起点在段内 / 从上方穿入 / 从下方穿入
        let inside0 = y0 >= s.bottom_mm && y0 <= s.top_mm;
        let cross_top = (y0 > s.top_mm && y1 <= s.top_mm) || (y1 > s.top_mm && y0 <= s.top_mm);
        let cross_bottom =
            (y0 < s.bottom_mm && y1 >= s.bottom_mm) || (y1 < s.bottom_mm && y0 >= s.bottom_mm);
        if inside0 || cross_top || cross_bottom {
            return Some(i as u32);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::mat;

    fn world_with_wall() -> World {
        // 8 格 = 4000 mm；格 (4,4) = x,z ∈ [2000, 2500]
        let mut w = World::new_flat(8, 4, -8000);
        w.push_segment(4, 4, Segment::new(0, 3000, mat::CONCRETE, 600));
        w
    }

    fn p(x: i32, y: i32, z: i32) -> Vec3 {
        Vec3::new(Mm(x), Mm(y), Mm(z))
    }

    #[test]
    fn directed_cases() {
        let w = world_with_wall();
        let cases: [(&str, Vec3, Vec3, bool); 12] = [
            ("正向穿墙", p(1000, 1500, 2250), p(3000, 1500, 2250), true),
            ("反向穿墙", p(3000, 1500, 2250), p(1000, 1500, 2250), true),
            ("起点在界外、穿墙", p(6000, 1500, 2250), p(1000, 1500, 2250), true),
            ("终点在界外", p(1000, 1500, 2250), p(9000, 1500, 2250), true),
            ("墙上方越过", p(1000, 4000, 2250), p(3000, 4000, 2250), false),
            ("绕开（z 偏移）", p(1000, 1500, 500), p(3000, 1500, 500), false),
            ("完全在界外", p(6000, 1500, 3500), p(9000, 1500, 3500), false),
            ("垂直向上（起点在地面上）", p(1000, 100, 1000), p(1000, 5000, 1000), false),
            ("垂直向上（起点在地面里）", p(1000, -100, 1000), p(1000, 5000, 1000), true),
            ("垂直向下入地", p(1000, 1500, 1000), p(1000, -5000, 1000), true),
            ("零长度（点在墙内）", p(2250, 1500, 2250), p(2250, 1500, 2250), true),
            ("轴对齐只走 Z", p(2250, 1500, 500), p(2250, 1500, 3000), true),
        ];
        for (name, a, b, expect) in cases {
            assert_eq!(
                blocked(&w, a, b, RayMode::Sight),
                expect,
                "用例「{name}」失败"
            );
        }
    }

    #[test]
    fn overhang_gap_is_walkable_and_shootable() {
        // 段之间有空隙 → 悬挑 / 桥下 / 窗洞
        let mut w = World::new(8, 4);
        w.push_segment(4, 4, Segment::new(0, 300, mat::CONCRETE, 600));
        w.push_segment(4, 4, Segment::new(2500, 2800, mat::CONCRETE, 600));
        assert!(
            !blocked(&w, p(1000, 1500, 2250), p(3000, 1500, 2250), RayMode::Sight),
            "空隙 [300, 2500] 必须能通过"
        );
        assert!(
            blocked(&w, p(1000, 2650, 2250), p(3000, 2650, 2250), RayMode::Sight),
            "桥面必须挡住"
        );
        assert!(
            blocked(&w, p(1000, 150, 2250), p(3000, 150, 2250), RayMode::Sight),
            "下段必须挡住"
        );
    }

    #[test]
    fn wire_blocks_move_but_not_sight_or_bullets() {
        let mut w = World::new(8, 4);
        w.push_segment(4, 4, Segment::new(0, 2000, mat::WIRE, 30));
        let a = p(1000, 1000, 2250);
        let b = p(3000, 1000, 2250);
        assert!(!blocked(&w, a, b, RayMode::Sight), "铁丝网不挡视线");
        assert!(!blocked(&w, a, b, RayMode::Projectile), "铁丝网不挡子弹");
        let solid = w.material(mat::WIRE).blocks_move;
        assert!(solid, "但人走不过去（由导航层处理）");
    }

    #[test]
    fn destroyed_wall_stops_blocking() {
        let mut w = world_with_wall();
        let a = p(1000, 1500, 2250);
        let b = p(3000, 1500, 2250);
        assert!(blocked(&w, a, b, RayMode::Sight));
        // 找到命中段并摧毁它（掩体"越打越没用"的几何基础）
        let hit = cast(&w, a, b, RayMode::Projectile).expect("应当命中");
        assert_eq!(hit.cell_x, 4);
        assert_eq!(hit.cell_z, 4);
        assert!(w.damage(hit.cell_x as u32, hit.cell_z as u32, hit.seg_index, 10000));
        assert!(!blocked(&w, a, b, RayMode::Sight), "墙没了就必须打得过去");
    }

    #[test]
    fn hit_point_lies_between_endpoints() {
        let w = world_with_wall();
        let a = p(1000, 1500, 2250);
        let b = p(3000, 1500, 2250);
        let hit = cast(&w, a, b, RayMode::Sight).expect("应当命中");
        let hp = hit_point(a, b, &hit);
        assert!(hp.x.0 >= a.x.0 && hp.x.0 <= b.x.0, "交点必须落在射线段内: {:?}", hp);
        assert!(hp.x.0 >= 2000 && hp.x.0 <= 2500, "交点应落在墙所在格: {:?}", hp);
    }

    #[test]
    fn corners_are_not_tunneled_through() {
        // 对角穿过"格的角点"时不能漏判：在 (2,2) 和 (3,3) 放两块，射线走对角线
        let mut w = World::new(8, 4);
        w.push_segment(2, 2, Segment::new(0, 3000, mat::CONCRETE, 600));
        w.push_segment(3, 3, Segment::new(0, 3000, mat::CONCRETE, 600));
        // 从 (1250,1500,1250) 到 (1750,1500,1750)：正好穿过格点 (1500,1500)
        assert!(
            blocked(&w, p(1250, 1500, 1250), p(1750, 1500, 1750), RayMode::Sight),
            "穿角点不得漏判"
        );
    }

    #[test]
    fn is_deterministic_across_repeated_runs() {
        let w = world_with_wall();
        let mut acc = 0u64;
        for _ in 0..3 {
            let mut h = 0u64;
            for i in 0..200 {
                let a = p(i * 17, 1500, i * 13);
                let b = p(3000 - i * 11, 1500, 3000 - i * 7);
                if let Some(hit) = cast(&w, a, b, RayMode::Sight) {
                    h = h.wrapping_add(hit.t_num as u64 ^ (hit.seg_index as u64) << 3);
                }
            }
            if acc == 0 {
                acc = h;
            } else {
                assert_eq!(acc, h, "重复运行结果必须一致");
            }
        }
    }
}
