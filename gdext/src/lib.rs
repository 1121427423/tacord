//! tacord 的 Godot 薄绑定（GDExtension）。
//!
//! **边界（A6）**：这一层只有"搬运 + 驱动"，没有任何规则逻辑。
//! 规则全部在 `sim_core`（不依赖 Godot，可在 headless 下跑测试与回放）。
//!
//! 单位换算只发生在这一层：**sim 内部一律毫米整数，Godot 世界单位 = 米（f32）**。
//! 时间也一样：sim 只按固定步长 1/30 s 前进，渲染帧率与它无关。
//!
//! M1-A（掩体派生 + 找掩体）接进来之后，这里多搬了三样东西：
//! - 场景里的墙（`wall_boxes`，渲染用）；
//! - 每个士兵"巡逻 / 冲掩体 / 在掩体里"的状态与姿态（`unit_state` / `unit_posture`）；
//! - 一挺演示用的机枪（`threat_position` / `fire`）。
//! "什么时候该找掩体、哪个槽更好、够不够藏住"全在 `sim_core::cover`，这里一个判断都不做。

use godot::prelude::*;

use sim_core::cover::{blocking_at, pick_cover, CoverField, Posture, Threat, COVER_OK_BLOCK};
use sim_core::gen::build_city;
use sim_core::nav::{nearest_walkable, step_toward, HeightField, NavParams};
use sim_core::world::World;
use sim_math::Pcg32;

struct TacordExt;

#[gdextension]
unsafe impl ExtensionLibrary for TacordExt {}

const CELL_MM: i64 = 500;
const TICK_DT: f64 = 1.0 / 30.0;
/// 追帧上限（冻结参数表 §15）：落后太多时丢时间，绝不无限追帧（lockstep 下会雪崩）
const MAX_TICKS_PER_FRAME: i64 = 2;
/// 掩体重评估周期（5 Hz = 6 tick，= `constants.ron` 的 `time.cover_period`）
const COVER_REEVAL: u64 = 6;
/// 每 tick 最多重评多少个单位。
///
/// 这是**预算封顶**而不是"每 6 tick 全员重评"：400 人同一 tick 一起选槽会把一帧
/// 顶到几十毫秒（浏览器里直接掉帧），而且人数一变成本就变。封顶之后成本与人数无关，
/// 代价是最坏情况要 400/16 = 25 tick（0.8 s）才轮完一圈 —— 真人也是这样，
/// 不是所有人同时反应过来。
const COVER_BUDGET: usize = 16;
/// 冲刺 / 巡逻速度（mm/tick）：3000 mm/s ÷ 30 Hz = 100；巡逻 1500 mm/s = 50
const RUSH_MM: i64 = 100;
const PATROL_MM: i64 = 50;
/// 到槽判定（mm）：差这么多就算到了（槽宽 800 mm，半格内都算站进去）
const ARRIVE_MM: i64 = 250;
/// 连续多少 tick 原地不动算"卡住"（撞墙绕不过去就换目标，别贴着墙磨）
const STUCK_TICKS: u32 = 45;
/// 钻进掩体之后至少蹲多久（tick）：枪一停就站起来不是真人
const HOLD_TICKS: u64 = 60;
/// 演示节奏：每 6 秒一个点射，点射持续 1.5 秒
const FIRE_PERIOD: u64 = 180;
const FIRE_BURST: u64 = 45;

// 士兵状态（给渲染用的编码，别在 GDScript 里另立一套）
const ST_PATROL: i64 = 0;
const ST_RUSH: i64 = 1;
const ST_HIDDEN: i64 = 2;

// 姿态编码
const PO_STAND: u64 = 0;
const PO_CROUCH: u64 = 1;
const PO_PRONE: u64 = 2;

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Patrol,
    Rush,
    Hidden,
}

