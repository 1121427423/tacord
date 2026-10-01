//! tacord 的 Godot 薄绑定（GDExtension）。
//!
//! **边界（A6）**：这一层只有"搬运 + 驱动"，没有任何规则逻辑。
//! 规则全部在 `sim_core`（不依赖 Godot，可在 headless 下跑测试与回放）。
//!
//! 单位换算只发生在这一层：**sim 内部一律毫米整数，Godot 世界单位 = 米（f32）**。
//! 时间也一样：sim 只按固定步长 1/30 s 前进，渲染帧率与它无关。

use godot::prelude::*;

use sim_core::nav::{nearest_walkable, step_toward, FlowField, HeightField, NavParams};
use sim_core::world::{mat, Segment, World};
use sim_math::Pcg32;

struct TacordExt;

#[gdextension]
unsafe impl ExtensionLibrary for TacordExt {}

const CELL_MM: i64 = 500;
const TICK_DT: f64 = 1.0 / 30.0;
/// 追帧上限（冻结参数表 §15）：落后太多时丢时间，绝不无限追帧（lockstep 下会雪崩）
const MAX_TICKS_PER_FRAME: i64 = 2;
/// 流场重算周期（15 tick = 2 Hz，班组层）
const FLOW_REBUILD: u64 = 15;

#[derive(GodotClass)]
#[class(base=Node3D)]
struct SimRoot {
    base: Base<Node3D>,
    world: World,
    hf: HeightField,
    ff: FlowField,
    units: Vec<(i64, i64)>,
    goal: (i64, i64),
    dim: u32,
    tick: u64,
    rng: Pcg32,
    /// 时间累加器（浮点只用于"这一帧要不要走一步"，不进 sim 状态）
    acc: f64,
    auto_advance: bool,
}

impl SimRoot {
    fn rebuild(&mut self, dim_cells: u32, units_n: usize, seed: u64) {
        let mut rng = Pcg32::new(seed, 11);
        let world = build_world(&mut rng, dim_cells);
        let p = NavParams::default();
        let mut hf = HeightField::new(dim_cells);
        hf.rebuild_all(&world, &p);
        let d = dim_cells as i64;
        let goal = nearest_walkable(&hf, d - 2, d - 2, 8).unwrap_or((d / 2, d / 2));
        let mut ff = FlowField::new(dim_cells);
        ff.compute(&hf, goal, &p, None);
        let mut units = Vec::with_capacity(units_n);
        let span = (d / 8).max(4);
        let mut guard = 0usize;
        while units.len() < units_n && guard < units_n * 64 {
            guard += 1;
            let cx = i64::from(rng.next_range(span as u32)).min(d - 1);
            let cz = i64::from(rng.next_range(span as u32)).min(d - 1);
            if !hf.walkable(cx, cz) || !ff.reachable(cx, cz) {
                continue;
            }
            units.push((cx * CELL_MM + CELL_MM / 2, cz * CELL_MM + CELL_MM / 2));
        }
        self.world = world;
        self.hf = hf;
        self.ff = ff;
        self.units = units;
        self.goal = goal;
        self.dim = dim_cells;
        self.tick = 0;
        self.rng = rng;
        self.acc = 0.0;
    }

    fn advance_inner(&mut self, delta: f64) {
        self.acc += delta;
        let mut n = 0i64;
        while self.acc >= TICK_DT && n < MAX_TICKS_PER_FRAME {
            self.acc -= TICK_DT;
            self.step();
            n += 1;
        }
        // 追不上就丢时间（渲染慢不能拖垮模拟节奏，更不能在 lockstep 下雪崩）
        if self.acc > TICK_DT * 4.0 {
            self.acc = 0.0;
        }
    }
}

