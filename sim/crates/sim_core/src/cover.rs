//! 掩体派生（设计文档 §20.1）—— **全部从体素几何实时算出，没有任何手工掩体点**。
//!
//! 三条不能破的约束：
//! 1. **反脚本化**：槽位只由 `World` 的段 + `HeightField` 的可站立面决定，
//!    代码里没有、也不允许有"这里是掩体"的数据。`tests/cover.rs` 用随机场景验证（§20.1.8）。
//! 2. **"被挡住了吗"只走 `ray::blocked`**（R3）：掩体、视线、弹道共用同一个函数，
//!    三者不可能出现规则分歧。
//! 3. 本文件的常量与 `sim/data/constants.ron` 的 `cover` 段一一对应，
//!    改一处必须改另一处（`tools/check_constants.py` 校验文档与 ron）。
//!
//! M1 切片范围（冻结表 §6.2）：
//! - ✅ 槽生成（§20.1.2）/ 遮挡度（§20.1.3）/ 有效遮挡角（§20.1.4）/ 评分选槽（M1 子集）
//! - ❌ 掩体图、`escape_score`、压制场、任务牵引 —— M2，本文件里它们恒为 0（有注释标明）

use crate::nav::HeightField;
use crate::ray::{blocked, RayMode};
use crate::world::{mat, World};
use crate::CELL_MM;
use sim_math::{Ang, Mm, Q16, Vec3};

// ═══════════════════════════ 冻结常量 ═══════════════════════════
// 与 `sim/data/constants.ron` 的 `cover` / `ai_weights` 段一一对应。
// 改这里必须同步改 ron 与《05-frozen-parameters.md》（check_constants.py 会校验文档与 ron）。

/// 搜索半径：超出这个距离的掩体对士兵没有战术意义（转移耗时过长）。
pub const SEARCH_RADIUS_MM: i64 = 18_000;
/// 候选上限（Full LOD）。12 × 2 采样点 = 24 射线/次评估。
pub const CANDIDATES_FULL: usize = 12;
/// 候选上限（Reduced LOD）。
pub const CANDIDATES_REDUCED: usize = 6;
/// 每个单位占的墙面宽度（肩宽）。
pub const SLOT_CAPACITY_MM: i64 = 800;
/// 掩体图连边（M2）。
pub const GRAPH_EDGE_MM: i64 = 8_000;
/// 覆盖角：`coverage = clamp(base + width_deg * width/2m, base, max)` —— **全角**。
pub const COVERAGE_BASE_DEG: i32 = 60;
pub const COVERAGE_WIDTH_DEG: i32 = 30;
pub const COVERAGE_MAX_DEG: i32 = 110;
/// 超出 `cover_half_angle + FLANK_MARGIN` → 对该威胁失效（被包抄）。
pub const FLANK_MARGIN_DEG: i32 = 25;
/// 绕墙近距特判：距离 < 3 m 且夹角 > 120° → 失效。
pub const FLANK_DIST_MM: i64 = 3_000;
pub const FLANK_BACK_DEG: i32 = 120;
/// 低于此高度的凸起不算掩体（脚能跨过去）。
pub const MIN_HEIGHT_MM: i32 = 400;
/// 高墙 / 矮墙分界。
pub const HIGH_WALL_MM: i32 = 1_100;
/// 窄于这个宽度只能藏半个身位 → `PILLAR`。
pub const PILLAR_MAX_WIDTH_MM: i32 = 1_000;
/// 沿墙扫描宽度的上限（8 m）。
pub const WIDTH_SCAN_MAX_MM: i64 = 8_000;
/// 战壕判定：槽位地面比"面前那一格"低这么多就算壕。
pub const TRENCH_DEPTH_MM: i32 = 500;
/// 探身侧向偏移。
pub const PEEK_OFFSET_MM: i32 = 450;
/// 槽位预留保持时间（tick）。
pub const SLOT_RESERVE_TICKS: u32 = 30;
/// `reach_score` 的时间视野（tick）：走 3 秒还没到的槽，reach 归零。
///
/// 为什么用**时间**而不是距离：`reach` 的本意是"到达时间的反比"（§20.1.5）。
/// 只按距离算的话，15 m 外那个"完美掩体"会赢过脚边的矮墙，
/// 于是士兵在 3 秒验收窗口里一直在开阔地跑 —— 实测成功率只有 7%。
pub const REACH_HORIZON_TICKS: i64 = 90;
/// "冲向掩体"的速度（mm/tick）：`speed_sprint_mmps = 3000` ÷ 30 Hz。
///
/// 用冲刺而不是步行：挨打时冲进掩体是真实行为（constants.ron 里 sprint 就是给这个用的），
/// 而且只有在这个速度下"3 秒到达"才是个有意义的约束。
pub const RUSH_MM_PER_TICK: i64 = 100;

// 评分权重（ai_weights.ron 的 M1 子集，Q16 口径：1.0 = 65536）
impl CoverKind {
    /// 这处掩体**该用什么姿态**（§20.1.2 的"可用姿态"列）。
    ///
    /// 为什么必须显式化：蹲在 0.9 m 矮墙后，头顶采样点（1150 mm）是露在外面的，
    /// 两点评测只有 0.53 —— 达不到"藏住"。矮墙/战壕/残骸必须**卧倒**才算藏好。
    /// 少了这一步，AI 会认为矮墙没用，或者站错了姿态被人打头。
    pub const fn best_posture(self) -> Posture {
        match self {
            CoverKind::Trench | CoverKind::LowWall | CoverKind::Wreck | CoverKind::Pillar => {
                Posture::Prone
            }
            CoverKind::HighWall | CoverKind::Corner | CoverKind::Window => Posture::Crouch,
        }
    }
}

