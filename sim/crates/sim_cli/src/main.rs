//! `sim_cli` —— 无渲染的 headless 工具。
//!
//! 子命令：
//! - `bench`：性能基线（G1 门槛的输入）
//! - `nav`：400 个单位沿流场寻路（M0 的验收演示），含"炸开墙 → 重算 → 新通路"
//! - `worldcheck`：世界构建 + 射线自检 + 校验和（CI 冒烟用）
//!
//! 注意：这里可以用浮点与 `std::time`（不进 sim），但**任何影响模拟结果的输入都必须来自
//! 确定性 PRNG**，否则回放会分叉。

use sim_core::cover::{blocking_at, pick_cover, CoverField, Posture, Threat};
use sim_core::nav::{nearest_walkable, step_toward, FlowField, HeightField, NavParams};
use sim_core::ray::{blocked, RayMode};
use sim_core::world::{mat, Segment, World};
use sim_math::{isqrt_i64, Mm, Pcg32, Vec3};

const CELL: i64 = 500;

fn print_help() {
    println!(
        "用法：sim_cli <子命令> [选项]\n\
         \n\
         bench        性能基线：--units --ticks --rays --world --maxdist --seed\n\
         nav          400 单位沿流场寻路：--units --ticks --world --rebuild --breach --seed\n\
         worldcheck   世界构建 + 射线自检 + 校验和\n\
         cover        掩体派生 + 挨打会不会自己找掩体（§20.1.8 反脚本化）\n\
         \n\
         --maxdist 0 表示不限长（最坏情况）；掩体评分用 30000、感知用 80000。
         示例：sim_cli bench --units 400 --ticks 20000 --rays 4 --world 256 --maxdist 30000 --seed 1\n\
        示例：sim_cli nav --units 400 --ticks 6000 --world 256 --rebuild 15 --breach 1500 --seed 1\n\
        示例：sim_cli cover --world 256 --trials 200 --seed 1"
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
        "nav" => cmd_nav(&args),
        "worldcheck" => cmd_worldcheck(&args),
        "cover" => cmd_cover(&args),
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

/// 街区场景：成片建筑 + 院墙 + 残骸 —— M1 演示与掩体验收用。
///
/// 为什么不复用 `build_world`：那个生成器造的是**孤立单柱**（为射线 bench 服务的密度），
/// 里面没有成片的墙 ⇒ 所有掩体槽宽度都只有 1 柱（0.5 m），
/// 20 m 外一根柱子根本挡不住人 —— 拿它做掩体验收会得出"掩体没用"的错误结论。
fn build_city(rng: &mut Pcg32, dim_cells: u32) -> World {
    let mut w = World::new_flat(dim_cells, 32, -8000);
    let dim = dim_cells as i64;
    let put = |w: &mut World, x: i64, z: i64, s: Segment| {
        if x >= 0 && z >= 0 && x < dim && z < dim {
            w.push_segment(x as u32, z as u32, s);
        }
    };

    // 建筑：矩形块（4..13 柱 ≈ 2..6.5 m 宽），高 3..7.5 m；1/3 带窗洞
    let blocks = (dim / 16).max(4);
    for _ in 0..blocks {
        let bw = 4 + rng.next_range(9) as i64;
        let bd = 4 + rng.next_range(9) as i64;
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
    let walls = (dim / 24).max(3);
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
    for _ in 0..(dim / 32).max(2) {
        let x = rng.next_range(dim_cells) as i64;
        let z = rng.next_range(dim_cells) as i64;
        for dz in 0..2 {
            for dx in 0..2 {
                put(&mut w, x + dx, z + dz, Segment::new(0, 1200, mat::WRECK, 150));
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

/// FNV-1a：把单位位置压成一个校验和（跨平台逐位比对用，不进 sim 核心）。
fn checksum_positions(units: &[NavUnit]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for u in units {
        for v in [u.pos.0, u.pos.1] {
            for b in v.to_le_bytes() {
                h ^= b as u64;
                h = h.wrapping_mul(0x100_0000_01b3);
            }
        }
    }
    h
}

struct NavUnit {
    pos: (i64, i64),
    arrived_at: Option<u64>,
}

/// `nav`：400 个单位共用一个流场寻路 —— 这是 M0 的验收演示
/// （"sim_cli 跑 400 单位在体素世界寻路"）。
fn cmd_nav(args: &[String]) {
    let units_n = arg(args, "units", 400) as usize;
    let ticks = arg(args, "ticks", 6000) as u64;
    let dim = arg(args, "world", 256) as u32;
    let rebuild_every = arg(args, "rebuild", 15) as u64; // 流场重算周期（tick）
    let breach_at = arg(args, "breach", 0) as u64; // >0：在该 tick 炸开一堵墙
    let seed = arg(args, "seed", 1);
    let p = NavParams::default();
    let speed_mm_per_tick = 1500 / 30; // 步行 1.5 m/s（constants.ron 的 speed_walk_mmps）

    let mut rng = Pcg32::new(seed, 11);
    let mut world = build_world(&mut rng, dim);

    let t0 = std::time::Instant::now();
    let mut hf = HeightField::new(dim);
    hf.rebuild_all(&world, &p);
    let build_us = t0.elapsed().as_micros();

    let dim_i = dim as i64;
    let mut walkable_cells = 0u64;
    for cz in 0..dim {
        for cx in 0..dim {
            if hf.walkable(cx as i64, cz as i64) {
                walkable_cells += 1;
            }
        }
    }

    // 目标：对角（站不住就退化到最近可站立柱）
    let goal = nearest_walkable(&hf, dim_i - 2, dim_i - 2, 8).expect("地图上没有可站立的柱");
    let mut ff = FlowField::new(dim);
    let t1 = std::time::Instant::now();
    ff.compute(&hf, goal, &p, None);
    let first_field_us = t1.elapsed().as_micros();
    let reachable_before = ff.reached_cells();

    // 生成单位：在左上角区域随机撒在"可达"的柱上
    let mut units: Vec<NavUnit> = Vec::with_capacity(units_n);
    let spawn_span = (dim_i / 8).max(4);
    let mut guard = 0u32;
    while units.len() < units_n && guard < units_n as u32 * 64 {
        guard += 1;
        let cx = (rng.next_range(spawn_span as u32) as i64).min(dim_i - 1);
        let cz = (rng.next_range(spawn_span as u32) as i64).min(dim_i - 1);
        if !hf.walkable(cx, cz) || !ff.reachable(cx, cz) {
            continue;
        }
        units.push(NavUnit {
            pos: (cx * CELL + CELL / 2, cz * CELL + CELL / 2),
            arrived_at: None,
        });
    }
    let spawned = units.len();

    let mut samples: Vec<u64> = Vec::with_capacity(ticks as usize);
    let mut rebuild_us: Vec<u64> = Vec::new();
    let mut stuck_ticks: u64 = 0;
    let mut breached_at: Option<(u32, u32)> = None;
    let mut reachable_after = reachable_before;

    for t in 0..ticks {
        // 破坏演示：炸开一堵墙 → 高度场局部重建 → 流场重算 → 出现新通路
        if breach_at > 0 && t == breach_at {
            if let Some((cx, cz, idx)) = find_wall_segment(&world, dim) {
                if world.damage(cx, cz, idx, 6000) {
                    let (cx, cz) = (cx as i64, cz as i64);
                    hf.rebuild_area(&world, cx - 1, cz - 1, cx + 2, cz + 2, &p);
                    ff.compute(&hf, goal, &p, None);
                    reachable_after = ff.reached_cells();
                    breached_at = Some((cx as u32, cz as u32));
                }
            }
        }

        // 流场按周期重算（班组层 2 Hz）；成本与单位数无关
        if rebuild_every > 0 && t % rebuild_every == 0 && t > 0 {
            let r0 = std::time::Instant::now();
            ff.compute(&hf, goal, &p, None);
            rebuild_us.push(r0.elapsed().as_micros() as u64);
        }

        let t_start = std::time::Instant::now();
        for u in units.iter_mut() {
            if u.arrived_at.is_some() {
                continue;
            }
            let (cx, cz) = (u.pos.0 / CELL, u.pos.1 / CELL);
            if (cx, cz) == goal {
                u.arrived_at = Some(t);
                continue;
            }
            match ff.next_cell(cx, cz) {
                Some((nx, nz)) => {
                    let target = (nx * CELL + CELL / 2, nz * CELL + CELL / 2);
                    u.pos = step_toward(u.pos, target, speed_mm_per_tick);
                }
                None => {
                    stuck_ticks += 1; // 被围死（或流场半径外）
                }
            }
        }
        samples.push(t_start.elapsed().as_micros() as u64);
    }

    samples.sort_unstable();
    let pct = |p: f64| -> f64 {
        let i = ((samples.len() as f64) * p) as usize;
        samples[i.min(samples.len() - 1)] as f64
    };
    rebuild_us.sort_unstable();
    let rb = |p: f64| -> f64 {
        if rebuild_us.is_empty() {
            return 0.0;
        }
        let i = ((rebuild_us.len() as f64) * p) as usize;
        rebuild_us[i.min(rebuild_us.len() - 1)] as f64
    };

    let arrived = units.iter().filter(|u| u.arrived_at.is_some()).count();
    let arrive_sum: u64 = units
        .iter()
        .filter_map(|u| u.arrived_at)
        .sum();
    let arrive_max = units.iter().filter_map(|u| u.arrived_at).max().unwrap_or(0);

    println!("── sim_cli nav ──────────────────────────────");
    println!("世界        : {} 柱（{} m），{} 段", dim, dim_i * CELL / 1000, world.segment_count());
    println!("可站立柱    : {} / {}（{:.1}%）", walkable_cells,
             dim_i * dim_i, 100.0 * walkable_cells as f64 / (dim_i * dim_i) as f64);
    println!("目标柱      : {:?}；流场覆盖 {} 柱", goal, reachable_before);
    println!("高度场构建  : {} µs（全量）", build_us);
    println!("流场首次计算: {} µs；之后每 {} tick 重算一次：p50 {:.0} µs | p99 {:.0} µs（共 {} 次）",
             first_field_us, rebuild_every, rb(0.50), rb(0.99), rebuild_us.len());
    println!("单位        : {}（生成 {}；步行 {} mm/tick）", spawned, units_n, speed_mm_per_tick);
    println!("每 tick 移动: 平均 {:.1} µs | p50 {:.0} | p90 {:.0} | p99 {:.0} | max {}",
             samples.iter().sum::<u64>() as f64 / samples.len() as f64,
             pct(0.50), pct(0.90), pct(0.99), samples[samples.len() - 1]);
    println!("预算对照    : p99 {:.0} µs / 11000 µs（每 tick 预算）= {:.2}%",
             pct(0.99), 100.0 * pct(0.99) / 11000.0);
    println!("到达        : {} / {}，平均 {:.1} s，最长 {:.1} s",
             arrived, spawned,
             if arrived > 0 { arrive_sum as f64 / arrived as f64 / 30.0 } else { 0.0 },
             arrive_max as f64 / 30.0);
    println!("卡住        : {} 单位·tick（流场不可达；正常时应为 0）", stuck_ticks);
    match breached_at {
        Some((cx, cz)) => println!("破坏演示    : tick {} 炸开 ({}, {}) → 流场覆盖 {} → {} 柱（新通路）",
                                   breach_at, cx, cz, reachable_before, reachable_after),
        None => println!("破坏演示    : 未触发（--breach 0）"),
    }
    println!("位置校验和  : 0x{:016X}（跨平台逐位比对用）", checksum_positions(&units));
}

/// 找一堵"能炸开且炸开有意义"的墙：混凝土、顶面在 2~3 m、且靠近地图中部。
fn find_wall_segment(world: &World, dim: u32) -> Option<(u32, u32, u32)> {
    let lo = dim / 2 - dim / 8;
    let hi = dim / 2 + dim / 8;
    for cx in lo..hi {
        for cz in 0..dim {
            let segs = world.segments(cx, cz);
            for (i, s) in segs.iter().enumerate() {
                if s.material == mat::CONCRETE && s.top_mm >= 2000 && s.top_mm <= 3000 {
                    return Some((cx, cz, i as u32));
                }
            }
        }
    }
    None
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

#[cfg(test)]
mod tests {
    use super::{isqrt_i64, truncate_ray};
    use crate::{Mm, Vec3};

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

}

/// 贴墙滑行：直线走不通就只走 x / 只走 z（本地转向的最小实现，
/// 长距离仍走班组流场 —— 见冻结表 §6.2）。
fn steer_to(
    hf: &HeightField,
    p: &NavParams,
    pos: (i64, i64),
    target: (i64, i64),
    step_mm: i64,
) -> (i64, i64) {
    let cell = |x: i64, z: i64| (x / CELL, z / CELL);
    let cand = step_toward(pos, target, step_mm);
    let fc = cell(pos.0, pos.1);
    let tc = cell(cand.0, cand.1);
    if fc == tc || hf.can_step(fc.0, fc.1, tc.0, tc.1, p) {
        return cand;
    }
    let try_x = (cand.0, pos.1);
    let txc = cell(try_x.0, try_x.1);
    if hf.can_step(fc.0, fc.1, txc.0, txc.1, p) {
        return try_x;
    }
    let try_z = (pos.0, cand.1);
    let tzc = cell(try_z.0, try_z.1);
    if hf.can_step(fc.0, fc.1, tzc.0, tzc.1, p) {
        return try_z;
    }
    pos
}

/// `cover`：掩体派生 + 反脚本化验证（§20.1.8）。
///
/// 场景里**没有任何手工掩体标记**，槽位全部从体素几何算出。
/// 每个 trial：随机放 1 个士兵 + 1 个敌人，敌人开火（视为一个 Threat），
/// 士兵按 5 Hz 重新选槽并走过去，3 秒后看他的遮挡度是否 ≥ 0.7。
fn cmd_cover(args: &[String]) {
    let dim = arg(args, "world", 256) as u32;
    let trials = arg(args, "trials", 200) as u32;
    let seed = arg(args, "seed", 1);
    let p = NavParams::default();
    let cover_period = 6u64; // 5 Hz（constants.ron 的 time.cover_period）
    let ticks_3s = 90u64;
    let step_mm = 50i64; // 1.5 m/s ÷ 30 Hz

    let mut rng = Pcg32::new(seed, 11);
    let world = build_city(&mut rng, dim);

    let t0 = std::time::Instant::now();
    let mut hf = HeightField::new(dim);
    hf.rebuild_all(&world, &p);
    let hf_us = t0.elapsed().as_micros();

    let t1 = std::time::Instant::now();
    let mut field = CoverField::new();
    field.rebuild_all(&world, &hf);
    let cover_us = t1.elapsed().as_micros();

    // ── 槽位统计 ──
    let mut by_kind = [0u64; 7];
    let mut hsum = 0i64;
    let mut wsum = 0i64;
    for s in field.slots.iter() {
        by_kind[s.kind as usize] += 1;
        hsum += s.height_mm as i64;
        wsum += s.width_mm as i64;
    }
    let kind_name = |k: usize| match k {
        0 => "战壕",
        1 => "矮墙",
        2 => "高墙",
        3 => "转角",
        4 => "窗洞",
        5 => "残骸",
        _ => "窄柱",
    };

    println!("── sim_cli cover ──────────────────────────────");
    println!("世界: {dim}×{dim} 柱（{} m 见方）", dim as i64 * CELL / 1000);
    println!("高度场重建: {hf_us} µs");
    println!("掩体派生:   {cover_us} µs  →  {} 个槽", field.len());
    if !field.is_empty() {
        println!(
            "平均: 高 {} mm / 宽 {} mm",
            hsum / field.len() as i64,
            wsum / field.len() as i64
        );
    }
    for k in 0..7 {
        if by_kind[k] > 0 {
            println!("  {:<4} {:>7}", kind_name(k), by_kind[k]);
        }
    }
    println!("掩体场校验和: 0x{:016X}", field.checksum());

    // ── 反脚本化验证（§20.1.8）──
    let dim_i = dim as i64;
    let mut reached = 0u32;
    let mut evaluated = 0u32;
    let mut scrape: Vec<u32> = Vec::new();
    let t2 = std::time::Instant::now();
    for _ in 0..trials {
        // 随机士兵位置：**地面层**（楼顶也是可站立的，但站在楼顶没有掩体可躲，
        // 那种 trial 考的不是掩体系统）
        let (ux, uz) = loop {
            let x = rng.next_range(dim) as i64;
            let z = rng.next_range(dim) as i64;
            if hf.walk_top(x, z) == Some(0) {
                break (x, z);
            }
        };
        // 随机敌人：8..40 m 之外，同样在地面层
        let (ex, ez) = loop {
            let x = rng.next_range(dim) as i64;
            let z = rng.next_range(dim) as i64;
            if hf.walk_top(x, z) != Some(0) {
                continue;
            }
            let d2 = (x - ux) * (x - ux) + (z - uz) * (z - uz);
            let d = isqrt_i64(d2);
            if d > 16 && d < 80 {
                break (x, z);
            }
        };
        let _ = dim_i;
        let threat = Threat {
            x_mm: (ex * CELL + CELL / 2) as i32,
            y_mm: hf.walk_top(ex, ez).unwrap_or(0),
            z_mm: (ez * CELL + CELL / 2) as i32,
            confidence: 65_535,
        };
        let mut pos = (ux * CELL + CELL / 2, uz * CELL + CELL / 2);
        let mut goal: Option<(i64, i64)> = None;
        for tick in 0..ticks_3s {
            // 5 Hz 重新选槽（constants.ron 的 time.cover_period），中间继续朝目标走
            if goal.is_none() || tick % cover_period == 0 {
                if let Some(c) = pick_cover(
                    &world,
                    &field,
                    pos.0,
                    pos.1,
                    Posture::Crouch,
                    &[threat],
                    12,
                    &mut scrape,
                ) {
                    if let Some(s) = field.slot(c.slot) {
                        goal = Some((s.center_x_mm(), s.center_z_mm()));
                    }
                }
            }
            if let Some(g) = goal {
                pos = steer_to(&hf, &p, pos, g, step_mm);
            }
        }
        evaluated += 1;
        let b = blocking_at(&world, &hf, pos.0, pos.1, Posture::Crouch, &[threat]);
        if b.0 >= 45_875 {
            // 0.7 × 65536
            reached += 1;
        }
    }
    let eval_us = t2.elapsed().as_micros();
    let pct = if evaluated > 0 {
        reached as f64 * 100.0 / evaluated as f64
    } else {
        0.0
    };
    println!();
    println!("反脚本化验证（§20.1.8）: {evaluated} 次随机遭遇");
    println!(
        "  3 秒内 blocking ≥ 0.7: {reached}/{evaluated} = {pct:.1}%   （目标 ≥ 95%）"
    );
    println!("  每 trial 平均 {} µs", eval_us / evaluated.max(1) as u128);
    // 给 CI 用的机器可读行（反脚本化验收门禁读这一行）
    println!("cover_rate_pct={pct:.1}");
    println!("───────────────────────────────────────────────");
}