struct Unit {
    x: i64,
    z: i64,
    state: State,
    /// 目标点（掩体槽中心或巡逻点），mm
    tx: i64,
    tz: i64,
    /// 已占用的槽索引（-1 = 没占）。
    ///
    /// 占用是真占：`pick_cover` 的 crowd 项读的就是 `CoverSlot.occupied`，
    /// 不登记的话 400 人会全挤在同一个"最近的能挡住的"槽上（画面里就是一坨）。
    slot: i32,
    /// 蹲到什么时候（tick）
    hold_until: u64,
    /// 下次可以重评的 tick（5 Hz 分频）
    next_eval: u64,
    stuck: u32,
    posture: u64,
}

#[derive(GodotClass)]
#[class(base=Node3D)]
struct SimRoot {
    base: Base<Node3D>,
    world: World,
    hf: HeightField,
    cover: CoverField,
    units: Vec<Unit>,
    /// 演示用的机枪位置（mm）
    mg: (i64, i64),
    /// 点射结束的 tick（< 当前 tick 就是没在打）
    fire_until: u64,
    shots: u64,
    auto_fire: bool,
    dim: u32,
    tick: u64,
    rng: Pcg32,
    /// 时间累加器（浮点只用于"这一帧要不要走一步"，不进 sim 状态）
    acc: f64,
    auto_advance: bool,
    scratch: Vec<u32>,
}

impl SimRoot {
    fn rebuild(&mut self, dim_cells: u32, units_n: usize, seed: u64) {
        let mut rng = Pcg32::new(seed, 11);
        let world = build_city(&mut rng, dim_cells);
        let p = NavParams::default();
        let mut hf = HeightField::new(dim_cells);
        hf.rebuild_all(&world, &p);
        let mut cover = CoverField::new();
        cover.rebuild_all(&world, &hf);
        let d = dim_cells as i64;

        // 机枪阵地：地图中心附近第一个能站人的地方
        let (mx, mz) = nearest_walkable(&hf, d / 2, d / 2, 12).unwrap_or((d / 2, d / 2));
        let mg = (mx * CELL_MM + CELL_MM / 2, mz * CELL_MM + CELL_MM / 2);

        // 士兵：撒在全图可站立的柱上，别贴脸生成（4 m 内直接被扫）
        let mut units = Vec::with_capacity(units_n);
        let mut guard = 0usize;
        while units.len() < units_n && guard < units_n * 64 {
            guard += 1;
            let cx = i64::from(rng.next_range(dim_cells));
            let cz = i64::from(rng.next_range(dim_cells));
            if !hf.walkable(cx, cz) {
                continue;
            }
            let x = cx * CELL_MM + CELL_MM / 2;
            let z = cz * CELL_MM + CELL_MM / 2;
            let dx = x - mg.0;
            let dz = z - mg.1;
            if dx * dx + dz * dz < 4_000 * 4_000 {
                continue;
            }
            units.push(Unit {
                x,
                z,
                state: State::Patrol,
                tx: x,
                tz: z,
                slot: -1,
                hold_until: 0,
                next_eval: 0,
                stuck: 0,
                posture: PO_STAND,
            });
        }
        // 巡逻目标：生成时先给一个，免得第一 tick 全都堆在原地
        for u in units.iter_mut() {
            let (px, pz) = self.pick_patrol_point((u.x, u.z));
            u.tx = px;
            u.tz = pz;
        }

        self.world = world;
        self.hf = hf;
        self.cover = cover;
        self.units = units;
        self.mg = mg;
        self.fire_until = 0;
        self.shots = 0;
        self.dim = dim_cells;
        self.tick = 0;
        self.rng = rng;
        self.acc = 0.0;
        self.scratch.clear();
    }

    /// 随机挑一个能站人的柱（巡逻用）。挑不到就原地不动（下一 tick 再试）。
    fn pick_patrol_point(&mut self, fallback: (i64, i64)) -> (i64, i64) {
        for _ in 0..32 {
            let cx = i64::from(self.rng.next_range(self.dim));
            let cz = i64::from(self.rng.next_range(self.dim));
            if self.hf.walkable(cx, cz) {
                return (cx * CELL_MM + CELL_MM / 2, cz * CELL_MM + CELL_MM / 2);
            }
        }
        fallback
    }