pub const W_BLOCK: i32 = 65_536; // 1.00
pub const W_ANGLE: i32 = 29_491; // 0.45
pub const W_REACH: i32 = 22_938; // 0.35
pub const W_CROWD: i32 = 16_384; // 0.25
// M2 才有：W_ESCAPE 0.30 / W_FIRE 0.40 / W_SUPPRESS 0.60 / W_OBJECTIVE 0.50 / W_LEADER 0.15
// —— 本文件里这些项恒为 0（见 `score_slot` 的注释）

/// 四个水平方向：北(-Z) / 东(+X) / 南(+Z) / 西(-X)。
const DIRS: [(i64, i64); 4] = [(0, -1), (1, 0), (0, 1), (-1, 0)];
/// 与 `DIRS` 对应的方位角（度）：0 = 北，顺时针。
const DIR_DEG: [i32; 4] = [0, 90, 180, 270];

// ═══════════════════════════ 姿态与采样点 ═══════════════════════════

/// 姿态。采样点与命中判定**共用**（§20.1.3），改这里牵动整个战斗系统。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Posture {
    Stand,
    Crouch,
    Prone,
    /// 伤员爬行
    Crawl,
    /// 左右探身
    Peek,
    /// 探头上沿
    PeekOver,
}

impl Posture {
    /// 身体采样点高度（mm，相对脚底），从高到低。与 `constants.ron` 的 `cover.samples_*_mm` 一致。
    pub const fn samples_mm(self) -> &'static [i32] {
        match self {
            Posture::Stand => &[1700, 1350, 1000, 550],
            Posture::Crouch => &[1150, 850, 550],
            Posture::Prone => &[450, 300, 150],
            Posture::Crawl => &[350, 200],
            Posture::Peek => &[1300, 1000, 700],
            Posture::PeekOver => &[1500, 1250],
        }
    }
    /// 采样点权重（百分比，与采样点一一对应）。伤害与暴露共用。
    pub const fn samples_w(self) -> &'static [i32] {
        match self {
            Posture::Stand => &[30, 35, 20, 15],
            Posture::Crouch => &[35, 40, 25],
            Posture::Prone => &[40, 35, 25],
            Posture::Crawl => &[50, 50],
            Posture::Peek => &[40, 40, 20],
            Posture::PeekOver => &[50, 50],
        }
    }
    /// 眼高（mm，相对脚底）—— 视线与"射手眼睛"位置。
    pub const fn eye_mm(self) -> i32 {
        match self {
            Posture::Stand => 1650,
            Posture::Crouch => 1050,
            Posture::Prone => 400,
            Posture::Crawl => 300,
            Posture::Peek => 1250,
            Posture::PeekOver => 1450,
        }
    }
}

/// 掩体类型（§20.1.2 类型判定表）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum CoverKind {
    /// 战壕：可低姿机动，站立完全暴露
    Trench,
    /// 矮墙：蹲下全藏，站立需探头
    LowWall,
    /// 高墙：可左右探身
    HighWall,
    /// 转角：两边都能探头，也容易两面挨打
    Corner,
    /// 窗洞：可从窗台探头
    Window,
    /// 残骸：会被打穿，掩体价值衰减快
    Wreck,
    /// 窄柱：只藏半个身位
    Pillar,
}

// ═══════════════════════════ 槽与场 ═══════════════════════════

/// 一个掩体槽。**位置信息只存柱坐标** —— 精确位置由柱中心推出，
/// 这样"世界改了 → 槽重建"不会引入浮点误差，跨平台校验和天然一致。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct CoverSlot {
    /// 槽所在柱（**外侧空柱**，士兵站的地方）
    pub cx: i32,
    pub cz: i32,
    /// 站立面高度（mm）
    pub ground_mm: i32,
    /// **掩体正面**朝向：从槽**指回掩体**的方向（= 威胁在哪个方向时这处掩体才有用）。
    ///
    /// 命名对照：设计文档 §20.1.2 里 `d` 是"墙柱 → 槽"的方向，而 `normal = -d`。
    /// 想成"士兵背靠掩体、面朝敌人"就不会搞反 —— 威胁方向与它的夹角才是 α。
    pub normal: Ang,
    /// 遮挡物高度（顶 - 地面，mm）
    pub height_mm: i32,
    /// 沿墙连续自由面的长度（mm，≤ 8 m）
    pub width_mm: i32,
    pub kind: CoverKind,
    /// 完整度（0..65535 ≡ 0..1）：被打得千疮百孔的墙，掩体价值下降
    pub solidity: u16,
    /// 容量 = `max(1, width / 800mm)`
    pub capacity: u8,
    /// 已占用数
    pub occupied: u8,
    /// 预留保持到哪一 tick
    pub reserved_until_tick: u32,
}

impl CoverSlot {
    /// 槽中心的世界坐标（mm，柱中心）。
    #[inline]
    pub const fn center_x_mm(self) -> i64 {
        self.cx as i64 * CELL_MM + CELL_MM / 2
    }
    #[inline]
    pub const fn center_z_mm(self) -> i64 {
        self.cz as i64 * CELL_MM + CELL_MM / 2
    }
    /// 是否还能进人（含预留）。
    #[inline]
    pub fn has_room(self, tick: u32) -> bool {
        if (self.occupied as i32) < self.capacity as i32 {
            return true;
        }
        tick >= self.reserved_until_tick
    }
}

