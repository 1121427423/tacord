//! `sim_cli` —— 无渲染的 headless 工具。
//!
//! 子命令：
//! - `bench`：性能基线（G1 门槛的输入）
//! - `worldcheck`：世界构建 + 射线自检 + 校验和（CI 冒烟用）
//!
//! 注意：这里可以用浮点与 `std::time`（不进 sim），但**任何影响模拟结果的输入都必须来自
//! 确定性 PRNG**，否则回放会分叉。

use sim_core::ray::{blocked, RayMode};
use sim_core::world::{mat, Segment, World};
use sim_math::{Mm, Pcg32, Vec3};

const CELL: i64 = 500;

fn print_help() {
    println!(
        "用法：sim_cli <子命令> [选项]\n\
         \n\
         bench        性能基线：--units --ticks --rays --world --maxdist --seed\n\
         worldcheck   世界构建 + 射线自检 + 校验和\n\
         \n\
         --maxdist 0 表示不限长（最坏情况）；掩体评分用 30000、感知用 80000。
         示例：sim_cli bench --units 400 --ticks 20000 --rays 4 --world 256 --maxdist 30000 --seed 1"
    );
}

fn arg(args: &[String], name: &str, default: u64) -> u64 {
    args.iter()
        .position(|a| a == format!("--{}", name).as_str())
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("");
    match cmd {
        "bench" => cmd_bench(&args),
        "worldcheck" => cmd_worldcheck(&args),
        _ => print_help(),
    }
}

/// 造一个程序化测试世界：平地 + 随机建筑（实心块 / 带窗洞的墙 / 悬挑）。
fn build_world(rng: &mut Pcg32, dim_cells: u32) -> World {
    let mut w = World::new_flat(dim_cells, 32, -8000);
    let buildings = (dim_cells as u64 * dim_cells as u64) / 400 + 8; // 密度随面积缩放
    for _ in 0..buildings {
        let cx = rng.next_range(dim_cells);
        let cz = rng.next_range(dim_cells);
        match rng.next_range(3) {
            0 => {
                w.push_segment(cx, cz, Segment::new(0, 2500, mat::CONCRETE, 600));
            }
            1 => {
                w.push_segment(cx, cz, Segment::new(0, 900, mat::BRICK, 180));
                w.push_segment(cx, cz, Segment::new(1800, 3000, mat::BRICK, 180));
            }
            _ => {
                w.push_segment(cx, cz, Segment::new(0, 300, mat::CONCRETE, 600));
                w.push_segment(cx, cz, Segment::new(2500, 2800, mat::WOOD, 45));
            }
        }
    }
    w
}

struct Unit {
    pos: Vec3,
    vel: (i32, i32),
}

