//! M1-B 单兵交战：开火 → 弹道 → 命中/近失 → 压制 → 弹药打光 → 阵地沉寂。
//!
//! 参数见设计文档 §6.3（派生值全部由 `constants.ron` 的源值推出，
//! `tools/check_constants.py` 会重算一遍），规则见 §30.3.2（逐点命中 / R3）
//! 与 §30.3.3（误差锥）。
//!
//! **三条硬规矩**（写错就要大返工）：
//!
//! 1. 子弹是**实体**：每 tick 走一段，用**线段**射线求交 —— 不是 hitscan
//!    （30 m/tick 下 hitscan 会穿墙，而墙是掩体的全部意义）。
//! 2. 命中是**几何求交**：误差锥 + 采样点球体 + `ray::cast`，
//!    **没有**"命中率查表" —— 查表会与掩体系统脱节，等于把 R3 白做。
//! 3. 弹道 / 视线 / 掩体评分三处共用 `ray::cast`，规则不可能出现分歧。
//!
//! 本块**不做**（留 M1-C / M2）：穿透与跳弹、摸尸补弹、伤员救援、感知记忆、
//! 威胁场。

use crate::cover::{blocking_at, pick_cover, CoverField, Posture, Threat, COVER_OK_BLOCK};
use crate::nav::{step_toward, HeightField, NavParams};
use crate::ray::{blocked, cast, hit_point, RayMode};
use crate::world::World;
use crate::CELL_MM;
use sim_math::{isqrt_i64, Mm, Pcg32, Vec3};

// ───────────────────────── 武器与弹道（§6.3.2）─────────────────────────

/// 步枪弹速：900 m/s ÷ 30 Hz（mm/tick）
pub const VEL_RIFLE_MMPT: i64 = 30_000;
/// 机枪弹速：850 m/s ÷ 30 Hz
pub const VEL_MG_MMPT: i64 = 28_333;
/// 步枪射速：600 rpm → 0.33333 发/tick
pub const RPT_RIFLE_Q16: i64 = 21_845;
/// 机枪射速：750 rpm → 0.41667 发/tick
pub const RPT_MG_Q16: i64 = 27_306;

pub const MAG_RIFLE: i32 = 30;
pub const SPARE_RIFLE: i32 = 180; // 6 个弹匣
pub const MAG_MG: i32 = 200;
pub const SPARE_MG: i32 = 100;
pub const RELOAD_TACTICAL_TICKS: u64 = 78; // 2600 ms
pub const RELOAD_EMPTY_TICKS: u64 = 96; // 3200 ms

/// 长点射发数：打满就停火冷却，之后退化为单发（P4）
pub const BURST_ROUNDS_RIFLE: u32 = 8;
pub const BURST_ROUNDS_MG: u32 = 20;
pub const BURST_COOLDOWN_RIFLE: u64 = 18;
pub const BURST_COOLDOWN_MG: u64 = 30;
/// 单发节奏（退化为单发后）
pub const SINGLE_SHOT_TICKS: u64 = 6;
/// 停火多久算"这次交火结束了"，回到连发模式
pub const BURST_RESET_TICKS: u64 = 45;

/// 散布（µrad；1 mrad = 1000 µrad）—— 初值，M1 末试玩后调
pub const CONE_BASE_URAD_RIFLE: i64 = 2_500;
pub const CONE_BASE_URAD_MG: i64 = 5_000;
pub const BLOOM_URAD_PER_ROUND: i64 = 400;
pub const BLOOM_MAX_MUL_Q16: i64 = 196_608; // ×3.0
pub const BLOOM_DECAY_URAD_PT: i64 = 800;

/// 压制（§7：τ = 120 tick，迟疑 0.30，钉住 0.60）
pub const SUPP_DECAY_Q16: i64 = 64_990;
pub const SUPP_HESITANT_Q16: i64 = 19_661;
pub const SUPP_PINNED_Q16: i64 = 39_322;
/// 近失弹压制：0.3 m → 0.55，1.5 m → 0.30（线性插值）
pub const NEAR_MISS_MM: i64 = 1_500;
pub const NEAR_MISS_MIN_MM: i64 = 300;
pub const SUPP_NEAR_MISS_MAX_Q16: i64 = 36_044; // 0.55
pub const SUPP_NEAR_MISS_MIN_Q16: i64 = 19_660; // 0.30

/// 基础伤害与部位系数（Q16：头 2.6 / 胸 1.0 / 腹 0.85 / 肢 0.45）
pub const DMG_RIFLE: i32 = 35;
pub const DMG_MG: i32 = 40;
pub const PART_HEAD_Q16: i64 = 170_394;
pub const PART_CHEST_Q16: i64 = 65_536;
pub const PART_GUT_Q16: i64 = 55_706;
pub const PART_LIMB_Q16: i64 = 29_491;

/// 命中判定半径（mm）
pub const HIT_R_HEAD_MM: i64 = 120;
pub const HIT_R_CHEST_MM: i64 = 200;
pub const HIT_R_GUT_MM: i64 = 200;
pub const HIT_R_LIMB_MM: i64 = 150;

pub const RANGE_RIFLE_MM: i64 = 400_000;
pub const RANGE_MG_MM: i64 = 800_000;
pub const MAX_PROJECTILES: usize = 4_096;

pub const HP_MAX: i32 = 100;

// ─────────────────── 姿态/移动的散布系数（§8 combat.coef_*）──────────────────

const COEF_STAND_Q16: i64 = 65_536; // 1.00
const COEF_CROUCH_Q16: i64 = 49_152; // 0.75
const COEF_PRONE_Q16: i64 = 36_044; // 0.55
const COEF_PEEK_Q16: i64 = 62_259; // 0.95
const COEF_PEEKOVER_Q16: i64 = 72_089; // 1.10
/// 移动对散布的贡献系数：cone × (1 + 0.9 × move_factor)
const MOVE_CONE_Q16: i64 = 58_982; // 0.9
const MOVE_PATROL_Q16: i64 = 32_768; // 走 0.5
const MOVE_RUSH_Q16: i64 = 65_536; // 跑 1.0
/// 压制对散布的贡献：cone × (1 + 1.5 × supp)
const SUPP_CONE_Q16: i64 = 98_304; // 1.5
/// 距离对散布的贡献：cone × (1 + 0.4 × d/range)
const DIST_CONE_Q16: i64 = 26_214; // 0.4

// ───────────────────────── 从 M1-A 搬过来的行为常量 ─────────────────────────

const PATROL_MM: i64 = 50;
const RUSH_MM: i64 = 100;
const ARRIVE_MM: i64 = 250;
const STUCK_TICKS: u32 = 45;
const HOLD_TICKS: u64 = 60;
const COVER_REEVAL: u64 = 6;
const COVER_BUDGET: usize = 16;
const FIRE_REEVAL: u64 = 6;
const FIRE_BUDGET: usize = 16;
/// 探身开火的时长与间隔（M1-B 新引入：藏在掩体里也得能还手）
const PEEK_TICKS: u64 = 24;
const PEEK_COOLDOWN_TICKS: u64 = 36;