/// 掩体场：槽数组 + 空间哈希（CSR）。
///
/// 生命周期：世界破坏 → 脏 chunk → `rebuild_area`（M1 先用 `rebuild_all`，
/// 破坏管线接上时再按 chunk 增量）。
#[derive(Clone, Debug, Default)]
pub struct CoverField {
    pub slots: Vec<CoverSlot>,
    /// 世界边长（柱）
    dim: i64,
    /// 每个哈希桶边长（柱）
    bucket_cells: i64,
    buckets_per_side: usize,
    bucket_ofs: Vec<u32>,
    bucket_items: Vec<u32>,
}

impl CoverField {
    pub fn new() -> Self {
        CoverField {
            slots: Vec::new(),
            dim: 0,
            bucket_cells: 8, // 4 m 一个桶：一次 18 m 查询 ≈ 覆盖 5×5 个桶
            buckets_per_side: 0,
            bucket_ofs: Vec::new(),
            bucket_items: Vec::new(),
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.slots.len()
    }
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
    #[inline]
    pub fn slot(&self, i: u32) -> Option<&CoverSlot> {
        self.slots.get(i as usize)
    }

    fn bucket_index(&self, cx: i64, cz: i64) -> usize {
        let bcx = (cx / self.bucket_cells).clamp(0, self.buckets_per_side as i64 - 1) as usize;
        let bcz = (cz / self.bucket_cells).clamp(0, self.buckets_per_side as i64 - 1) as usize;
        bcz * self.buckets_per_side + bcx
    }

    /// 全量重建（世界加载 / 测试用）。破坏管线接上后改用 `rebuild_area`。
    pub fn rebuild_all(&mut self, w: &World, hf: &HeightField) {
        self.slots.clear();
        self.dim = w.dim_cells as i64;
        self.buckets_per_side = ((self.dim + self.bucket_cells - 1) / self.bucket_cells) as usize;
        let dim = self.dim;
        for cz in 0..dim {
            for cx in 0..dim {
                self.gen_cell(w, hf, cx, cz);
            }
        }
        self.dedup_by_cell();
        self.rehash();
    }

    /// 重建一个矩形区域（世界破坏后按脏 chunk 调用）。
    pub fn rebuild_area(&mut self, w: &World, hf: &HeightField, x0: i64, z0: i64, x1: i64, z1: i64) {
        // M1 实现：剔除旧槽 + 重新生成该区域 + 重排 + 重建哈希。
        // 破坏管线（M1 后半）会按 chunk 调它，频率远低于 1 Hz，O(区域) 可接受。
        self.slots
            .retain(|s| (s.cx as i64) < x0 || (s.cx as i64) > x1 || (s.cz as i64) < z0 || (s.cz as i64) > z1);
        let dim = self.dim;
        for cz in z0.max(0)..=z1.min(dim - 1) {
            for cx in x0.max(0)..=x1.min(dim - 1) {
                self.gen_cell(w, hf, cx, cz);
            }
        }
        self.dedup_by_cell();
        self.rehash();
    }

    /// 为一个"墙柱"在它的每个自由侧面生成候选槽。
    fn gen_cell(&mut self, w: &World, hf: &HeightField, cx: i64, cz: i64) {
        let segs = w.segments(cx as u32, cz as u32);
        if segs.is_empty() {
            return;
        }
        for (dir, (dx, dz)) in DIRS.iter().enumerate() {
            let (nx, nz) = (cx + dx, cz + dz);
            let Some(n_ground) = hf.walk_top(nx, nz) else {
                continue; // 外侧站不住 → 不是槽
            };
            // 取该侧最高的、挡视线的实体段作为遮挡面
            let mut best_top: Option<i32> = None;
            let mut best_mat: u16 = 0;
            let mut best_hp: u16 = 0;
            let mut max_hp: u16 = 1;
            let mut has_gap = false; // 立面中间有洞 → 窗
            let mut prev_top = n_ground;
            for s in segs {
                if s.top_mm <= n_ground {
                    continue;
                }
                let m = w.material(s.material);
                if !m.blocks_sight {
                    continue;
                }
                if s.bottom_mm > prev_top {
                    has_gap = true;
                }
                prev_top = prev_top.max(s.top_mm);
                if best_top.map_or(true, |t| s.top_mm > t) {
                    best_top = Some(s.top_mm);
                    best_mat = s.material;
                    best_hp = s.hp;
                    max_hp = m.hp.max(1);
                }
            }
            let Some(cover_top) = best_top else { continue };
            let height = cover_top - n_ground;
            if height < MIN_HEIGHT_MM {
                continue; // 太矮，一脚跨过去了
            }
            // 槽位本身必须是空的（能站人）
            if w.overlaps(nx as u32, nz as u32, n_ground + 1, cover_top) {
                continue;
            }
            let width = self.scan_width(w, hf, (cx, cz), (nx, nz), (*dx, *dz), n_ground, cover_top);
            // 墙角：沿墙方向只有**一侧**到头了（能绕过去探头）；
            // 两侧都到头 = 一根孤零零的柱子，那是 PILLAR 不是 CORNER。
            let perp = (dz, -*dx);
            let open_pos = edge_open(
                w,
                hf,
                (cx + perp.0, cz + perp.1),
                (nx + perp.0, nz + perp.1),
                n_ground,
                cover_top,
            );
            let open_neg = edge_open(
                w,
                hf,
                (cx - perp.0, cz - perp.1),
                (nx - perp.0, nz - perp.1),
                n_ground,
                cover_top,
            );
            let is_end = open_pos != open_neg;
            let kind = classify(
                w,
                hf,
                (nx, nz),
                (*dx, *dz),
                n_ground,
                height,
                width,
                best_mat,
                has_gap,
                is_end,
            );
            let solidity = ((best_hp as u64 * 65_536) / max_hp as u64).min(65_535) as u16;
            let capacity = (width as i64 / SLOT_CAPACITY_MM).clamp(1, 255) as u8;
            self.slots.push(CoverSlot {
                cx: nx as i32,
                cz: nz as i32,
                ground_mm: n_ground,
                // normal = -d：槽在墙的 +d 侧，法线指回墙（威胁来的方向）
                normal: Ang::from_degrees(DIR_DEG[dir] + 180),
                height_mm: height,
                width_mm: width,
                kind,
                solidity,
                capacity,
                occupied: 0,
                reserved_until_tick: 0,
            });
        }
    }

    /// 沿墙扫描可用宽度（左右各扫到"墙断了/地断了/外侧被占"为止，上限 8 m）。
    fn scan_width(
        &self,
        w: &World,
        hf: &HeightField,
        wall: (i64, i64),
        slot: (i64, i64),
        d: (i64, i64),
        ground_mm: i32,
        cover_top: i32,
    ) -> i32 {
        // 墙的走向 = 方向 d 旋转 90°
        let perp = (-d.1, d.0);
        let max_cells = WIDTH_SCAN_MAX_MM / CELL_MM;
        let mut cells = 1i64; // 自己算一格
        for sign in [1i64, -1i64] {
            for k in 1..=max_cells {
                let sx = slot.0 + perp.0 * sign * k;
                let sz = slot.1 + perp.1 * sign * k;
                let Some(g) = hf.walk_top(sx, sz) else { break };
                if (g - ground_mm).abs() > 400 {
                    break; // 高差超过一级台阶 → 墙面不连续
                }
                // 对应的墙柱必须在同一高度带里是实体
                let wx = wall.0 + perp.0 * sign * k;
                let wz = wall.1 + perp.1 * sign * k;
                if !w.overlaps(wx as u32, wz as u32, ground_mm + 1, cover_top) {
                    break;
                }
                // 外侧必须是空的（能站人）
                if w.overlaps(sx as u32, sz as u32, g + 1, cover_top) {
                    break;
                }
                cells += 1;
            }
        }
        (cells * CELL_MM).min(WIDTH_SCAN_MAX_MM) as i32
    }

    /// 同一个柱可能从多个侧面生成槽（转角）→ 只保留最高的那个。
    fn dedup_by_cell(&mut self) {
        // 按 (cz, cx) 排序后线性去重：结果是确定的，与槽的生成顺序无关。
        self.slots.sort_by_key(|s| (s.cz, s.cx, -s.height_mm));
        self.slots.dedup_by_key(|s| (s.cz, s.cx));
    }

    fn rehash(&mut self) {
        let n = self.buckets_per_side * self.buckets_per_side;
        // 计数与填充都用局部变量：迭代 self.slots 的同时改 self.bucket_ofs 会触发 E0502
        let mut counts = vec![0u32; n];
        for s in self.slots.iter() {
            counts[self.bucket_index(s.cx as i64, s.cz as i64)] += 1;
        }
        let mut ofs = vec![0u32; n + 1];
        for i in 0..n {
            ofs[i + 1] = ofs[i] + counts[i];
        }
        let mut cursor = ofs.clone();
        let mut items = vec![0u32; self.slots.len()];
        for (i, s) in self.slots.iter().enumerate() {
            let b = self.bucket_index(s.cx as i64, s.cz as i64);
            items[cursor[b] as usize] = i as u32;
            cursor[b] += 1;
        }
        self.bucket_ofs = ofs;
        self.bucket_items = items;
    }

    /// 半径内的槽（粗筛，不排序）。结果写入 `out`（清空后填充）。
    pub fn slots_near(&self, x_mm: i64, z_mm: i64, r_mm: i64, out: &mut Vec<u32>) {
        out.clear();
        if self.slots.is_empty() {
            return;
        }
        let r2 = r_mm * r_mm;
        let c0x = ((x_mm - r_mm) / CELL_MM / self.bucket_cells).max(0);
        let c1x = ((x_mm + r_mm) / CELL_MM / self.bucket_cells).min(self.buckets_per_side as i64 - 1);
        let c0z = ((z_mm - r_mm) / CELL_MM / self.bucket_cells).max(0);
        let c1z = ((z_mm + r_mm) / CELL_MM / self.bucket_cells).min(self.buckets_per_side as i64 - 1);
        for bz in c0z..=c1z {
            for bx in c0x..=c1x {
                let b = (bz as usize) * self.buckets_per_side + bx as usize;
                let s0 = self.bucket_ofs[b] as usize;
                let s1 = self.bucket_ofs[b + 1] as usize;
                for i in s0..s1 {
                    let idx = self.bucket_items[i] as usize;
                    let s = &self.slots[idx];
                    let dx = s.center_x_mm() - x_mm;
                    let dz = s.center_z_mm() - z_mm;
                    if dx * dx + dz * dz <= r2 {
                        out.push(idx as u32);
                    }
                }
            }
        }
    }
}

/// 分类（优先级从上到下）。
/// 沿墙再走一格：墙还延续吗？（不延续 = 可以从这一侧绕过去探头）
fn edge_open(
    w: &World,
    hf: &HeightField,
    wall: (i64, i64),
    slot: (i64, i64),
    ground_mm: i32,
    cover_top: i32,
) -> bool {
    !w.overlaps(wall.0 as u32, wall.1 as u32, ground_mm + 1, cover_top)
        && hf.walkable(slot.0, slot.1)
}

fn classify(
    w: &World,
    hf: &HeightField,
    slot: (i64, i64),
    d: (i64, i64),
    ground_mm: i32,
    height: i32,
    width: i32,
    mat_id: u16,
    has_gap: bool,
    is_end: bool,
) -> CoverKind {
    // 战壕：槽位前面那一格（同方向再走一格）地面明显更高，且能站人 → 人在沟里
    if let Some(fg) = hf.walk_top(slot.0 + d.0, slot.1 + d.1) {
        if fg - ground_mm >= TRENCH_DEPTH_MM {
            return CoverKind::Trench;
        }
    }
    // 残骸：会被打穿（solidity 衰减快），玩法上单独分一类
    if mat_id == mat::WRECK {
        return CoverKind::Wreck;
    }
    // 窗：立面中间有洞
    if has_gap {
        return CoverKind::Window;
    }
    // 转角：槽位有 ≥2 个侧面是掩体
    let mut faces = 0;
    for (ddx, ddz) in DIRS {
        let ax = slot.0 + ddx;
        let az = slot.1 + ddz;
        if w.overlaps(ax as u32, az as u32, ground_mm + 1, ground_mm + height) {
            faces += 1;
        }
    }
    if faces >= 2 || is_end {
        return CoverKind::Corner;
    }
    if width < PILLAR_MAX_WIDTH_MM {
        return CoverKind::Pillar;
    }
    if height >= HIGH_WALL_MM {
        CoverKind::HighWall
    } else {
        CoverKind::LowWall
    }
}

// ═══════════════════════════ 有效遮挡角（§20.1.4）═══════════════════════════

/// 覆盖角（**全角**，度）：越宽的墙能挡的范围越大。
pub fn coverage_angle_deg(width_mm: i32) -> i32 {
    let extra = COVERAGE_WIDTH_DEG * width_mm / 2_000;
    (COVERAGE_BASE_DEG + extra).clamp(COVERAGE_BASE_DEG, COVERAGE_MAX_DEG)
}

/// 覆盖半角（度）。判定时一律用半角（R10）。
pub fn cover_half_angle_deg(width_mm: i32) -> i32 {
    coverage_angle_deg(width_mm) / 2
}

/// 对该威胁还"有效"吗：1.0 = 正对着，0 = 已被包抄（§20.1.4）。
///
/// **验收 B2 必须直接调用本函数，不得在测试里重述阈值**（R10）。
pub fn angular_factor(slot: &CoverSlot, threat_x_mm: i64, threat_z_mm: i64) -> Q16 {
    let dx = threat_x_mm - slot.center_x_mm();
    let dz = threat_z_mm - slot.center_z_mm();
    let dist2 = dx * dx + dz * dz;
    if dist2 == 0 {
        return Q16(65_536);
    }
    // 威胁方向（槽 → 威胁）与槽法线的夹角（半角，0..π）
    let bearing = bearing_of(dx, dz);
    let alpha = bearing.abs_diff(slot.normal) as i32; // 0..32768 ≡ 0..180°
    // 绕墙近距特判：贴着掩体绕到背面 → 直接失效
    let back = Ang::from_degrees(FLANK_BACK_DEG).raw() as i32;
    if dist2 < FLANK_DIST_MM * FLANK_DIST_MM && alpha > back {
        return Q16(0);
    }
    let half = Ang::from_degrees(cover_half_angle_deg(slot.width_mm)).raw() as i32;
    let margin = Ang::from_degrees(FLANK_MARGIN_DEG).raw() as i32;
    if alpha <= half {
        return Q16(65_536);
    }
    if alpha >= half + margin {
        return Q16(0);
    }
    // 线性衰减 1 → 0
    let num = ((alpha - half) as i64) << 16;
    let f = (num / margin as i64) as i32;
    Q16(65_536 - f)
}

/// 方位角：`(dx, dz)` → `Ang`。约定 0 = 北(-Z)，顺时针（与 `constants.ron` 一致）。
fn bearing_of(dx: i64, dz: i64) -> Ang {
    // 用查表 atan2：x = -dz（北为 +x），y = dx（东为 +y）
    sim_math::atan2(Mm(dx as i32), Mm(-dz as i32))
}

// ═══════════════════════════ 遮挡度（§20.1.3）══════════════════════════

/// M1 的威胁来源：一个已知/可疑的敌方位置。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Threat {
    pub x_mm: i32,
    pub y_mm: i32,
    pub z_mm: i32,
    /// 置信度（0..65535）；可疑目标用低值，确认目标 65535
    pub confidence: u16,
}

