//! tacord 的 Godot 薄绑定（GDExtension）。
//!
//! **边界（A6）**：这一层只有"搬运 + 驱动"，没有任何规则逻辑。
//! 规则全部在 `sim_core`（不依赖 Godot，可在 headless 下跑测试与回放）。
//!
//! 单位换算只发生在这一层：**sim 内部一律毫米整数，Godot 世界单位 = 米（f32）**。
//! 时间也一样：sim 只按固定步长 1/30 s 前进，渲染帧率与它无关。
//!
//! M1-B 之后，单位 AI 与交战全部住在 `sim_core::engage`（`sim_cli engage`
//! 无渲染就能验收），这里只搬三样东西给渲染层：
//! - 场景里的墙（`wall_boxes`）；
//! - 每个士兵的状态 / 姿态 / 队伍 / HP / 弹药 / 压制（`unit_*`）；
//! - 飞在空中的子弹（`projectile_*`，曳光弹用）。
//! "谁打得中谁、掩体够不够、压制多少、弹药打没打完"一律在 `sim_core` 里算，
//! 这里一个判断都不做。

use godot::prelude::*;

use sim_core::engage::{engage_dry_count, Sim as EngageSim, HP_MAX};

struct TacordExt;

#[gdextension]
unsafe impl ExtensionLibrary for TacordExt {}

const CELL_MM: i64 = 500;
const TICK_DT: f64 = 1.0 / 30.0;
/// 追帧上限（§15）：落后太多时丢时间，绝不无限追帧（lockstep 下会雪崩）
const MAX_TICKS_PER_FRAME: i64 = 4;
const DEFAULT_DIM: u32 = 64;
const DEFAULT_UNITS: usize = 400;
const DEFAULT_SEED: u64 = 1;

#[derive(GodotClass)]
#[class(base=Node3D)]
struct SimRoot {
    base: Base<Node3D>,
    sim: EngageSim,
    /// 时间累加器（浮点只用于"这一帧要不要走一步"，不进 sim 状态）
    acc: f64,
    auto_advance: bool,
}

#[godot_api]
impl INode3D for SimRoot {
    fn init(base: Base<Node3D>) -> Self {
        SimRoot {
            base,
            sim: EngageSim::new(DEFAULT_DIM, DEFAULT_UNITS, DEFAULT_SEED),
            acc: 0.0,
            auto_advance: true,
        }
    }

    fn process(&mut self, delta: f64) {
        if !self.auto_advance {
            return;
        }
        self.acc += delta;
        let mut n = 0i64;
        while self.acc >= TICK_DT && n < MAX_TICKS_PER_FRAME {
            self.acc -= TICK_DT;
            self.sim.step();
            n += 1;
        }
        if self.acc > TICK_DT * 4.0 {
            self.acc = 0.0;
        }
    }
}

#[godot_api]
impl SimRoot {
    #[func]
    fn reset(&mut self, dim_cells: i64, units_n: i64, seed: i64) {
        let dim = if dim_cells <= 0 {
            DEFAULT_DIM
        } else {
            dim_cells as u32
        };
        let n = if units_n <= 0 {
            DEFAULT_UNITS
        } else {
            units_n as usize
        };
        self.sim = EngageSim::new(dim, n, seed.max(0) as u64);
        self.acc = 0.0;
    }

    /// 按渲染帧推进（内部按 1/30 s 固定步长，与帧率无关）
    #[func]
    fn advance(&mut self, delta: f64) {
        self.acc += delta;
        let mut n = 0i64;
        while self.acc >= TICK_DT && n < MAX_TICKS_PER_FRAME {
            self.acc -= TICK_DT;
            self.sim.step();
            n += 1;
        }
        if self.acc > TICK_DT * 4.0 {
            self.acc = 0.0;
        }
    }

    /// 走**一个** tick（测试与回放用：校验和必须只由 tick 数决定）
    #[func]
    fn step(&mut self) {
        self.sim.step();
    }

    #[func]
    fn set_auto_advance(&mut self, on: bool) {
        self.auto_advance = on;
    }