// ───────────────────────── 数据 ─────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Weapon {
    Rifle,
    Mg,
}

impl Weapon {
    pub const fn vel_mmpt(self) -> i64 {
        match self {
            Weapon::Rifle => VEL_RIFLE_MMPT,
            Weapon::Mg => VEL_MG_MMPT,
        }
    }
    pub const fn rpt_q16(self) -> i64 {
        match self {
            Weapon::Rifle => RPT_RIFLE_Q16,
            Weapon::Mg => RPT_MG_Q16,
        }
    }
    pub const fn dmg(self) -> i32 {
        match self {
            Weapon::Rifle => DMG_RIFLE,
            Weapon::Mg => DMG_MG,
        }
    }
    pub const fn mag(self) -> i32 {
        match self {
            Weapon::Rifle => MAG_RIFLE,
            Weapon::Mg => MAG_MG,
        }
    }
    pub const fn burst_rounds(self) -> u32 {
        match self {
            Weapon::Rifle => BURST_ROUNDS_RIFLE,
            Weapon::Mg => BURST_ROUNDS_MG,
        }
    }
    pub const fn burst_cooldown(self) -> u64 {
        match self {
            Weapon::Rifle => BURST_COOLDOWN_RIFLE,
            Weapon::Mg => BURST_COOLDOWN_MG,
        }
    }
    pub const fn range_mm(self) -> i64 {
        match self {
            Weapon::Rifle => RANGE_RIFLE_MM,
            Weapon::Mg => RANGE_MG_MM,
        }
    }
}

/// 行为状态（与 M1-A 一致，M1-B 增加"倒地"）
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    /// 巡逻/走动
    Patrol,
    /// 冲向掩体
    Rush,
    /// 在掩体里（蹲够时间或探身开火）
    Hidden,
    /// 倒地（HP ≤ 0）：不动、不还击，等 M1-C 的救援链路
    Downed,
}