#[godot_api]
impl INode3D for SimRoot {
    fn init(base: Base<Node3D>) -> Self {
        let dim = 64u32;
        let mut this = SimRoot {
            base,
            world: World::new(dim, 32),
            hf: HeightField::new(dim),
            ff: FlowField::new(dim),
            units: Vec::new(),
            goal: (0, 0),
            dim,
            tick: 0,
            rng: Pcg32::new(1, 11),
            acc: 0.0,
            auto_advance: true,
        };
        this.rebuild(dim, 400, 1);
        this
    }

    fn process(&mut self, delta: f64) {
        if !self.auto_advance {
            return;
        }
        self.advance_inner(delta);
    }
}

#[godot_api]
impl SimRoot {
    /// 重建世界（dim_cells 必须是 32 的倍数：chunk = 32 柱）
    #[func]
    fn reset(&mut self, dim_cells: i64, units_n: i64, seed: i64) {
        let dim = if dim_cells < 32 { 32 } else { dim_cells as u32 };
        let n = if units_n < 0 { 0 } else { units_n as usize };
        self.rebuild(dim, n, seed.max(0) as u64);
    }

    /// 由渲染帧驱动（内部按固定 1/30 s 步长前进，最多追 2 步）
    #[func]
    fn advance(&mut self, delta: f64) {
        self.advance_inner(delta);
    }

    /// 走一个固定步长（headless 测试与回放用这个，不经过时间累加器）
    #[func]
    fn step(&mut self) {
        if self.tick % FLOW_REBUILD == 0 && self.tick > 0 {
            self.ff.compute(&self.hf, self.goal, &NavParams::default(), None);
        }
        for u in self.units.iter_mut() {
            let (cx, cz) = (u.0 / CELL_MM, u.1 / CELL_MM);
            if (cx, cz) == self.goal {
                continue;
            }
            if let Some((nx, nz)) = self.ff.next_cell(cx, cz) {
                *u = step_toward(*u, (nx * CELL_MM + CELL_MM / 2, nz * CELL_MM + CELL_MM / 2), 50);
            }
        }
        self.tick += 1;
    }

    #[func]
    fn set_auto_advance(&mut self, on: bool) {
        self.auto_advance = on;
    }

    #[func]
    fn unit_count(&self) -> i64 {
        self.units.len() as i64
    }

    #[func]
    fn tick_count(&self) -> i64 {
        self.tick as i64
    }

    /// 第 i 个单位的**渲染位置**（米）。y 取该柱的可站立顶面 —— M0 阶段只是贴地。
    #[func]
    fn unit_position(&self, i: i64) -> Vector3 {
        let i = i as usize;
        if i >= self.units.len() {
            return Vector3::ZERO;
        }
        let (x, z) = self.units[i];
        let y = self.hf.walk_top(x / CELL_MM, z / CELL_MM).unwrap_or(0);
        Vector3::new(x as f32 / 1000.0, y as f32 / 1000.0, z as f32 / 1000.0)
    }

    /// 世界的确定性校验和（跨平台逐位比对用；Godot 的整数是 i64）
    #[func]
    fn world_checksum(&self) -> i64 {
        self.world.checksum() as i64
    }

    #[func]
    fn unit_position_checksum(&self) -> i64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for (x, z) in self.units.iter() {
            for v in [*x, *z] {
                for b in v.to_le_bytes() {
                    h ^= u64::from(b);
                    h = h.wrapping_mul(0x100_0000_01b3);
                }
            }
        }
        h as i64
    }

    #[func]
    fn segment_count(&self) -> i64 {
        self.world.segment_count() as i64
    }

    #[func]
    fn dim_cells(&self) -> i64 {
        i64::from(self.dim)
    }
}

/// 与 `sim_cli` 同一个程序化世界生成器（保证"命令行看到的"和"编辑器里看到的"是同一个世界）。
/// TODO(M1)：换成真实的地图加载；这个函数只用于 M0 演示与 bench。
fn build_world(rng: &mut Pcg32, dim_cells: u32) -> World {
    let mut w = World::new_flat(dim_cells, 32, -8000);
    let buildings = u64::from(dim_cells) * u64::from(dim_cells) / 400 + 8;
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