/// 掩体评分用的 LOD：**最高两个采样点**（头 + 胸），各 1 条射线。
///
/// 与冻结表 §6 的预算口径一致（12 候选 × 2 点 = 24 射线/次）。
/// 伤害/命中判定仍用**全部**采样点（`Posture::samples_mm`），不走这里。
fn exposure_samples(slot: &CoverSlot, posture: Posture) -> [Vec3; 2] {
    let (cx, cz) = (slot.center_x_mm(), slot.center_z_mm());
    // Peek 要沿墙面切向偏移半个身位（探出去的那半边）
    let (ox, oz) = if posture == Posture::Peek {
        let tangent = slot.normal.wrapping_add(Ang::QUARTER);
        let (ux, uz) = bearing_dir(tangent);
        (
            (ux.0 as i64 * PEEK_OFFSET_MM as i64) >> 16,
            (uz.0 as i64 * PEEK_OFFSET_MM as i64) >> 16,
        )
    } else {
        (0, 0)
    };
    let s = posture.samples_mm();
    let y0 = slot.ground_mm + s[0];
    let y1 = slot.ground_mm + s[1];
    [
        Vec3::new(Mm((cx + ox) as i32), Mm(y0), Mm((cz + oz) as i32)),
        Vec3::new(Mm((cx + ox) as i32), Mm(y1), Mm((cz + oz) as i32)),
    ]
}