impl State {
    pub const fn code(self) -> i64 {
        match self {
            State::Patrol => 0,
            State::Rush => 1,
            State::Hidden => 2,
            State::Downed => 3,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PostureCode {
    Stand,
    Crouch,
    Prone,
    Crawl,
    Peek,
    PeekOver,
}

impl PostureCode {
    pub const fn code(self) -> i64 {
        match self {
            PostureCode::Stand => 0,
            PostureCode::Crouch => 1,
            PostureCode::Prone => 2,
            PostureCode::Crawl => 3,
            PostureCode::Peek => 4,
            PostureCode::PeekOver => 5,
        }
    }
    pub const fn to_cover(self) -> Posture {
        match self {
            PostureCode::Stand => Posture::Stand,
            PostureCode::Crouch => Posture::Crouch,
            PostureCode::Prone => Posture::Prone,
            PostureCode::Crawl => Posture::Crawl,
            PostureCode::Peek => Posture::Peek,
            PostureCode::PeekOver => Posture::PeekOver,
        }
    }
    pub const fn cone_q16(self) -> i64 {
        match self {
            PostureCode::Stand => COEF_STAND_Q16,
            PostureCode::Crouch => COEF_CROUCH_Q16,
            PostureCode::Prone => COEF_PRONE_Q16,
            PostureCode::Crawl => COEF_PRONE_Q16,
            PostureCode::Peek => COEF_PEEK_Q16,
            PostureCode::PeekOver => COEF_PEEKOVER_Q16,
        }
    }
    /// 姿态高度（渲染与"这一发打在哪个高度"都要用，mm）
    pub const fn height_mm(self) -> i64 {
        match self {
            PostureCode::Stand => 1_700,
            PostureCode::Crouch => 1_150,
            PostureCode::Prone => 450,
            PostureCode::Crawl => 350,
            PostureCode::Peek => 1_300,
            PostureCode::PeekOver => 1_500,
        }
    }
}

pub struct Soldier {
    pub team: u8,
    pub x: i64,
    pub z: i64,
    pub state: State,
    pub posture: PostureCode,
    /// 目标点（掩体槽中心或巡逻点），mm
    pub tx: i64,
    pub tz: i64,
    /// 占用的槽（-1 = 没占）
    pub slot: i32,
    /// 蹲到什么时候（tick）
    pub hold_until: u64,
    /// 下次重评掩体的 tick（5 Hz 分频）
    pub next_eval: u64,
    /// 下次重评射击的 tick
    pub next_fire_eval: u64,
    pub stuck: u32,
    // ── 交战 ──
    pub weapon: Weapon,
    pub hp: i32,
    /// 压制（Q16，0..65536）
    pub supp: i64,
    pub ammo_mag: i32,
    pub ammo_spare: i32,
    /// 换弹完成的 tick（0 = 没在换）
    pub reload_until: u64,
    /// 本轮长点射已打出的发数
    pub burst_fired: u32,
    /// 散布累积（µrad）
    pub bloom_urad: i64,
    /// 下一发的最早 tick
    pub next_shot_tick: u64,
    /// 射速小数累加器（Q16）
    pub shot_acc: i64,
    /// 是否退化为单发
    pub single_mode: bool,
    /// 上一次开火的 tick（判断"这次交火结束没有"）
    pub last_fire_tick: u64,
    /// 当前目标（敌人索引，-1 = 无）
    pub target: i32,
    /// 探身开火到什么时候（tick）
    pub peek_until: u64,
    pub next_peek_tick: u64,
}

impl Soldier {
    pub fn alive(&self) -> bool {
        self.state != State::Downed
    }
    /// 还能不能开火（不判断目标，那是 `try_fire` 的事）
    pub fn can_shoot(&self, tick: u64) -> bool {
        self.alive()
            && self.ammo_mag > 0
            && tick >= self.reload_until
            && tick >= self.next_shot_tick
            && self.supp < SUPP_PINNED_Q16
    }
    pub fn total_ammo(&self) -> i32 {
        self.ammo_mag + self.ammo_spare
    }
}

/// 子弹。**实体**：每 tick 从 prev 走到 pos，用线段求交。
#[derive(Clone, Copy)]
pub struct Projectile {
    pub px: i64,
    pub py: i64,
    pub pz: i64,
    pub x: i64,
    pub y: i64,
    pub z: i64,
    pub vx: i64,
    pub vy: i64,
    pub vz: i64,
    pub team: u8,
    pub owner: u32,
    pub dmg: i32,
    /// 剩余 tick（飞出射程就消失）
    pub ttl: i32,
}

#[derive(Clone, Copy, Default, Debug)]
pub struct Stats {
    pub shots: u64,
    pub hits: u64,
    pub near_misses: u64,
    pub downs: u64,
    /// 打光了全部弹药（弹匣 + 备弹 = 0）的人数
    pub dry: u64,
    /// 当前被钉住（supp ≥ 0.60）的人数
    pub pinned: u64,
}

pub struct Sim {
    pub world: World,
    pub hf: HeightField,
    pub cover: CoverField,
    pub soldiers: Vec<Soldier>,
    pub projectiles: Vec<Projectile>,
    pub tick: u64,
    pub dim: u32,
    pub rng: Pcg32,
    pub stats: Stats,
    scratch: Vec<u32>,
    /// 每 tick 重建的空间桶（柱 → 士兵索引），避免弹道对全员暴力枚举
    grid: Vec<Vec<u32>>,
}

impl Sim {
    pub fn new(dim_cells: u32, units_n: usize, seed: u64) -> Self {
        // 先拦在门口：`World::new_flat` 的 chunk_cells 是 32，dim 不是 32 的整数倍
        // 时会在很深的断言里炸，报错信息完全看不出是尺寸的问题。
        assert!(
            dim_cells > 0 && dim_cells % 32 == 0,
            "dim_cells 必须是 32 的整数倍（world 的 chunk_cells = 32），收到 {}",
            dim_cells
        );
        let mut rng = Pcg32::new(seed, 11);
        let world = crate::gen::build_city(&mut rng, dim_cells);
        let p = NavParams::default();
        let mut hf = HeightField::new(dim_cells);
        hf.rebuild_all(&world, &p);
        let mut cover = CoverField::new();
        cover.rebuild_all(&world, &hf);

        let d = i64::from(dim_cells);
        let mut soldiers = Vec::with_capacity(units_n);
        let mut guard = 0usize;
        while soldiers.len() < units_n && guard < units_n * 64 {
            guard += 1;
            let cx = i64::from(rng.next_range(dim_cells));
            let cz = i64::from(rng.next_range(dim_cells));
            if !hf.walkable(cx, cz) {
                continue;
            }
            let x = cx * CELL_MM + CELL_MM / 2;
            let z = cz * CELL_MM + CELL_MM / 2;
            // 两班各占半张地图，不然开局就贴脸
            let team: u8 = if cz < d / 2 { 0 } else { 1 };
            // 每 8 个人一挺机枪
            let weapon = if soldiers.len() % 8 == 3 {
                Weapon::Mg
            } else {
                Weapon::Rifle
            };
            let mag = weapon.mag();
            let spare = if weapon == Weapon::Mg {
                SPARE_MG
            } else {
                SPARE_RIFLE
            };
            soldiers.push(Soldier {
                team,
                x,
                z,
                state: State::Patrol,
                posture: PostureCode::Stand,
                tx: x,
                tz: z,
                slot: -1,
                hold_until: 0,
                next_eval: 0,
                next_fire_eval: 0,
                stuck: 0,
                weapon,
                hp: HP_MAX,
                supp: 0,
                ammo_mag: mag,
                ammo_spare: spare,
                reload_until: 0,
                burst_fired: 0,
                bloom_urad: 0,
                next_shot_tick: 0,
                shot_acc: 0,
                single_mode: false,
                last_fire_tick: 0,
                target: -1,
                peek_until: 0,
                next_peek_tick: 0,
            });
        }
        // 巡逻目标：生成时就给一个，免得第一 tick 全堆在原地
        let mut sim = Sim {
            world,
            hf,
            cover,
            soldiers,
            projectiles: Vec::new(),
            tick: 0,
            dim: dim_cells,
            rng,
            stats: Stats::default(),
            scratch: Vec::new(),
            grid: vec![Vec::new(); (dim_cells * dim_cells) as usize],
        };
        for i in 0..sim.soldiers.len() {
            let (px, pz) = sim.pick_patrol_point((sim.soldiers[i].x, sim.soldiers[i].z));
            sim.soldiers[i].tx = px;
            sim.soldiers[i].tz = pz;
        }
        sim
    }

    // ───────────────────────── 每 tick ─────────────────────────

    pub fn step(&mut self) {
        self.rebuild_grid();
        self.step_projectiles();
        self.step_recovery();
        self.step_fire();
        self.step_cover();
        self.step_move();
        self.tick += 1;
    }

    fn rebuild_grid(&mut self) {
        for cell in self.grid.iter_mut() {
            cell.clear();
        }
        let d = self.dim as i64;
        for (i, s) in self.soldiers.iter().enumerate() {
            if !s.alive() {
                continue;
            }
            let cx = s.x / CELL_MM;
            let cz = s.z / CELL_MM;
            if cx < 0 || cz < 0 || cx >= d || cz >= d {
                continue;
            }
            self.grid[(cz * d + cx) as usize].push(i as u32);
        }
    }

    // ── 1) 子弹推进与命中 ──

    fn step_projectiles(&mut self) {
        let mut i = 0usize;
        while i < self.projectiles.len() {
            let mut p = self.projectiles[i];
            p.px = p.x;
            p.py = p.y;
            p.pz = p.z;
            p.x += p.vx;
            p.y += p.vy;
            p.z += p.vz;
            p.ttl -= 1;

            let hit_soldier = self.resolve_segment(&p);
            let hit_wall = cast(
                &self.world,
                v3(p.px, p.py, p.pz),
                v3(p.x, p.y, p.z),
                RayMode::Projectile,
            );

            let mut consumed = false;
            if let Some((idx, t_num, t_den, part)) = hit_soldier {
                // 墙比人近 → 打在墙上（子弹不会穿墙，这是掩体有意义的唯一原因）
                let wall_first = match &hit_wall {
                    Some(w) => (w.t_num as i128) * (t_den as i128) <= (t_num as i128) * (w.t_den as i128),
                    None => false,
                };
                if !wall_first {
                    let dmg = (i64::from(p.dmg) * part_mul_q16(part)) >> 16;
                    // 注意：这里不能一边 &mut soldiers 一边调 self 的方法（借用冲突），
                    // 所以"倒地"先记成标志，出了块再松槽。
                    let just_downed = {
                        let s = &mut self.soldiers[idx];
                        s.hp -= dmg as i32;
                        self.stats.hits += 1;
                        if s.hp <= 0 && s.alive() {
                            s.hp = 0;
                            s.state = State::Downed;
                            s.posture = PostureCode::Crawl;
                            self.stats.downs += 1;
                            true
                        } else {
                            false
                        }
                    };
                    if just_downed {
                        self.release_slot(idx);
                    }
                    consumed = true;
                }
            }
            if !consumed && hit_wall.is_some() {
                // 打在墙上：M1-B 不做墙体破坏（穿透/跳弹/掩体被打掉留 M2）
                consumed = true;
            }
            // 近失压制：不管这一发最后打到哪儿，只要**飞过的那一段**从谁身边
            // 擦过去就算。原来的写法只在"谁也没打中"时才判近失，于是
            // 先擦过人、再打进墙里的那些子弹全被漏掉了（实测一条都没有）。
            let (ex, ey, ez) = match &hit_wall {
                Some(w) => {
                    let h = hit_point(v3(p.px, p.py, p.pz), v3(p.x, p.y, p.z), w);
                    (i64::from(h.x.0), i64::from(h.y.0), i64::from(h.z.0))
                }
                None => (p.x, p.y, p.z),
            };
            self.apply_near_miss(p.px, p.py, p.pz, ex, ey, ez, p.team);
            if consumed || p.ttl <= 0 || p.y < -2_000 {
                self.projectiles.swap_remove(i);
            } else {
                self.projectiles[i] = p;
                i += 1;
            }
        }
    }

    /// 线段 vs 敌人士兵的采样点球体，返回**最近**的一个命中（索引、t、部位）。
    fn resolve_segment(&self, p: &Projectile) -> Option<(usize, i64, i64, Part)> {
        let cands = self.candidates_for_segment(p.px, p.py, p.pz, p.x, p.y, p.z);
        let mut best: Option<(usize, i64, i64, Part)> = None;
        for idx in cands {
            let s = &self.soldiers[idx as usize];
            if !s.alive() || s.team == p.team {
                continue;
            }
            let ground = self.ground_mm(s.x, s.z);
            let hmm = s.posture.to_cover().samples_mm();
            for (k, h) in hmm.iter().enumerate() {
                let py = ground + i64::from(*h);
                let r = part_radius_mm(k, hmm.len());
                if let Some((t_num, t_den)) = seg_sphere_hit(
                    p.px, p.py, p.pz, p.x, p.y, p.z, s.x, py, s.z, r,
                ) {
                    let better = match best {
                        None => true,
                        Some((_, bn, bd, _)) => {
                            (t_num as i128) * (bd as i128) < (bn as i128) * (t_den as i128)
                        }
                    };
                    if better {
                        best = Some((idx as usize, t_num, t_den, part_of(k, hmm.len())));
                    }
                }
            }
        }
        best
    }

    /// 取线段附近格子里的士兵；格子太多（子弹一 tick 走 60 格）就退回全量枚举。
    fn candidates_for_segment(
        &self,
        ax: i64,
        _ay: i64,
        az: i64,
        bx: i64,
        _by: i64,
        bz: i64,
    ) -> Vec<u32> {
        let d = self.dim as i64;
        let c0x = clamp_cell(i64::min(ax, bx) / CELL_MM - 1, d);
        let c1x = clamp_cell(i64::max(ax, bx) / CELL_MM + 1, d);
        let c0z = clamp_cell(i64::min(az, bz) / CELL_MM - 1, d);
        let c1z = clamp_cell(i64::max(az, bz) / CELL_MM + 1, d);
        let area = (c1x - c0x + 1) * (c1z - c0z + 1);
        let mut out = Vec::new();
        if area > 256 {
            // 一步跨过大半个地图：与其扫几千个空格子，不如直接枚举人
            for (i, s) in self.soldiers.iter().enumerate() {
                if s.alive() {
                    out.push(i as u32);
                }
            }
            return out;
        }
        for cz in c0z..=c1z {
            for cx in c0x..=c1x {
                out.extend_from_slice(&self.grid[(cz * d + cx) as usize]);
            }
        }
        out
    }

    #[allow(clippy::too_many_arguments)]
    fn apply_near_miss(
        &mut self,
        ax: i64,
        ay: i64,
        az: i64,
        bx: i64,
        by: i64,
        bz: i64,
        shooter_team: u8,
    ) {
        let cands = self.candidates_for_segment(ax, ay, az, bx, by, bz);
        for idx in cands {
            let i = idx as usize;
            let (alive, team, sx, sz) = {
                let s = &self.soldiers[i];
                (s.alive(), s.team, s.x, s.z)
            };
            // 注意别写反：这里比较的是"士兵的队"与"开枪那一方的队"，
            // 两个都叫 team 时会静默变成"自己跟自己比"（恒真 ⇒ 谁也不压制，
            // 而且不报错，只是近失永远为 0 —— 上一版就栽在这）。
            if !alive || team == shooter_team {
                continue;
            }
            let ground = self.ground_mm(sx, sz);
            let chest = ground + 1_350;
            let d2 = seg_point_dist2(ax, ay, az, bx, by, bz, sx, chest, sz);
            if d2 > NEAR_MISS_MM * NEAR_MISS_MM {
                continue;
            }
            // 距离越近压制越强：0.3 m → 0.55，1.5 m → 0.30
            let d = isqrt64(d2).max(NEAR_MISS_MIN_MM).min(NEAR_MISS_MM);
            let num = (NEAR_MISS_MM - d) * SUPP_NEAR_MISS_MAX_Q16
                + (d - NEAR_MISS_MIN_MM) * SUPP_NEAR_MISS_MIN_Q16;
            let den = NEAR_MISS_MM - NEAR_MISS_MIN_MM;
            let add = num / den;
            let s = &mut self.soldiers[i];
            s.supp = (s.supp + add).min(65_536);
            self.stats.near_misses += 1;
        }
    }

    // ── 2) 恢复：压制衰减、散布回落、换弹 ──

    fn step_recovery(&mut self) {
        for s in self.soldiers.iter_mut() {
            if !s.alive() {
                continue;
            }
            s.supp = (s.supp * SUPP_DECAY_Q16) >> 16;
            if s.supp < 4 {
                s.supp = 0;
            }
            if self.tick.saturating_sub(s.last_fire_tick) > 2 {
                s.bloom_urad = (s.bloom_urad - BLOOM_DECAY_URAD_PT).max(0);
            }
            if s.reload_until > 0 && self.tick >= s.reload_until {
                s.reload_until = 0;
                let take = s.ammo_spare.min(s.weapon.mag());
                s.ammo_mag = take;
                s.ammo_spare -= take;
                s.burst_fired = 0;
            }
            // 停火够久 → 回到连发模式
            if s.single_mode && self.tick.saturating_sub(s.last_fire_tick) > BURST_RESET_TICKS {
                s.single_mode = false;
                s.burst_fired = 0;
            }
        }
    }

    // ── 3) 选目标与开火 ──

    fn step_fire(&mut self) {
        let n = self.soldiers.len();
        if n == 0 {
            return;
        }
        let mut budget = FIRE_BUDGET;
        let start = (self.tick as usize) % n;
        for k in 0..n {
            if budget == 0 {
                break;
            }
            let i = (start + k) % n;
            if self.soldiers[i].next_fire_eval > self.tick {
                continue;
            }
            self.soldiers[i].next_fire_eval = self.tick + FIRE_REEVAL;
            budget -= 1;
            self.think_fire(i);
        }
        // 开火是**每 tick**结算的（射速累加器决定这一 tick 出几发），
        // 目标选择才是 5 Hz —— 否则高射速武器会被决策频率卡住。
        for i in 0..n {
            self.try_fire(i);
        }
    }

    /// 挑一个看得见的敌人（最近的），顺便决定要不要探身
    fn think_fire(&mut self, i: usize) {
        if !self.soldiers[i].alive() {
            return;
        }
        let (x, z, team, weapon, peek_until, next_peek, hidden) = {
            let s = &self.soldiers[i];
            (
                s.x,
                s.z,
                s.team,
                s.weapon,
                s.peek_until,
                s.next_peek_tick,
                s.state == State::Hidden,
            )
        };
        let range = weapon.range_mm();
        let best = self.find_target(i, x, z, team, range);
        // 藏在掩体里：先探身（抬高采样点）才看得见人，也才打得着
        if hidden && self.tick >= peek_until {
            if self.tick >= next_peek && best.is_none() {
                // 看不见人 → 探一次头看看
                self.soldiers[i].peek_until = self.tick + PEEK_TICKS;
                self.soldiers[i].next_peek_tick = self.tick + PEEK_TICKS + PEEK_COOLDOWN_TICKS;
                self.soldiers[i].posture = PostureCode::PeekOver;
            } else if self.tick < peek_until {
                // 正在探身
            } else {
                self.soldiers[i].posture = PostureCode::Prone;
            }
        }
        if hidden && self.tick < self.soldiers[i].peek_until {
            let again = self.find_target(i, x, z, team, range);
            self.soldiers[i].target = again.map(|(t, _, _, _)| t as i32).unwrap_or(-1);
            return;
        }
        self.soldiers[i].target = best.map(|(t, _, _, _)| t as i32).unwrap_or(-1);
    }

    /// 最近的、看得见的敌人（返回索引与瞄准点）
    fn find_target(
        &self,
        _i: usize,
        x: i64,
        z: i64,
        team: u8,
        range: i64,
    ) -> Option<(usize, i64, i64, i64)> {
        let mut best: Option<(usize, i64, i64, i64, i64)> = None; // (idx, d2, aim_y, ax, az)
        let eye = self.ground_mm(x, z) + 1_650;
        for (j, s) in self.soldiers.iter().enumerate() {
            if !s.alive() || s.team == team {
                continue;
            }
            let d2 = (s.x - x) * (s.x - x) + (s.z - z) * (s.z - z);
            if d2 > range * range {
                continue;
            }
            if let Some((_, bd2, _, _, _)) = best {
                if d2 >= bd2 {
                    continue;
                }
            }
            // 看得见吗：从射手眼睛到敌人**某个**采样点（逐点，R3）
            let ground = self.ground_mm(s.x, s.z);
            let samples = s.posture.to_cover().samples_mm();
            let mut aim: Option<(i64, i64, i64)> = None;
            for h in samples {
                let py = ground + i64::from(*h);
                if !blocked(
                    &self.world,
                    v3(x, eye, z),
                    v3(s.x, py, s.z),
                    RayMode::Sight,
                ) {
                    aim = Some((s.x, py, s.z));
                    break;
                }
            }
            if let Some((ax, ay, az)) = aim {
                best = Some((j, d2, ay, ax, az));
            }
        }
        best.map(|(j, _, ay, ax, az)| (j, ay, ax, az))
    }

    fn try_fire(&mut self, i: usize) {
        let (team, weapon, target) = {
            let s = &self.soldiers[i];
            (s.team, s.weapon, s.target)
        };
        if target < 0 || !self.soldiers[i].alive() {
            return;
        }
        let t = target as usize;
        if t >= self.soldiers.len() || !self.soldiers[t].alive() || self.soldiers[t].team == team {
            self.soldiers[i].target = -1;
            return;
        }
        if !self.soldiers[i].can_shoot(self.tick) {
            return;
        }
        // 射速累加器：这一 tick 该出几发
        self.soldiers[i].shot_acc += weapon.rpt_q16();
        if self.soldiers[i].shot_acc < 65_536 {
            return;
        }
        self.soldiers[i].shot_acc -= 65_536;
        if self.soldiers[i].single_mode {
            // 退化为单发：按单发节奏，不再连发
            self.soldiers[i].next_shot_tick = self.tick + SINGLE_SHOT_TICKS;
        }
        let (ax, az, ay) = {
            let s = &self.soldiers[t];
            (s.x, s.z, s.posture.height_mm())
        };
        let (sx, sz) = (self.soldiers[i].x, self.soldiers[i].z);
        let sy = self.ground_mm(sx, sz) + self.soldiers[i].posture.height_mm() - 300; // 枪口略低于头顶
        let cone = self.cone_urad(i, ax - sx, az - sz);
        self.spawn_shot(i, sx, sy, sz, ax, ay, az, cone);

        let s = &mut self.soldiers[i];
        s.ammo_mag -= 1;
        s.burst_fired += 1;
        s.last_fire_tick = self.tick;
        s.bloom_urad = (s.bloom_urad + BLOOM_URAD_PER_ROUND)
            .min((cone_base_urad(s.weapon) * BLOOM_MAX_MUL_Q16) >> 16);
        self.stats.shots += 1;
        if s.ammo_mag == 0 {
            // 打空 → 空仓换弹；还有备弹才换
            if s.ammo_spare > 0 {
                s.reload_until = self.tick + RELOAD_EMPTY_TICKS;
            }
        } else if s.burst_fired >= s.weapon.burst_rounds() {
            // 长点射打满 → 停火冷却，之后退化为单发（P4）
            s.next_shot_tick = self.tick + s.weapon.burst_cooldown();
            s.burst_fired = 0;
            s.single_mode = true;
        }
    }

    fn cone_urad(&self, i: usize, dx: i64, dz: i64) -> i64 {
        let s = &self.soldiers[i];
        let base = cone_base_urad(s.weapon) + s.bloom_urad;
        let mut cone = (base * s.posture.cone_q16()) >> 16;
        let mv = if s.state == State::Rush {
            MOVE_RUSH_Q16
        } else if s.state == State::Patrol {
            MOVE_PATROL_Q16
        } else {
            0
        };
        cone = (cone * (65_536 + ((MOVE_CONE_Q16 * mv) >> 16))) >> 16;
        cone = (cone * (65_536 + ((SUPP_CONE_Q16 * s.supp) >> 16))) >> 16;
        let d = isqrt64(dx * dx + dz * dz).min(s.weapon.range_mm());
        let dq = (d << 16) / s.weapon.range_mm();
        cone = (cone * (65_536 + ((DIST_CONE_Q16 * dq) >> 16))) >> 16;
        cone.max(1)
    }

    #[allow(clippy::too_many_arguments)]
    fn spawn_shot(
        &mut self,
        i: usize,
        sx: i64,
        sy: i64,
        sz: i64,
        tx: i64,
        ty: i64,
        tz: i64,
        cone_urad: i64,
    ) {
        if self.projectiles.len() >= MAX_PROJECTILES {
            return;
        }
        let mut dx = tx - sx;
        let mut dy = ty - sy;
        let mut dz = tz - sz;
        // 误差锥：水平转一个角、垂直抬一个角（µrad，小角近似，全整数）
        let r1 = self.rng.next_u32() as i64; // [0, 2^32)
        let r2 = self.rng.next_u32() as i64;
        let th_h = ((r1 % 2_000_001) - 1_000_000) * cone_urad / 1_000_000;
        let th_v = ((r2 % 2_000_001) - 1_000_000) * cone_urad / 1_000_000;
        // 水平旋转（sin θ ≈ θ/1e6，cos θ ≈ 1）
        let ndx = dx - (dz * th_h) / 1_000_000;
        let ndz = dz + (dx * th_h) / 1_000_000;
        dx = ndx;
        dz = ndz;
        // 垂直：抬高 L·θ_v
        let l = isqrt64(dx * dx + dz * dz).max(1);
        dy += (l * th_v) / 1_000_000;
        let len = isqrt64(dx * dx + dy * dy + dz * dz).max(1);
        let vel = self.soldiers[i].weapon.vel_mmpt();
        let vx = (dx * vel) / len;
        let vy = (dy * vel) / len;
        let vz = (dz * vel) / len;
        let dmg = self.soldiers[i].weapon.dmg();
        let team = self.soldiers[i].team;
        // 飞完射程就消失（ttl = 射程 / 每 tick 弹程 + 2 tick 余量）
        let ttl = (self.soldiers[i].weapon.range_mm() / vel + 2) as i32;
        self.projectiles.push(Projectile {
            px: sx,
            py: sy,
            pz: sz,
            x: sx,
            y: sy,
            z: sz,
            vx,
            vy,
            vz,
            team,
            owner: i as u32,
            dmg,
            ttl,
        });
    }

    // ── 4) 掩体决策（M1-A 逻辑搬进来，威胁换成"看得见的敌人"）──

    fn step_cover(&mut self) {
        let n = self.soldiers.len();
        if n == 0 {
            return;
        }
        let mut budget = COVER_BUDGET;
        let start = (self.tick as usize) % n;
        for k in 0..n {
            if budget == 0 {
                break;
            }
            let i = (start + k) % n;
            if self.soldiers[i].next_eval > self.tick {
                continue;
            }
            self.soldiers[i].next_eval = self.tick + COVER_REEVAL;
            budget -= 1;
            self.think_cover(i);
        }
        // 枪停了 → 蹲够时间的站起来继续走
        for i in 0..n {
            let stand = self.soldiers[i].state == State::Hidden
                && self.tick >= self.soldiers[i].hold_until
                && self.tick >= self.soldiers[i].peek_until
                && self.soldiers[i].target < 0;
            if stand {
                self.release_slot(i);
                let (px, pz) = self.pick_patrol_point((self.soldiers[i].x, self.soldiers[i].z));
                let s = &mut self.soldiers[i];
                s.state = State::Patrol;
                s.posture = PostureCode::Stand;
                s.tx = px;
                s.tz = pz;
                s.stuck = 0;
                s.single_mode = false;
                s.burst_fired = 0;
            }
        }
    }

    /// 威胁 = 最近 3 个看得见的敌人（M1-B：不再是一挺固定的机枪）
    fn threats_for(&self, i: usize) -> Vec<Threat> {
        let s = &self.soldiers[i];
        let mut out: Vec<Threat> = Vec::new();
        let mut found: Vec<(i64, usize)> = Vec::new();
        for (j, e) in self.soldiers.iter().enumerate() {
            if !e.alive() || e.team == s.team {
                continue;
            }
            let d2 = (e.x - s.x) * (e.x - s.x) + (e.z - s.z) * (e.z - s.z);
            if d2 > 120_000 * 120_000 {
                continue;
            }
            found.push((d2, j));
        }
        found.sort_unstable();
        for (_, j) in found.iter().take(3) {
            let e = &self.soldiers[*j];
            out.push(Threat {
                x_mm: e.x as i32,
                y_mm: self.ground_mm(e.x, e.z) as i32,
                z_mm: e.z as i32,
                confidence: 65_535,
            });
        }
        out
    }

    fn think_cover(&mut self, i: usize) {
        if !self.soldiers[i].alive() {
            return;
        }
        let (x, z, hidden, hold_until) = {
            let s = &self.soldiers[i];
            (s.x, s.z, s.state == State::Hidden, s.hold_until)
        };
        if hidden && self.tick < hold_until {
            return;
        }
        if self.soldiers[i].state == State::Downed {
            return;
        }
        let threats = self.threats_for(i);
        if threats.is_empty() {
            // 没威胁 → 别窝着
            if hidden {
                let (px, pz) = self.pick_patrol_point((x, z));
                let s = &mut self.soldiers[i];
                s.state = State::Patrol;
                s.posture = PostureCode::Stand;
                s.tx = px;
                s.tz = pz;
            }
            return;
        }
        // 就地一趴/一蹲就能挡住 → 不换地方
        if blocking_at(&self.world, &self.hf, x, z, None, &threats).0 >= COVER_OK_BLOCK {
            self.release_slot(i);
            let s = &mut self.soldiers[i];
            s.state = State::Hidden;
            s.hold_until = self.tick + HOLD_TICKS;
            s.posture = PostureCode::Prone;
            s.tx = x;
            s.tz = z;
            return;
        }
        let choice = pick_cover(
            &self.world,
            &self.cover,
            x,
            z,
            None,
            &threats,
            12,
            &mut self.scratch,
        );
        if let Some(c) = choice {
            if let Some(slot) = self.cover.slot(c.slot).copied() {
                let (tx, tz) = (slot.center_x_mm(), slot.center_z_mm());
                let posture = posture_of(slot.kind.best_posture());
                self.take_slot(i, c.slot);
                let s = &mut self.soldiers[i];
                s.state = State::Rush;
                s.posture = posture;
                s.tx = tx;
                s.tz = tz;
                s.stuck = 0;
            }
        }
    }

    fn take_slot(&mut self, i: usize, slot_idx: u32) {
        self.release_slot(i);
        if let Some(slot) = self.cover.slots.get_mut(slot_idx as usize) {
            slot.occupied = slot.occupied.saturating_add(1);
            self.soldiers[i].slot = slot_idx as i32;
        }
    }

    fn release_slot(&mut self, i: usize) {
        let s = self.soldiers[i].slot;
        if s >= 0 {
            if let Some(slot) = self.cover.slots.get_mut(s as usize) {
                slot.occupied = slot.occupied.saturating_sub(1);
            }
            self.soldiers[i].slot = -1;
        }
    }

    // ── 5) 移动 ──

    fn step_move(&mut self) {
        for i in 0..self.soldiers.len() {
            let (state, x, z, tx, tz, posture) = {
                let s = &self.soldiers[i];
                (s.state, s.x, s.z, s.tx, s.tz, s.posture)
            };
            if state == State::Hidden || state == State::Downed {
                continue;
            }
            let mut step_mm = if state == State::Rush {
                RUSH_MM
            } else {
                PATROL_MM
            };
            // 被压制 → 走得慢（迟疑）
            if self.soldiers[i].supp >= SUPP_HESITANT_Q16 {
                step_mm = (step_mm * 7) / 10;
            }
            let (nx, nz) = {
                let (sx, sz) = step_toward((x, z), (tx, tz), step_mm);
                if self.can_stand(sx, sz) {
                    (sx, sz)
                } else if self.can_stand(sx, z) {
                    (sx, z)
                } else if self.can_stand(x, sz) {
                    (x, sz)
                } else {
                    (x, z)
                }
            };
            let dx = tx - nx;
            let dz = tz - nz;
            let arrived = dx * dx + dz * dz <= ARRIVE_MM * ARRIVE_MM;
            let moved = nx != x || nz != z;
            let mut reset_patrol = false;
            {
                let s = &mut self.soldiers[i];
                s.x = nx;
                s.z = nz;
                if arrived {
                    if state == State::Rush {
                        s.state = State::Hidden;
                        s.hold_until = self.tick + HOLD_TICKS;
                        s.posture = if posture == PostureCode::Prone {
                            PostureCode::Prone
                        } else {
                            PostureCode::Crouch
                        };
                    } else {
                        reset_patrol = true;
                    }
                } else if !moved {
                    s.stuck += 1;
                    if s.stuck > STUCK_TICKS {
                        reset_patrol = true;
                    }
                }
            }
            if reset_patrol {
                self.release_slot(i);
                let (px, pz) = self.pick_patrol_point((nx, nz));
                let s = &mut self.soldiers[i];
                s.state = State::Patrol;
                s.posture = PostureCode::Stand;
                s.tx = px;
                s.tz = pz;
                s.stuck = 0;
            }
        }
    }

    // ───────────────────────── 小工具 ─────────────────────────

    pub fn ground_mm(&self, x_mm: i64, z_mm: i64) -> i64 {
        i64::from(
            self.hf
                .walk_top(x_mm / CELL_MM, z_mm / CELL_MM)
                .unwrap_or(0),
        )
    }

    fn can_stand(&self, x_mm: i64, z_mm: i64) -> bool {
        let cx = x_mm / CELL_MM;
        let cz = z_mm / CELL_MM;
        cx >= 0 && cz >= 0 && cx < i64::from(self.dim) && cz < i64::from(self.dim) && self.hf.walkable(cx, cz)
    }

    pub fn pick_patrol_point(&mut self, fallback: (i64, i64)) -> (i64, i64) {
        for _ in 0..32 {
            let cx = i64::from(self.rng.next_range(self.dim));
            let cz = i64::from(self.rng.next_range(self.dim));
            if self.hf.walkable(cx, cz) {
                return (cx * CELL_MM + CELL_MM / 2, cz * CELL_MM + CELL_MM / 2);
            }
        }
        fallback
    }

    /// 供渲染/调试：当前在掩体里的人数
    pub fn in_cover_count(&self) -> usize {
        self.soldiers
            .iter()
            .filter(|s| s.state == State::Hidden)
            .count()
    }
    pub fn downed_count(&self) -> usize {
        self.soldiers.iter().filter(|s| !s.alive()).count()
    }
    pub fn pinned_count(&self) -> usize {
        self.soldiers.iter().filter(|s| s.supp >= SUPP_PINNED_Q16).count()
    }

    /// 士兵位置校验和（与 M1-A 同口径，用于跨平台比对）
    pub fn pos_checksum(&self) -> u64 {
        let mut h: u64 = 0x9E3779B97F4A7C15;
        for s in self.soldiers.iter() {
            h ^= h.rotate_left(7).wrapping_add(s.x as u64);
            h ^= h.rotate_left(11).wrapping_add(s.z as u64);
            h ^= h.rotate_left(17).wrapping_add(s.state.code() as u64);
            h ^= h.rotate_left(23).wrapping_add(s.hp as u64);
        }
        h
    }
}

// ───────────────────────── 自由函数 ─────────────────────────

#[inline]
fn v3(x: i64, y: i64, z: i64) -> Vec3 {
    Vec3 {
        x: Mm(x as i32),
        y: Mm(y as i32),
        z: Mm(z as i32),
    }
}

#[inline]
fn clamp_cell(v: i64, d: i64) -> i64 {
    v.max(0).min(d - 1)
}

#[inline]
fn cone_base_urad(w: Weapon) -> i64 {
    match w {
        Weapon::Rifle => CONE_BASE_URAD_RIFLE,
        Weapon::Mg => CONE_BASE_URAD_MG,
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Part {
    Head,
    Chest,
    Gut,
    Limb,
}

/// 采样点索引 → 部位。采样点是"从高到低"排列的，与 §20.1.3 的权重表一一对应。
fn part_of(k: usize, n: usize) -> Part {
    match (n, k) {
        (4, 0) => Part::Head,  // Stand: 1700 头 / 1350 胸 / 1000 腹 / 550 腿
        (4, 1) => Part::Chest,
        (4, 2) => Part::Gut,
        (4, _) => Part::Limb,
        (3, 0) => Part::Head,  // Crouch / Peek: 最高的算头
        (3, 1) => Part::Chest,
        (3, _) => Part::Gut,
        (2, 0) => Part::Head,  // Prone / Crawl / PeekOver
        _ => Part::Chest,
    }
}

fn part_mul_q16(p: Part) -> i64 {
    match p {
        Part::Head => PART_HEAD_Q16,
        Part::Chest => PART_CHEST_Q16,
        Part::Gut => PART_GUT_Q16,
        Part::Limb => PART_LIMB_Q16,
    }
}

fn part_radius_mm(k: usize, n: usize) -> i64 {
    match part_of(k, n) {
        Part::Head => HIT_R_HEAD_MM,
        Part::Chest => HIT_R_CHEST_MM,
        Part::Gut => HIT_R_GUT_MM,
        Part::Limb => HIT_R_LIMB_MM,
    }
}

fn posture_of(p: Posture) -> PostureCode {
    match p {
        Posture::Stand => PostureCode::Stand,
        Posture::Crouch => PostureCode::Crouch,
        Posture::Prone => PostureCode::Prone,
        Posture::Crawl => PostureCode::Crawl,
        Posture::Peek => PostureCode::Peek,
        Posture::PeekOver => PostureCode::PeekOver,
    }
}

/// 整数平方根：直接用 `sim_math` 的实现，不在这里再写一份
/// （全项目同一套定点数学，跨平台校验和才有意义）。
fn isqrt64(v: i64) -> i64 {
    isqrt_i64(v)
}

/// 线段 A→B 与球心 P、半径 r 求交。返回命中参数 `t = t_num / t_den`。
///
/// 全部走 i128：`(P−A)·den` 这类中间量在毫米单位下会到 1e13，
/// 平方后 i64 必然溢出（i64 上限 9.2e18）。
#[allow(clippy::too_many_arguments)]
fn seg_sphere_hit(
    ax: i64,
    ay: i64,
    az: i64,
    bx: i64,
    by: i64,
    bz: i64,
    px: i64,
    py: i64,
    pz: i64,
    r: i64,
) -> Option<(i64, i64)> {
    // 粗筛：包围盒，先干掉绝大多数不相关的目标
    let (lox, hix) = if ax <= bx { (ax - r, bx + r) } else { (bx - r, ax + r) };
    let (loy, hiy) = if ay <= by { (ay - r, by + r) } else { (by - r, ay + r) };
    let (loz, hiz) = if az <= bz { (az - r, bz + r) } else { (bz - r, az + r) };
    if !(px >= lox && px <= hix && py >= loy && py <= hiy && pz >= loz && pz <= hiz) {
        return None;
    }
    let abx = i128::from(bx - ax);
    let aby = i128::from(by - ay);
    let abz = i128::from(bz - az);
    let apx = i128::from(px - ax);
    let apy = i128::from(py - ay);
    let apz = i128::from(pz - az);
    let den = abx * abx + aby * aby + abz * abz;
    if den == 0 {
        return None;
    }
    let num = apx * abx + apy * aby + apz * abz;
    let r2 = i128::from(r) * i128::from(r);
    if num <= 0 {
        let d2 = apx * apx + apy * apy + apz * apz;
        return if d2 <= r2 { Some((0, 1)) } else { None };
    }
    if num >= den {
        let dx = i128::from(px - bx);
        let dy = i128::from(py - by);
        let dz = i128::from(pz - bz);
        let d2 = dx * dx + dy * dy + dz * dz;
        return if d2 <= r2 { Some((1, 1)) } else { None };
    }
    // 最近点 = A + (num/den)·AB；比较 |P·den − (A·den + AB·num)|² ≤ r²·den²
    let cx = i128::from(ax) * den + abx * num;
    let cy = i128::from(ay) * den + aby * num;
    let cz = i128::from(az) * den + abz * num;
    let dx = i128::from(px) * den - cx;
    let dy = i128::from(py) * den - cy;
    let dz = i128::from(pz) * den - cz;
    if dx * dx + dy * dy + dz * dz <= r2 * den * den {
        Some((num as i64, den as i64))
    } else {
        None
    }
}

/// 点到线段的距离平方（近失判定用；只关心"是不是够近"，用 i128 保平安）
fn seg_point_dist2(
    ax: i64,
    ay: i64,
    az: i64,
    bx: i64,
    by: i64,
    bz: i64,
    px: i64,
    py: i64,
    pz: i64,
) -> i64 {
    let abx = i128::from(bx - ax);
    let aby = i128::from(by - ay);
    let abz = i128::from(bz - az);
    let apx = i128::from(px - ax);
    let apy = i128::from(py - ay);
    let apz = i128::from(pz - az);
    let den = abx * abx + aby * aby + abz * abz;
    if den == 0 {
        return (apx * apx + apy * apy + apz * apz).min(i64::MAX as i128) as i64;
    }
    let mut num = apx * abx + apy * aby + apz * abz;
    if num < 0 {
        num = 0;
    } else if num > den {
        num = den;
    }
    let cx = i128::from(ax) * den + abx * num;
    let cy = i128::from(ay) * den + aby * num;
    let cz = i128::from(az) * den + abz * num;
    let dx = i128::from(px) * den - cx;
    let dy = i128::from(py) * den - cy;
    let dz = i128::from(pz) * den - cz;
    let d2 = (dx * dx + dy * dy + dz * dz) / (den * den);
    d2.min(i64::MAX as i128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isqrt_is_exact_enough() {
        assert_eq!(isqrt64(0), 0);
        assert_eq!(isqrt64(1), 1);
        assert_eq!(isqrt64(4), 2);
        assert_eq!(isqrt64(9), 3);
        assert_eq!(isqrt64(1_000_000), 1_000);
        assert_eq!(isqrt64(1_000_000_000_000), 1_000_000);
    }

    #[test]
    fn segment_hits_sphere_only_when_close() {
        // 沿 +x 飞的子弹，球心在 (1000, 0, 0)，半径 200
        let hit = seg_sphere_hit(0, 0, 0, 2_000, 0, 0, 1_000, 0, 0, 200);
        assert!(hit.is_some(), "正对着飞过去必须命中");
        // 偏 500 mm 就打不中
        let miss = seg_sphere_hit(0, 0, 0, 2_000, 0, 0, 1_000, 500, 0, 200);
        assert!(miss.is_none(), "偏出去 500 mm 不该命中半径 200 的球");
        // 球在射线**后面**：不该命中（子弹一 tick 只走一段）
        let behind = seg_sphere_hit(0, 0, 0, 2_000, 0, 0, -1_000, 0, 0, 200);
        assert!(behind.is_none());
    }

    #[test]
    fn near_miss_distance_is_perpendicular() {
        // 子弹从 (0,0,0) 飞到 (2000,0,0)，人在 (1000, 1500, 0)：垂直距离就是 1500
        let d2 = seg_point_dist2(0, 0, 0, 2_000, 0, 0, 1_000, 1_500, 0);
        assert_eq!(isqrt64(d2), 1_500);
    }

    #[test]
    fn engagement_runs_and_produces_casualties() {
        // 32 人小图跑 600 tick：得有人开枪、有人被压制、有人倒下
        let mut sim = Sim::new(64, 32, 7);
        for _ in 0..1_200 {
            sim.step();
        }
        assert!(sim.stats.shots > 0, "两班相遇总得开枪");
        assert!(sim.stats.near_misses > 0, "近失弹要能压制到人");
        assert!(
            sim.stats.downs > 0,
            "打 600 tick 还没人倒下 = 命中判定没生效（shots={} hits={}）",
            sim.stats.shots,
            sim.stats.hits
        );
    }

    #[test]
    fn ammo_runs_out_and_positions_go_quiet() {
        // 弹药必须真的会打光：跑到最后应该有人在换弹或彻底没弹
        let mut sim = Sim::new(64, 32, 11);
        for _ in 0..3_000 {
            sim.step();
        }
        let dry = sim.soldiers.iter().filter(|s| s.total_ammo() == 0).count();
        let reloading = sim.soldiers.iter().filter(|s| s.reload_until > 0).count();
        assert!(
            dry + reloading > 0,
            "打了 3000 tick 竟然没人换弹也没人打光 —— 弹药是假的"
        );
    }
}

/// 打光了全部弹药（弹匣 + 备弹 = 0）的人数 —— CLI 与引擎都用它做"阵地沉寂"的判据。
pub fn engage_dry_count(s: &Sim) -> usize {
    s.soldiers.iter().filter(|u| u.total_ammo() == 0).count()
}
