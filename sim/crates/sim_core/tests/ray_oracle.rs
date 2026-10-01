//! DDA 射线 vs 密集采样 oracle（属性测试）。
//!
//! oracle 是"沿射线采 N 个点，任一点落在实体段内即阻挡"。
//! 采样是**离散**的，遇到刀刃型擦边（射线正好切过 voxel 的一角）会漏判，
//! 所以当 oracle 说"通畅"而 DDA 说"阻挡"时，逐次加密采样复核 —— 若加密后一致则接受。
//! （反过来不行：加密采样无法消除一个已经被采样命中的点。）
//!
//! 全过程用确定性 PRNG（`sim_math::Pcg32`），所以测试可复现、不 flaky。

use sim_core::ray::{blocked, RayMode};
use sim_core::world::{mat, Segment, World};
use sim_math::{Mm, Pcg32, Vec3};

const CELL: i64 = 500;

fn brute_blocked(w: &World, a: Vec3, b: Vec3, n: u64, mode: RayMode) -> bool {
    let ax = a.x.0 as i64;
    let ay = a.y.0 as i64;
    let az = a.z.0 as i64;
    let bx = b.x.0 as i64;
    let by = b.y.0 as i64;
    let bz = b.z.0 as i64;
    for i in 0..=n {
        let t = i as f64 / n as f64; // oracle 只在测试里用浮点，不进 sim
        let x = (ax as f64 + (bx - ax) as f64 * t) as i64;
        let y = (ay as f64 + (by - ay) as f64 * t) as i64;
        let z = (az as f64 + (bz - az) as f64 * t) as i64;
        let cx = x.div_euclid(CELL);
        let cz = z.div_euclid(CELL);
        if cx < 0 || cz < 0 || cx >= w.dim_cells as i64 || cz >= w.dim_cells as i64 {
            continue;
        }
        for s in w.segments(cx as u32, cz as u32) {
            let m = w.material(s.material);
            let blocks = match mode {
                RayMode::Sight => m.blocks_sight,
                RayMode::Projectile => m.blocks_bullet,
            };
            if blocks && y >= s.bottom_mm as i64 && y <= s.top_mm as i64 {
                return true;
            }
        }
    }
    false
}

fn rand_range(rng: &mut Pcg32, lo: i64, hi: i64) -> i64 {
    let span = (hi - lo) as u64;
    lo + rng.next_range(span as u32) as i64
}

fn build_random_world(rng: &mut Pcg32, dim: u32) -> World {
    let mut w = World::new_flat(dim, 4, -8000);
    let n = 4 + rng.next_range(10) as usize;
    for _ in 0..n {
        let cx = rng.next_range(dim) as u32;
        let cz = rng.next_range(dim) as u32;
        match rng.next_range(3) {
            0 => {
                // 实心块
                let h = [1000, 2500, 5000][rng.next_range(3) as usize];
                w.push_segment(cx, cz, Segment::new(0, h, mat::CONCRETE, 600));
            }
            1 => {
                // 带窗洞的墙（两段 + 空隙）
                w.push_segment(cx, cz, Segment::new(0, 900, mat::BRICK, 180));
                w.push_segment(cx, cz, Segment::new(1800, 3000, mat::BRICK, 180));
            }
            _ => {
                // 悬挑 / 桥（上下两段，中间空）
                w.push_segment(cx, cz, Segment::new(0, 300, mat::CONCRETE, 600));
                w.push_segment(cx, cz, Segment::new(2500, 2800, mat::WOOD, 45));
            }
        }
    }
    w
}

#[test]
fn dda_matches_dense_sampling_oracle() {
    let mut rng = Pcg32::new(0xDEAD_BEEF, 11);
    let dim = 32u32;
    let mut rays = 0u32;
    let mut blocked_count = 0u32;
    let mut escalations = 0u32;

    for _ in 0..16 {
        let w = build_random_world(&mut rng, dim);
        let hi = (dim as i64) * CELL;
        for _ in 0..30 {
            // 有意让部分端点落在世界外，覆盖"射线从界外进入"的分支
            let a = Vec3::new(
                Mm(rand_range(&mut rng, -1500, hi + 1500) as i32),
                Mm(rand_range(&mut rng, -3000, 6000) as i32),
                Mm(rand_range(&mut rng, -1500, hi + 1500) as i32),
            );
            let b = Vec3::new(
                Mm(rand_range(&mut rng, -1500, hi + 1500) as i32),
                Mm(rand_range(&mut rng, -3000, 6000) as i32),
                Mm(rand_range(&mut rng, -1500, hi + 1500) as i32),
            );
            let dda = blocked(&w, a, b, RayMode::Sight);
            let mut n = 2000u64;
            let mut oracle = brute_blocked(&w, a, b, n, RayMode::Sight);
            // oracle 说通畅但 DDA 说阻挡 → 可能是采样漏判，加密复核
            while !oracle && dda && n < 500_000 {
                n *= 5;
                escalations += 1;
                oracle = brute_blocked(&w, a, b, n, RayMode::Sight);
            }
            assert_eq!(
                dda, oracle,
                "DDA 与 oracle 不一致：A={:?} B={:?}（采样数 {}）",
                a, b, n
            );
            rays += 1;
            if dda {
                blocked_count += 1;
            }
        }
    }
    // 防止测试退化成"全是通畅"（那样等于没测）
    assert!(blocked_count > 20 && rays - blocked_count > 20,
        "样本分布不合理：阻挡 {} / 通畅 {}（应该两者都足够多）",
        blocked_count, rays - blocked_count);
    println!(
        "oracle 对比：{} 条射线，阻挡 {}，加密复核 {} 次",
        rays, blocked_count, escalations
    );
}

#[test]
fn wire_is_transparent_to_both_ray_modes() {
    let mut w = World::new(8, 4);
    w.push_segment(4, 4, Segment::new(0, 2000, mat::WIRE, 30));
    let a = Vec3::new(Mm(1000), Mm(1000), Mm(2250));
    let b = Vec3::new(Mm(3000), Mm(1000), Mm(2250));
    assert!(!blocked(&w, a, b, RayMode::Sight));
    assert!(!blocked(&w, a, b, RayMode::Projectile));
    assert!(!brute_blocked(&w, a, b, 2000, RayMode::Projectile));
}