/// 方位角 → 单位方向（x, z），Q16。
fn bearing_dir(a: Ang) -> (Q16, Q16) {
    (a.sin(), Q16(-a.cos().0))
}

/// 加权遮挡度（0..1，Q16）：对每个威胁按"置信度 × 距离权重"加权平均
/// `blocking × angular_factor`。
///
/// 只用于**掩体评分**与**暴露度**；命中判定一律走逐点 `ray::blocked`（§20.1.3.1）。
pub fn blocking_aggregate(
    w: &World,
    slot: &CoverSlot,
    posture: Option<Posture>,
    threats: &[Threat],
) -> Q16 {
    let posture = posture.unwrap_or_else(|| slot.kind.best_posture());
    if threats.is_empty() {
        // 没有已知威胁：退化为"这堵墙本身有多高"（相对姿态），只是个排序用的量
        let eye = slot.ground_mm + posture.eye_mm();
        let covered = if eye <= slot.ground_mm + slot.height_mm {
            65_536
        } else {
            0
        };
        return Q16(covered);
    }
    let pts = exposure_samples(slot, posture);
    let ws = posture.samples_w();
    // 头 + 胸两点的权重归一化（Q16）
    let wsum = ws[0] + ws[1];
    let w0 = ((ws[0] as i64) << 16) / wsum as i64;
    let w1 = ((ws[1] as i64) << 16) / wsum as i64;

    let mut acc: i64 = 0;
    let mut wacc: i64 = 0;
    for t in threats {
        let dx = t.x_mm as i64 - slot.center_x_mm();
        let dz = t.z_mm as i64 - slot.center_z_mm();
        let dist = isqrt_i64(dx * dx + dz * dz).max(1);
        // 距离权重：近的威胁更该防（1/(1 + d/40m)，Q16）
        let dw = (65_536i64 * 40_000) / (40_000 + dist);
        let weight = (t.confidence as i64 * dw) >> 16;
        if weight <= 0 {
            continue;
        }
        // 射手眼睛位置
        let eye = Vec3::new(Mm(t.x_mm), Mm(t.y_mm + Posture::Stand.eye_mm()), Mm(t.z_mm));
        let mut blocked_w = 0i64;
        blocked_w += if blocked(w, eye, pts[0], RayMode::Sight) {
            w0
        } else {
            0
        };
        blocked_w += if blocked(w, eye, pts[1], RayMode::Sight) {
            w1
        } else {
            0
        };
        // 有效遮挡角：被包抄的掩体对这个威胁没有价值
        let af = angular_factor(slot, t.x_mm as i64, t.z_mm as i64);
        let b = (blocked_w * af.0 as i64) >> 16;
        acc += b * weight;
        wacc += weight << 16;
    }
    if wacc == 0 {
        return Q16(0);
    }
    Q16((acc / (wacc >> 16)).max(0).min(65_536) as i32)
}