fn cmd_bench(args: &[String]) {
    let units_n = arg(args, "units", 400) as usize;
    let ticks = arg(args, "ticks", 20000) as u64;
    let rays_per_tick = arg(args, "rays", 4) as usize;
    // 射线长度上限（mm，0 = 不限）。真实负载里射线按用途限长：
    // 掩体评分 ≤30m、感知 LOS ≤80m（冻结参数表 §4/§15 的 LOD 距离）。
    let maxdist_mm = arg(args, "maxdist", 0) as i32;
    let dim = arg(args, "world", 256) as u32;
    let seed = arg(args, "seed", 1);

    let mut rng = Pcg32::new(seed, 7);
    let world = build_world(&mut rng, dim);
    let size_mm = (dim as i64) * CELL;

    let mut units = Vec::with_capacity(units_n);
    for _ in 0..units_n {
        let x = rng.next_range(size_mm as u32) as i32;
        let z = rng.next_range(size_mm as u32) as i32;
        let vx = (rng.next_range(2000) as i32) - 1000; // ±1 m/s
        let vz = (rng.next_range(2000) as i32) - 1000;
        units.push(Unit {
            pos: Vec3::new(Mm(x), Mm(1700), Mm(z)),
            vel: (vx, vz),
        });
    }

    // 目标点：静态点集（模拟"对已知威胁做遮挡判定"）。
    // 目标点取全图随机，发射前按 maxdist 截断，于是"长度分布"由 maxdist 控制、
    // 方向仍是全向的（比"只打近处目标"更接近真实：威胁方向本来就是全向的）。
    let targets: Vec<Vec3> = (0..64)
        .map(|_| {
            Vec3::new(
                Mm(rng.next_range(size_mm as u32) as i32),
                Mm(1200),
                Mm(rng.next_range(size_mm as u32) as i32),
            )
        })
        .collect();

    let mut samples: Vec<u64> = Vec::with_capacity(ticks as usize);
    let mut rays_total: u64 = 0;
    let mut hit_count: u64 = 0;
    let mut degenerate: u64 = 0;

    for _tick in 0..ticks {
        let t0 = std::time::Instant::now();
        for u in units.iter_mut() {
            // 移动（1 tick = 1/30 s；速度单位 mm/s → mm/tick = v/30）
            let nx = u.pos.x.0 + u.vel.0 / 30;
            let nz = u.pos.z.0 + u.vel.1 / 30;
            if nx < 0 || nx >= size_mm as i32 {
                u.vel.0 = -u.vel.0;
            } else {
                u.pos.x.0 = nx;
            }
            if nz < 0 || nz >= size_mm as i32 {
                u.vel.1 = -u.vel.1;
            } else {
                u.pos.z.0 = nz;
            }
            // 射线：模拟"感知 + 掩体评估"的射线负载
            for _ in 0..rays_per_tick {
                let t = targets[(rng.next_u32() as usize) % targets.len()];
                let eye = Vec3::new(u.pos.x, Mm(1650), u.pos.z);
                let t = truncate_ray(eye, t, maxdist_mm);
                if t == eye {
                    degenerate += 1; // 截断把射线砍成 0 长度 = bug，必须显示在输出里
                }
                if blocked(&world, eye, t, RayMode::Sight) {
                    hit_count += 1;
                }
                rays_total += 1;
            }
        }
        samples.push(t0.elapsed().as_nanos() as u64);
    }

    samples.sort_unstable();
    let pct = |p: f64| -> f64 {
        let i = ((samples.len() as f64) * p) as usize;
        samples[i.min(samples.len() - 1)] as f64 / 1000.0 // µs
    };
    let sum: u64 = samples.iter().sum();
    let avg = sum as f64 / samples.len() as f64 / 1000.0;

    println!("── sim_cli bench ─────────────────────────────");
    println!("世界        : {} 柱（{} m），{} 段", dim, size_mm / 1000, world.segment_count());
    println!("单位        : {}", units_n);
    println!("tick 数     : {}", ticks);
    println!("射线/tick   : {}（合计 {}）", rays_per_tick, rays_total);
    if maxdist_mm > 0 {
        println!("射线长度上限: {} m", maxdist_mm / 1000);
    }
    println!("命中率      : {:.1}%", 100.0 * hit_count as f64 / rays_total as f64);
    println!("退化射线    : {}（截断把射线砍成 0 长度的数量，必须恒为 0）", degenerate);
    println!("每 tick 耗时: 平均 {:.1} µs | p50 {:.1} | p90 {:.1} | p99 {:.1} | max {:.1}",
             avg, pct(0.50), pct(0.90), pct(0.99),
             samples[samples.len() - 1] as f64 / 1000.0);
    let rays_per_s = rays_total as f64 / (sum as f64 / 1e9);
    println!("射线吞吐    : {:.0} ray/s（{:.2} M ray/s，单条 {:.2} µs）",
             rays_per_s, rays_per_s / 1e6,
             sum as f64 / 1000.0 / rays_total as f64);
    println!("预算对照    : p99 {:.1} µs / 11000 µs（每 tick 预算）= {:.2}%",
             pct(0.99), 100.0 * pct(0.99) / 11000.0);
    println!("世界校验和  : 0x{:016X}", world.checksum());
    println!("（注意：这是纯射线负载的基线，尚未包含 AI 决策与掩体评分）");
}

fn cmd_worldcheck(args: &[String]) {
    let dim = arg(args, "world", 64) as u32;
    let mut rng = Pcg32::new(42, 3);
    let mut w = build_world(&mut rng, dim);
    let size_mm = (dim as i64) * CELL;

    // 射线自检：从随机点对随机目标
    let mut blocked_n = 0;
    let n = 2000u32;
    for _ in 0..n {
        let a = Vec3::new(
            Mm(rng.next_range(size_mm as u32) as i32),
            Mm(1650),
            Mm(rng.next_range(size_mm as u32) as i32),
        );
        let b = Vec3::new(
            Mm(rng.next_range(size_mm as u32) as i32),
            Mm(1200),
            Mm(rng.next_range(size_mm as u32) as i32),
        );
        if blocked(&w, a, b, RayMode::Sight) {
            blocked_n += 1;
        }
    }

    // 破坏管线：打掉一段，确认脏队列与校验和都变了
    let before = w.checksum();
    let mut destroyed = 0;
    'outer: for cx in 0..dim {
        for cz in 0..dim {
            // 先拷出索引与材质再改（否则 &world 与 &mut world 借用冲突）
            let snapshot: Vec<(usize, u16)> = w
                .segments(cx, cz)
                .iter()
                .enumerate()
                .map(|(i, s)| (i, s.material))
                .collect();
            for (i, m) in snapshot {
                if m == mat::WOOD && w.damage(cx, cz, i as u32, 1000) {
                    destroyed += 1;
                }
                if destroyed >= 4 {
                    break 'outer;
                }
            }
        }
    }
    let after = w.checksum();
    let dirty = w.take_dirty(1000).len();

    println!("── sim_cli worldcheck ────────────────────────");
    println!("世界        : {} 柱（{} m），{} 段", dim, size_mm / 1000, w.segment_count());
    println!("射线自检    : {} 条，阻挡 {}", n, blocked_n);
    println!("破坏        : 摧毁 {} 段，脏 chunk {} 个", destroyed, dirty);
    println!("校验和      : 0x{:016X} → 0x{:016X}（{}）",
             before, after, if before == after { "未变，异常！" } else { "已变，正常" });
    assert_ne!(before, after, "破坏后校验和必须变化");
    println!("OK");
}