    fn can_stand(&self, x_mm: i64, z_mm: i64) -> bool {
        let (cx, cz) = (x_mm / CELL_MM, z_mm / CELL_MM);
        cx >= 0 && cz >= 0 && cx < self.dim as i64 && cz < self.dim as i64 && self.hf.walkable(cx, cz)
    }

    /// 一步移动：直冲，撞墙就沿墙滑（先试 x，再试 z，都不行就原地 —— 由 stuck 计数处理）
    fn slide(&self, x: i64, z: i64, tx: i64, tz: i64, step_mm: i64) -> (i64, i64) {
        let (nx, nz) = step_toward((x, z), (tx, tz), step_mm);
        if self.can_stand(nx, nz) {
            return (nx, nz);
        }
        if self.can_stand(nx, z) {
            return (nx, z);
        }
        if self.can_stand(x, nz) {
            return (x, nz);
        }
        (x, z)
    }

    /// 松开已占用的槽（`pick_cover` 的 crowd 项靠 `occupied` 分流，必须如实登记）
    fn release_slot(&mut self, i: usize) {
        let s = self.units[i].slot;
        if s >= 0 {
            if let Some(slot) = self.cover.slots.get_mut(s as usize) {
                slot.occupied = slot.occupied.saturating_sub(1);
            }
            self.units[i].slot = -1;
        }
    }

    /// 占一个新槽（先松开旧的）
    fn take_slot(&mut self, i: usize, slot_idx: u32) {
        self.release_slot(i);
        if let Some(slot) = self.cover.slots.get_mut(slot_idx as usize) {
            slot.occupied = slot.occupied.saturating_add(1);
            self.units[i].slot = slot_idx as i32;
        }
    }

    /// 挨打时的决策：就地藏得住就不动，藏不住就换一个够用的槽（取最近的）。
    fn think(&mut self, i: usize, threats: &[Threat]) {
        let (x, z, hidden, hold_until) = {
            let u = &self.units[i];
            (u.x, u.z, u.state == State::Hidden, u.hold_until)
        };
        // 已经藏好、且还没蹲够 → 别动（真人也不会在枪林弹雨里换姿势）
        if hidden && self.tick < hold_until {
            return;
        }
        // 就地一趴/一蹲就能挡住 → 不换地方
        //
        // 注意 `None` = "用这处掩体该用的姿态"（`blocking_at` 内部按槽类型取
        // `best_posture`），所以"藏得住"这句话天然包含了"他得趴下/蹲下"。
        if blocking_at(&self.world, &self.hf, x, z, None, threats).0 >= COVER_OK_BLOCK {
            self.release_slot(i);
            let u = &mut self.units[i];
            u.state = State::Hidden;
            u.hold_until = self.tick + HOLD_TICKS;
            u.posture = PO_PRONE;
            u.tx = x;
            u.tz = z;
            return;
        }
        // 挡不住 → 找掩体（pick_cover 内部：够用的里面挑最近的）
        let choice = pick_cover(
            &self.world,
            &self.cover,
            x,
            z,
            None,
            threats,
            12,
            &mut self.scratch,
        );
        if let Some(c) = choice {
            if let Some(s) = self.cover.slot(c.slot).copied() {
                let (tx, tz) = (s.center_x_mm(), s.center_z_mm());
                let posture = posture_code(s.kind.best_posture());
                self.take_slot(i, c.slot);
                let u = &mut self.units[i];
                u.state = State::Rush;
                u.tx = tx;
                u.tz = tz;
                u.slot = c.slot as i32;
                u.posture = posture; // 到了再摆这个姿势
                u.stuck = 0;
                return;
            }
        }
        // 找不到掩体：继续走（站着挨打和乱跑一样糟，但至少不会卡在原地）
        self.release_slot(i);
        let u = &mut self.units[i];
        u.state = State::Patrol;
        u.stuck = 0;
    }