fn isqrt_i64(n: i64) -> i64 {
    sim_math::isqrt_i64(n)
}

/// 在**任意位置**（不一定站在槽里）评估遮挡度 —— 验收与调试用。
///
/// 做法：就地造一个"临时槽"（法线朝向主威胁，宽度 1 柱），再走同一个
/// `blocking_aggregate`。这样"验收看到的值"和"AI 选槽用的值"是同一个函数。
pub fn blocking_at(
    w: &World,
    hf: &HeightField,
    x_mm: i64,
    z_mm: i64,
    posture: Option<Posture>,
    threats: &[Threat],
) -> Q16 {
    let cx = (x_mm / CELL_MM) as i32;
    let cz = (z_mm / CELL_MM) as i32;
    let Some(ground_mm) = hf.walk_top(cx as i64, cz as i64) else {
        return Q16(0);
    };
    let normal = if let Some(t) = threats.first() {
        bearing_of(t.x_mm as i64 - x_mm, t.z_mm as i64 - z_mm)
    } else {
        Ang::ZERO
    };
    let slot = CoverSlot {
        cx,
        cz,
        ground_mm,
        normal,
        height_mm: 0,
        width_mm: CELL_MM as i32,
        kind: CoverKind::LowWall,
        solidity: 65_535,
        capacity: 1,
        occupied: 0,
        reserved_until_tick: 0,
    };
    blocking_aggregate(w, &slot, posture, threats)
}

impl CoverField {
    /// 全场的确定性校验和（跨平台逐位比对用，与 `World::checksum` 同一套 FNV）。
    pub fn checksum(&self) -> u64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        let mut push = |v: u64| {
            for b in v.to_le_bytes() {
                h ^= u64::from(b);
                h = h.wrapping_mul(0x100_0000_01b3);
            }
        };
        push(self.slots.len() as u64);
        for s in self.slots.iter() {
            push(s.cx as u64);
            push(s.cz as u64);
            push(s.ground_mm as u64);
            push(s.normal.raw() as u64);
            push(s.height_mm as u64);
            push(s.width_mm as u64);
            push(s.kind as u64);
            push(s.solidity as u64);
            push(s.capacity as u64);
        }
        h
    }
}

// ═══════════════════════════ 选槽（§20.1.5 的 M1 子集）══════════════════════════