    // ───────────────────────── 规模与时间 ─────────────────────────

    #[func]
    fn unit_count(&self) -> i64 {
        self.sim.soldiers.len() as i64
    }

    #[func]
    fn tick_count(&self) -> i64 {
        self.sim.tick as i64
    }

    #[func]
    fn segment_count(&self) -> i64 {
        self.sim.world.segment_count() as i64
    }

    #[func]
    fn dim_cells(&self) -> i64 {
        i64::from(self.sim.dim)
    }

    // ───────────────────────── 士兵 ─────────────────────────

    /// 第 i 个单位的**渲染位置**（米）。y 取该柱的可站立顶面。
    #[func]
    fn unit_position(&self, i: i64) -> Vector3 {
        let i = i as usize;
        let Some(s) = self.sim.soldiers.get(i) else {
            return Vector3::ZERO;
        };
        let y = self.sim.ground_mm(s.x, s.z);
        Vector3::new(s.x as f32 / 1000.0, y as f32 / 1000.0, s.z as f32 / 1000.0)
    }

    /// 0 巡逻 / 1 冲掩体 / 2 在掩体里 / 3 倒地
    #[func]
    fn unit_state(&self, i: i64) -> i64 {
        self.sim
            .soldiers
            .get(i as usize)
            .map_or(0, |s| s.state.code())
    }

    /// 0 站 / 1 蹲 / 2 趴 / 3 爬（伤员）/ 4 探身 / 5 探头
    #[func]
    fn unit_posture(&self, i: i64) -> i64 {
        self.sim
            .soldiers
            .get(i as usize)
            .map_or(0, |s| s.posture.code())
    }

    /// 0 / 1 两班
    #[func]
    fn unit_team(&self, i: i64) -> i64 {
        self.sim
            .soldiers
            .get(i as usize)
            .map_or(0, |s| i64::from(s.team))
    }

    /// 剩余 HP（0..100，0 = 倒地）
    #[func]
    fn unit_hp(&self, i: i64) -> i64 {
        self.sim.soldiers.get(i as usize).map_or(0, |s| i64::from(s.hp))
    }

    /// 弹匣里还有几发
    #[func]
    fn unit_ammo(&self, i: i64) -> i64 {
        self.sim
            .soldiers
            .get(i as usize)
            .map_or(0, |s| i64::from(s.ammo_mag))
    }

    /// 备弹（弹匣外的）
    #[func]
    fn unit_spare(&self, i: i64) -> i64 {
        self.sim
            .soldiers
            .get(i as usize)
            .map_or(0, |s| i64::from(s.ammo_spare))
    }

    /// 压制（Q16：0 = 没事，65536 = 满）
    #[func]
    fn unit_supp(&self, i: i64) -> i64 {
        self.sim.soldiers.get(i as usize).map_or(0, |s| s.supp)
    }

    #[func]
    fn unit_down(&self, i: i64) -> bool {
        self.sim.soldiers.get(i as usize).map_or(true, |s| !s.alive())
    }

    #[func]
    fn hp_max(&self) -> i64 {
        i64::from(HP_MAX)
    }

    /// 在掩体里的人数
    #[func]
    fn in_cover_count(&self) -> i64 {
        self.sim.in_cover_count() as i64
    }

    /// 被钉住（压制 ≥ 0.60，不还击）的人数
    #[func]
    fn pinned_count(&self) -> i64 {
        self.sim.pinned_count() as i64
    }

    /// 倒地人数（M1-C 会接上救援链路）
    #[func]
    fn downed_count(&self) -> i64 {
        self.sim.downed_count() as i64
    }

    /// 弹药彻底打光的人数（"阵地沉寂"的量化）
    #[func]
    fn dry_count(&self) -> i64 {
        engage_dry_count(&self.sim) as i64
    }

    // ───────────────────────── 交战统计 ─────────────────────────

    #[func]
    fn shot_count(&self) -> i64 {
        self.sim.stats.shots as i64
    }

    #[func]
    fn hit_count(&self) -> i64 {
        self.sim.stats.hits as i64
    }

