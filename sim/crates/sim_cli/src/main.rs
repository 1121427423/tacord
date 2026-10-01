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
         bench        性能基线：--units --ticks --rays --world --seed\n\
         worldcheck   世界构建 + 射线自检 + 校验和\n\
         \n\
         示例：sim_cli bench --units 400 --ticks 20000 --rays 4 --world 256 --seed 1"
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

    // 目标点：静态点集（模拟"对已知威胁做遮挡判定"）
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
    println!("命中率      : {:.1}%", 100.0 * hit_count as f64 / rays_total as f64);
    println!("每 tick 耗时: 平均 {:.1} µs | p50 {:.1} | p90 {:.1} | p99 {:.1} | max {:.1}",
             avg, pct(0.50), pct(0.90), pct(0.99),
             samples[samples.len() - 1] as f64 / 1000.0);
    println!("射线吞吐    : {:.2} M ray/s",
             rays_total as f64 / (sum as f64 / 1e9));
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