/// 选槽结果。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct CoverChoice {
    /// 槽索引
    pub slot: u32,
    /// 分数（Q16，仅用于比较/调试）
    pub score: Q16,
}

/// 挑一个掩体槽。
///
/// M1 只启用 4 项：`block / angle / reach / crowd`。
/// `escape / firesupport / suppression / objective / leader` 恒为 0（M2 再接，见文件头注释）。
///
/// 射线预算：候选 ≤ 12，每个只对**主威胁**做 2 条射线 = 24 条；
/// top-3 再对全部威胁复核（≤ +12 条）。
pub fn pick_cover(
    w: &World,
    field: &CoverField,
    from_x_mm: i64,
    from_z_mm: i64,
    posture: Option<Posture>,
    threats: &[Threat],
    max_candidates: usize,
    scratch: &mut Vec<u32>,
) -> Option<CoverChoice> {
    field.slots_near(from_x_mm, from_z_mm, SEARCH_RADIUS_MM, scratch);
    if scratch.is_empty() {
        return None;
    }
    // 主威胁：置信度 × 距离权重最大者
    let primary: Option<Threat> = threats
        .iter()
        .copied()
        .max_by_key(|t| {
            let d = isqrt_i64(
                (t.x_mm as i64 - from_x_mm) * (t.x_mm as i64 - from_x_mm)
                    + (t.z_mm as i64 - from_z_mm) * (t.z_mm as i64 - from_z_mm),
            )
            .max(1);
            (t.confidence as i64 * 40_000) / (40_000 + d)
        });

    // 便宜的预筛：主威胁下完全失效的（被包抄）直接丢掉
    let mut cands: Vec<u32> = Vec::with_capacity(scratch.len());
    for &i in scratch.iter() {
        let s = match field.slot(i) {
            Some(s) => s,
            None => continue,
        };
        if let Some(t) = primary {
            if angular_factor(s, t.x_mm as i64, t.z_mm as i64).0 == 0 {
                continue;
            }
        }
        cands.push(i);
    }
    if cands.is_empty() {
        return None;
    }
    // "走得到的优先"：脚边有掩体就别横穿 18 m 开阔地。
    // 没有走得到的（比如刚落地在广场中央），才退回到全部候选里挑。
    let reachable: Vec<u32> = cands
        .iter()
        .copied()
        .filter(|&i| {
            let s = &field.slots[i as usize];
            let dx = s.center_x_mm() - from_x_mm;
            let dz = s.center_z_mm() - from_z_mm;
            isqrt_i64(dx * dx + dz * dz) / RUSH_MM_PER_TICK < REACH_HORIZON_TICKS
        })
        .collect();
    let pool: &[u32] = if reachable.is_empty() {
        &cands
    } else {
        &reachable
    };

    // 按"离得近 + 墙高"排序取前 K（便宜的启发式，之后才做射线）
    let mut pool_sorted: Vec<u32> = pool.to_vec();
    pool_sorted.sort_by_key(|&i| {
        let s = &field.slots[i as usize];
        let dx = s.center_x_mm() - from_x_mm;
        let dz = s.center_z_mm() - from_z_mm;
        let d2 = dx * dx + dz * dz;
        // 距离优先，同距离下高的墙优先（负号 = 大者优先）
        (d2 / 1_000_000, -s.height_mm as i64)
    });
    let k = max_candidates.min(pool_sorted.len());
    let cands = &pool_sorted[..k];

    let one = [primary.unwrap_or(Threat { x_mm: 0, y_mm: 0, z_mm: 0, confidence: 0 })];
    let primary_slice: &[Threat] = if primary.is_some() { &one } else { &[] };

    let mut best: Option<CoverChoice> = None;
    for &i in cands {
        let s = &field.slots[i as usize];
        let b = blocking_aggregate(w, s, posture, primary_slice);
        let sc = score_slot(w, field, s, from_x_mm, from_z_mm, b, primary_slice);
        if best.map_or(true, |c| sc.0 > c.score.0) {
            best = Some(CoverChoice { slot: i, score: sc });
        }
    }
    // top-3 对全部威胁复核（避免"只防住一个人"的槽）
    if threats.len() > 1 {
        let mut ranked: Vec<(i32, u32)> = cands
            .iter()
            .map(|&i| {
                let s = &field.slots[i as usize];
                (blocking_aggregate(w, s, posture, threats).0, i)
            })
            .collect();
        ranked.sort_by_key(|(b, _)| -*b);
        for (b, i) in ranked.into_iter().take(3) {
            let s = &field.slots[i as usize];
            let sc = score_slot(w, field, s, from_x_mm, from_z_mm, Q16(b), threats);
            if best.map_or(true, |c| sc.0 > c.score.0) {
                best = Some(CoverChoice { slot: i, score: sc });
            }
        }
    }
    best
}