    /// 近失弹次数（压制来源）
    #[func]
    fn near_miss_count(&self) -> i64 {
        self.sim.stats.near_misses as i64
    }

    #[func]
    fn down_count(&self) -> i64 {
        self.sim.stats.downs as i64
    }

    /// 还有子弹在天上飞 = 正在交火
    #[func]
    fn under_fire(&self) -> bool {
        !self.sim.projectiles.is_empty()
    }

    // ───────────────────────── 子弹（曳光弹用）─────────────────────────

    #[func]
    fn projectile_count(&self) -> i64 {
        self.sim.projectiles.len() as i64
    }

    /// 第 i 发子弹这一 tick 飞过的线段（米）：`[px, py, pz, x, y, z]`。
    ///
    /// 为什么给线段而不是点：子弹一 tick 走 30 m，画成一个点会在墙里"闪现"，
    /// 画成线段才是"从这儿飞到那儿"（也正好是命中判定用的那一段）。
    #[func]
    fn projectile_segment(&self, i: i64) -> PackedFloat32Array {
        let mut out = PackedFloat32Array::new();
        let Some(p) = self.sim.projectiles.get(i as usize) else {
            return out;
        };
        out.push(p.px as f32 / 1000.0);
        out.push(p.py as f32 / 1000.0);
        out.push(p.pz as f32 / 1000.0);
        out.push(p.x as f32 / 1000.0);
        out.push(p.y as f32 / 1000.0);
        out.push(p.z as f32 / 1000.0);
        out
    }

    // ───────────────────────── 场景与校验和 ─────────────────────────

    /// 场景里的墙（渲染用）：每 6 个 float 一个盒子 —— 中心 xyz + 尺寸 xyz（米）。
    ///
    /// 地面段（`bottom_mm < 0`）不导出：另有一块地板，画了也是 z-fighting。
    #[func]
    fn wall_boxes(&self) -> PackedFloat32Array {
        let mut out = PackedFloat32Array::new();
        let dim = self.sim.dim;
        for cz in 0..dim {
            for cx in 0..dim {
                for s in self.sim.world.segments(cx, cz) {
                    if s.bottom_mm < 0 {
                        continue;
                    }
                    let w = f32::from(CELL_MM as i16) / 1000.0;
                    let h = (s.top_mm - s.bottom_mm) as f32 / 1000.0;
                    out.push((cx as f32 + 0.5) * w);
                    out.push((s.bottom_mm as f32 + s.top_mm as f32) / 2000.0);
                    out.push((cz as f32 + 0.5) * w);
                    out.push(w);
                    out.push(h);
                    out.push(w);
                }
            }
        }
        out
    }

    #[func]
    fn cover_slot_count(&self) -> i64 {
        self.sim.cover.len() as i64
    }

    #[func]
    fn cover_checksum(&self) -> i64 {
        self.sim.cover.checksum() as i64
    }

    #[func]
    fn world_checksum(&self) -> i64 {
        self.sim.world.checksum() as i64
    }

    #[func]
    fn unit_position_checksum(&self) -> i64 {
        self.sim.pos_checksum() as i64
    }

    /// 蓝方（team 1）的质心 —— 老接口留着：M1-A 的"机枪阵地"标记用它定位。
    #[func]
    fn threat_position(&self) -> Vector3 {
        let mut n = 0i64;
        let mut sx = 0i64;
        let mut sz = 0i64;
        for s in self.sim.soldiers.iter() {
            if s.team != 1 || !s.alive() {
                continue;
            }
            n += 1;
            sx += s.x;
            sz += s.z;
        }
        if n == 0 {
            return Vector3::ZERO;
        }
        Vector3::new(
            sx as f32 / n as f32 / 1000.0,
            0.0,
            sz as f32 / n as f32 / 1000.0,
        )
    }

    /// 每队还有多少人能打（HUD 用）
    #[func]
    fn team_alive(&self, team: i64) -> i64 {
        self.sim
            .soldiers
            .iter()
            .filter(|s| i64::from(s.team) == team && s.alive())
            .count() as i64
    }
}