/// 把射线 `from -> to` 截断到 `maxdist_mm`（0 = 不截断）。
///
/// 用 Q20 定点缩放而不是整数除：整数除 `k = maxdist / len` 在 len > maxdist 时会得到 0，
/// 把射线砍成零长度（曾经让 30m 用例的"命中率"变成 0.8%，成本假性降到 0.19 µs/条）。
fn truncate_ray(from: Vec3, to: Vec3, maxdist_mm: i32) -> Vec3 {
    if maxdist_mm <= 0 {
        return to;
    }
    let dx = i64::from(to.x.0) - i64::from(from.x.0);
    let dy = i64::from(to.y.0) - i64::from(from.y.0);
    let dz = i64::from(to.z.0) - i64::from(from.z.0);
    let len2 = dx * dx + dy * dy + dz * dz;
    let lim2 = i64::from(maxdist_mm) * i64::from(maxdist_mm);
    if len2 <= lim2 {
        return to;
    }
    let len = isqrt_i64(len2).max(1);
    // scale < 2^20（因为 len > maxdist），dx * scale 不会溢出 i64
    let scale = (i64::from(maxdist_mm) << 20) / len;
    Vec3::new(
        Mm(from.x.0 + ((dx * scale) >> 20) as i32),
        Mm(from.y.0 + ((dy * scale) >> 20) as i32),
        Mm(from.z.0 + ((dz * scale) >> 20) as i32),
    )
}

/// 整数平方根（牛顿法）。只用于 bench 的长度截断，不进 sim 核心（sim 核心不用浮点）。
fn isqrt_i64(n: i64) -> i64 {
    if n <= 0 {
        return 0;
    }
    let mut x = n;
    let mut y = (x + 1) / 2;
    while y < x {
        x = y;
        y = (x + n / x) / 2;
    }
    x
}

#[cfg(test)]
mod tests {
    use super::{isqrt_i64, truncate_ray};

    fn len_of(a: Vec3, b: Vec3) -> i64 {
        let dx = i64::from(b.x.0) - i64::from(a.x.0);
        let dy = i64::from(b.y.0) - i64::from(a.y.0);
        let dz = i64::from(b.z.0) - i64::from(a.z.0);
        isqrt_i64(dx * dx + dy * dy + dz * dz)
    }

    #[test]
    fn truncate_shortens_to_the_limit_without_collapsing() {
        let from = Vec3::new(Mm(0), Mm(1650), Mm(0));
        // 90m 的射线截断到 30m：长度必须 ≈30000mm（定点误差 < 1cm），绝不能是 0
        let to = Vec3::new(Mm(90_000), Mm(1650), Mm(0));
        let t = truncate_ray(from, to, 30_000);
        assert!((len_of(from, t) - 30_000).abs() < 10, "len = {}", len_of(from, t));
        assert_eq!(t.y.0, 1650);

        // 斜向也要保持方向（x:z = 3:4）
        let to = Vec3::new(Mm(30_000), Mm(1650), Mm(40_000)); // 50m
        let t = truncate_ray(from, to, 10_000);
        assert!((len_of(from, t) - 10_000).abs() < 10, "len = {}", len_of(from, t));
        assert!((t.x.0 * 4 - t.z.0 * 3).abs() < 10, "方向被截断改变了");

        // 比上限短：原样返回
        assert_eq!(truncate_ray(from, Vec3::new(Mm(1000), Mm(1650), Mm(0)), 30_000).x.0, 1000);
        // 0 = 不截断
        assert_eq!(truncate_ray(from, to, 0), to);
    }

    #[test]
    fn isqrt_matches_known_values() {
        assert_eq!(isqrt_i64(0), 0);
        assert_eq!(isqrt_i64(1), 1);
        assert_eq!(isqrt_i64(15), 3);
        assert_eq!(isqrt_i64(16), 4);
        assert_eq!(isqrt_i64(1_000_000), 1000);
        assert_eq!(isqrt_i64(1_000_000_000_000), 1_000_000);
    }
}