/// 评分：M1 的四项。权重见文件头的 `W_*` 常量。
fn score_slot(
    _w: &World,
    _field: &CoverField,
    slot: &CoverSlot,
    from_x_mm: i64,
    from_z_mm: i64,
    block: Q16,
    threats: &[Threat],
) -> Q16 {
    // block：最重要
    let mut score = (W_BLOCK as i64 * block.0 as i64) >> 16;

    // angle：是否面对主要威胁（取各威胁 angular_factor 的最大值）
    let mut angle = 0i64;
    for t in threats {
        let a = angular_factor(slot, t.x_mm as i64, t.z_mm as i64).0 as i64;
        angle = angle.max(a);
    }
    score += (W_ANGLE as i64 * angle) >> 16;

    // reach：到达时间的反比（§20.1.5）—— 走不到就等于没有
    let dx = slot.center_x_mm() - from_x_mm;
    let dz = slot.center_z_mm() - from_z_mm;
    let d = isqrt_i64(dx * dx + dz * dz);
    let travel_ticks = d / RUSH_MM_PER_TICK;
    let reach = if travel_ticks >= REACH_HORIZON_TICKS {
        0
    } else {
        65_536 - ((travel_ticks << 16) / REACH_HORIZON_TICKS)
    };
    score += (W_REACH as i64 * reach) >> 16;

    // crowd：挤了就扣分
    let crowd = if slot.capacity > 0 {
        ((slot.occupied as i64) << 16) / slot.capacity as i64
    } else {
        65_536
    };
    score -= (W_CROWD as i64 * crowd) >> 16;

    // solidity：打得千疮百孔的墙价值下降（M1：线性）
    score = (score * slot.solidity as i64) >> 16;

    Q16(score.clamp(i32::MIN as i64, i32::MAX as i64) as i32)
}

// ═══════════════════════════ 单元测试（快速自洽性）══════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nav::NavParams;
    use crate::world::Segment;

    /// 建一个平地世界，在中间放一堵东西向的墙，返回 (world, hf)。
    /// dim 必须是 chunk（32）的整数倍，否则 `World::new` 会 panic。
    fn world_with_wall(dim: u32, wall_z: i64, height_mm: i32) -> (World, HeightField) {
        let mut w = World::new_flat(dim, 32, -8_000);
        for x in 2..(dim as i64 - 2) {
            w.push_segment(
                x as u32,
                wall_z as u32,
                Segment::new(0, height_mm, mat::CONCRETE, 1000),
            );
        }
        let mut hf = HeightField::new(dim);
        hf.rebuild_all(&w, &NavParams::default());
        (w, hf)
    }

    #[test]
    fn wall_generates_slots_on_both_sides() {
        let (w, hf) = world_with_wall(32, 16, 1_500);
        let mut f = CoverField::new();
        f.rebuild_all(&w, &hf);
        assert!(!f.is_empty(), "墙两侧都应该生成槽");
        let mut north = 0;
        let mut south = 0;
        for s in f.slots.iter() {
            assert_eq!(s.height_mm, 1_500);
            if s.cz < 16 {
                north += 1;
            } else if s.cz > 16 {
                south += 1;
            }
        }
        assert!(north > 0 && south > 0, "两侧都要有槽: n={north} s={south}");
    }

    #[test]
    fn low_wall_vs_high_wall_classification() {
        let (w, hf) = world_with_wall(32, 16, 800); // 0.8 m → 矮墙
        let mut f = CoverField::new();
        f.rebuild_all(&w, &hf);
        // 注意：墙两端的"端头槽"是 CORNER（能绕过去探头），只对中段断言
        assert!(f
            .slots
            .iter()
            .filter(|s| s.cx >= 4 && s.cx <= 27)
            .all(|s| s.kind == CoverKind::LowWall));

        let (w2, hf2) = world_with_wall(32, 16, 1_500); // 1.5 m → 高墙
        let mut f2 = CoverField::new();
        f2.rebuild_all(&w2, &hf2);
        assert!(f2
            .slots
            .iter()
            .filter(|s| s.cx >= 4 && s.cx <= 27)
            .all(|s| s.kind == CoverKind::HighWall));
        // 端头必须是 CORNER（这是最经典的"探头位"）
        assert!(f2.slots.iter().any(|s| s.kind == CoverKind::Corner));
    }

    #[test]
    fn angular_factor_front_is_full_and_back_is_zero() {
        let slot = CoverSlot {
            cx: 8,
            cz: 9,
            ground_mm: 0,
            normal: Ang::from_degrees(180), // 法线朝南(+Z)
            height_mm: 1_500,
            width_mm: 4_000,
            kind: CoverKind::HighWall,
            solidity: 65_535,
            capacity: 5,
            occupied: 0,
            reserved_until_tick: 0,
        };
        let (sx, sz) = (slot.center_x_mm(), slot.center_z_mm());
        // 正南 10 m：法线方向 → 满值
        assert_eq!(angular_factor(&slot, sx, sz + 10_000).0, 65_536);
        // 正北 10 m：背面 → 0（超过半角 + 25°）
        assert_eq!(angular_factor(&slot, sx, sz - 10_000).0, 0);
    }

    #[test]
    fn blocking_high_when_behind_wall() {
        let (w, hf) = world_with_wall(32, 16, 1_500);
        let mut f = CoverField::new();
        f.rebuild_all(&w, &hf);
        // 找一个墙北侧、正对墙的槽
        let idx = f
            .slots
            .iter()
            .position(|s| s.cz == 15 && s.cx == 16)
            .expect("墙北侧应当有槽");
        let slot = f.slots[idx];
        // 威胁在墙的另一侧（南边 10 m）
        let t = Threat {
            x_mm: slot.center_x_mm() as i32,
            y_mm: 0,
            z_mm: slot.center_z_mm() as i32 + 10_000,
            confidence: 65_535,
        };
        let b = blocking_aggregate(&w, &slot, Some(Posture::Crouch), &[t]);
        assert!(b.0 > 60_000, "蹲在 1.5m 墙后应几乎全挡住，实际 {b:?}");
        // 站立时头露出来 → 遮挡下降
        let bs = blocking_aggregate(&w, &slot, Some(Posture::Stand), &[t]);
        assert!(bs.0 < b.0, "站立应比蹲下暴露更多: stand={bs:?} crouch={b:?}");
    }
}