    fn move_unit(&mut self, i: usize) {
        let (state, x, z, tx, tz) = {
            let u = &self.units[i];
            (u.state, u.x, u.z, u.tx, u.tz)
        };
        if state == State::Hidden {
            return;
        }
        let step_mm = if state == State::Rush {
            RUSH_MM
        } else {
            PATROL_MM
        };
        let (nx, nz) = self.slide(x, z, tx, tz, step_mm);
        let dx = tx - nx;
        let dz = tz - nz;
        let arrived = dx * dx + dz * dz <= ARRIVE_MM * ARRIVE_MM;
        let moved = nx != x || nz != z;

        let mut hide = false;
        let mut new_patrol = false;
        {
            let u = &mut self.units[i];
            u.x = nx;
            u.z = nz;
            if arrived {
                if state == State::Rush {
                    hide = true;
                } else {
                    new_patrol = true;
                }
            } else if !moved {
                u.stuck += 1;
                if u.stuck > STUCK_TICKS {
                    new_patrol = true;
                    u.stuck = 0;
                }
            }
        }
        if hide {
            let u = &mut self.units[i];
            u.state = State::Hidden;
            u.hold_until = self.tick + HOLD_TICKS;
        }
        if new_patrol {
            self.release_slot(i);
            let (px, pz) = self.pick_patrol_point((nx, nz));
            let u = &mut self.units[i];
            u.state = State::Patrol;
            u.posture = PO_STAND;
            u.tx = px;
            u.tz = pz;
            u.stuck = 0;
        }
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

fn posture_code(p: Posture) -> u64 {
    match p {
        Posture::Stand => PO_STAND,
        Posture::Crouch => PO_CROUCH,
        _ => PO_PRONE,
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
            cover: CoverField::new(),
            units: Vec::new(),
            mg: (dim as i64 * CELL_MM / 2, dim as i64 * CELL_MM / 2),
            fire_until: 0,
            shots: 0,
            auto_fire: true,
            dim,
            tick: 0,
            rng: Pcg32::new(1, 11),
            acc: 0.0,
            auto_advance: true,
            scratch: Vec::new(),
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
        // 演示节奏：定时点射（真正的交战判定在 M1-B，这里只提供"有人开枪"这个输入）
        if self.auto_fire && self.tick % FIRE_PERIOD == 0 {
            self.shots += 1;
            self.fire_until = self.tick + FIRE_BURST;
        }
        let firing = self.tick < self.fire_until;
        let threat = [Threat {
            x_mm: self.mg.0 as i32,
            y_mm: 0,
            z_mm: self.mg.1 as i32,
            confidence: 65_535,
        }];
        let threats: &[Threat] = if firing { &threat } else { &[] };

        // 1) 掩体决策（预算封顶 + 每单位 5 Hz）
        let n = self.units.len();
        if firing && n > 0 {
            let mut budget = COVER_BUDGET;
            let start = (self.tick as usize) % n;
            for k in 0..n {
                if budget == 0 {
                    break;
                }
                let i = (start + k) % n;
                if self.units[i].next_eval > self.tick {
                    continue;
                }
                self.units[i].next_eval = self.tick + COVER_REEVAL;
                budget -= 1;
                self.think(i, threats);
            }
        } else {
            // 枪停了 → 蹲够时间的站起来继续走
            for i in 0..n {
                let stand = self.units[i].state == State::Hidden && self.tick >= self.units[i].hold_until;
                if stand {
                    self.release_slot(i);
                    let (px, pz) = self.pick_patrol_point((self.units[i].x, self.units[i].z));
                    let u = &mut self.units[i];
                    u.state = State::Patrol;
                    u.posture = PO_STAND;
                    u.tx = px;
                    u.tz = pz;
                    u.stuck = 0;
                }
            }
        }

        // 2) 移动
        for i in 0..n {
            self.move_unit(i);
        }
        self.tick += 1;
    }

    #[func]
    fn set_auto_advance(&mut self, on: bool) {
        self.auto_advance = on;
    }

    /// 手动打一个点射（F 键）
    #[func]
    fn fire(&mut self) {
        self.shots += 1;
        self.fire_until = self.tick + FIRE_BURST;
    }

    #[func]
    fn set_auto_fire(&mut self, on: bool) {
        self.auto_fire = on;
    }

    #[func]
    fn under_fire(&self) -> bool {
        self.tick < self.fire_until
    }

    #[func]
    fn shot_count(&self) -> i64 {
        self.shots as i64
    }

    #[func]
    fn unit_count(&self) -> i64 {
        self.units.len() as i64
    }

    #[func]
    fn tick_count(&self) -> i64 {
        self.tick as i64
    }

    /// 第 i 个单位的**渲染位置**（米）。y 取该柱的可站立顶面。
    #[func]
    fn unit_position(&self, i: i64) -> Vector3 {
        let i = i as usize;
        if i >= self.units.len() {
            return Vector3::ZERO;
        }
        let (x, z) = (self.units[i].x, self.units[i].z);
        let y = self.hf.walk_top(x / CELL_MM, z / CELL_MM).unwrap_or(0);
        Vector3::new(x as f32 / 1000.0, y as f32 / 1000.0, z as f32 / 1000.0)
    }

    /// 0 巡逻 / 1 冲掩体 / 2 在掩体里
    #[func]
    fn unit_state(&self, i: i64) -> i64 {
        match self.units.get(i as usize) {
            Some(u) => match u.state {
                State::Patrol => ST_PATROL,
                State::Rush => ST_RUSH,
                State::Hidden => ST_HIDDEN,
            },
            None => ST_PATROL,
        }
    }

    /// 0 站 / 1 蹲 / 2 趴（`best_posture` 决定：矮墙趴、高墙蹲）
    #[func]
    fn unit_posture(&self, i: i64) -> i64 {
        self.units.get(i as usize).map_or(0, |u| u.posture as i64)
    }

    /// 已经钻进掩体的人数（HUD 用）
    #[func]
    fn in_cover_count(&self) -> i64 {
        self.units
            .iter()
            .filter(|u| u.state == State::Hidden)
            .count() as i64
    }

    /// 场景里的墙（渲染用）：每 6 个 float 一个盒子 —— 中心 xyz + 尺寸 xyz（米）。
    ///
    /// 地面段（`bottom_mm < 0`）不导出：另有一块地板，画了也是 z-fighting。
    #[func]
    fn wall_boxes(&self) -> PackedFloat32Array {
        let mut out = PackedFloat32Array::new();
        for cz in 0..self.dim {
            for cx in 0..self.dim {
                for s in self.world.segments(cx, cz) {
                    if s.bottom_mm < 0 || s.top_mm <= s.bottom_mm {
                        continue;
                    }
                    let y0 = f32::from(s.bottom_mm) / 1000.0;
                    let y1 = f32::from(s.top_mm) / 1000.0;
                    out.push(cx as f32 * 0.5 + 0.25);
                    out.push((y0 + y1) * 0.5);
                    out.push(cz as f32 * 0.5 + 0.25);
                    out.push(0.5);
                    out.push(y1 - y0);
                    out.push(0.5);
                }
            }
        }
        out
    }

    /// 演示用的机枪位置（米）
    #[func]
    fn threat_position(&self) -> Vector3 {
        let y = self
            .hf
            .walk_top(self.mg.0 / CELL_MM, self.mg.1 / CELL_MM)
            .unwrap_or(0);
        Vector3::new(
            self.mg.0 as f32 / 1000.0,
            y as f32 / 1000.0,
            self.mg.1 as f32 / 1000.0,
        )
    }

    #[func]
    fn cover_slot_count(&self) -> i64 {
        self.cover.len() as i64
    }

    #[func]
    fn cover_checksum(&self) -> i64 {
        self.cover.checksum() as i64
    }

    /// 世界的确定性校验和（跨平台逐位比对用；Godot 的整数是 i64）
    #[func]
    fn world_checksum(&self) -> i64 {
        self.world.checksum() as i64
    }

    #[func]
    fn unit_position_checksum(&self) -> i64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for u in self.units.iter() {
            for v in [u.x, u.z] {
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
