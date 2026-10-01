//! 2D 导航：可行走高度场 + 流场（设计文档 §10.5.2 / R4）
//!
//! 地表与单层建筑用 **2D 代价场 + flow field**（每柱一个可行走高度 = 该柱最高可站立顶面）；
//! 多层室内与地道是**显式图**（M1 之后），本模块只做地表这一层，
//! 但把"额外代价"接口留好了 —— M2 的威胁场（8m 栅格）直接作为 `extra` 叠加进来，
//! 于是"绕开正在被机枪扫射的空地"就是同一套 Dijkstra 的自然结果（§20.2.5）。
//!
//! **确定性**：堆的序是 `(cost, cell_index)` 的**全序**（同代价时索引小者先出堆），
//! Dijkstra 的代价唯一 ⇒ 首次赋值必然来自最小的 `(cost, index)` 前驱。
//! 因此不依赖线程调度、不依赖插入顺序，三平台逐位一致。
//! 这里**故意不使用** `rayon` 并行：并行 Dijkstra 的结果依赖归约顺序，会毁掉 lockstep。

use crate::world::World;
use sim_math::isqrt_i64;
use core::cmp::Reverse;
use std::collections::BinaryHeap;

/// 该柱不可站立（虚空 / 顶上没有净空 / 顶面站不住）
pub const NO_WALK: i32 = i32::MIN;
/// 流场里"不可达"的代价
pub const UNREACHABLE: u32 = u32::MAX;
/// 没有后继（目标柱自身，或不可达）
pub const NO_NEXT: u32 = u32::MAX;

/// 8 邻域：前 4 个正交，后 4 个对角（顺序即方向索引）
pub const DIRS: [(i64, i64); 8] = [
    (1, 0),
    (-1, 0),
    (0, 1),
    (0, -1),
    (1, 1),
    (1, -1),
    (-1, 1),
    (-1, -1),
];

/// 导航参数。与 `sim/data/constants.ron` 的 `nav` 段一一对应，由调用方填入
/// （sim 核心不读文件，保持无 I/O、无浮点）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct NavParams {
    /// 站立所需的垂直净空（mm）
    pub clearance_mm: i32,
    /// 能直接跨上的台阶高度（mm）
    pub step_up_mm: i32,
    /// 能直接走下的落差（mm）
    pub step_down_mm: i32,
    /// 正交一步的代价
    pub cost_ortho: u32,
    /// 对角一步的代价（≈ 正交 × √2）
    pub cost_diag: u32,
}

impl Default for NavParams {
    /// 默认值 = `constants.ron` 的 `nav` 段；改常量时**两处都要改**（`check_constants.py` 校验文档与 ron）。
    fn default() -> Self {
        NavParams {
            clearance_mm: 1900,
            step_up_mm: 400,
            step_down_mm: 700,
            cost_ortho: 10000,
            cost_diag: 14142,
        }
    }
}

/// 可行走高度场：每柱一个"最高可站立顶面"（mm）。
///
/// 只保存**一个**高度 —— 这是 §10.5.2 冻结的表示：桥下与桥面在同一 XZ 上共存时，
/// 这个 2D 场只能表达桥面（更高的那个），桥下走显式图（M1+）。
#[derive(Clone)]
pub struct HeightField {
    dim: usize,
    top: Vec<i32>,
}

impl HeightField {
    pub fn new(dim_cells: u32) -> Self {
        let dim = dim_cells as usize;
        HeightField {
            dim,
            top: vec![NO_WALK; dim * dim],
        }
    }

    #[inline]
    pub fn dim(&self) -> usize {
        self.dim
    }

    #[inline]
    fn idx(&self, cx: i64, cz: i64) -> Option<usize> {
        if cx < 0 || cz < 0 {
            return None;
        }
        let (x, z) = (cx as usize, cz as usize);
        if x >= self.dim || z >= self.dim {
            return None;
        }
        Some(z * self.dim + x)
    }

    /// 全量重建（地图加载 / 大规模破坏后的兜底）。
    pub fn rebuild_all(&mut self, w: &World, p: &NavParams) {
        let dim = self.dim;
        for cz in 0..dim {
            for cx in 0..dim {
                self.top[cz * dim + cx] =
                    standable_top(w, cx as u32, cz as u32, p).unwrap_or(NO_WALK);
            }
        }
    }

    /// 单柱重建。
    pub fn rebuild_cell(&mut self, w: &World, cx: i64, cz: i64, p: &NavParams) {
        if let Some(i) = self.idx(cx, cz) {
            self.top[i] = standable_top(w, cx as u32, cz as u32, p).unwrap_or(NO_WALK);
        }
    }

    /// 矩形区域重建（脏 chunk 增量重算；范围会被裁剪到地图内）。
    pub fn rebuild_area(&mut self, w: &World, x0: i64, z0: i64, x1: i64, z1: i64, p: &NavParams) {
        let lim = self.dim as i64;
        let z_lo = if z0 < 0 { 0 } else { z0 };
        let z_hi = if z1 > lim { lim } else { z1 };
        let x_lo = if x0 < 0 { 0 } else { x0 };
        let x_hi = if x1 > lim { lim } else { x1 };
        for cz in z_lo..z_hi {
            for cx in x_lo..x_hi {
                self.rebuild_cell(w, cx, cz, p);
            }
        }
    }

    /// 该柱的可站立顶面（mm）；不可站立返回 `None`。
    #[inline]
    pub fn walk_top(&self, cx: i64, cz: i64) -> Option<i32> {
        let i = self.idx(cx, cz)?;
        let t = self.top[i];
        if t == NO_WALK {
            None
        } else {
            Some(t)
        }
    }

    #[inline]
    pub fn walkable(&self, cx: i64, cz: i64) -> bool {
        self.walk_top(cx, cz).is_some()
    }

    /// 从 `(fx,fz)` 走到相邻柱 `(tx,tz)` 是否可行：终点要能站、落差在
    /// `[−step_down, +step_up]` 之内（阶梯近似，R4）。
    pub fn can_step(&self, fx: i64, fz: i64, tx: i64, tz: i64, p: &NavParams) -> bool {
        let a = match self.walk_top(fx, fz) {
            Some(v) => v,
            None => return false,
        };
        let b = match self.walk_top(tx, tz) {
            Some(v) => v,
            None => return false,
        };
        let d = b - a;
        d <= p.step_up_mm && -d <= p.step_down_mm
    }
}

/// 该柱"最高可站立顶面"：从高到低找**第一个**顶面以上有 `clearance` 净空的实体段。
///
/// 两条判定：
/// 1. 脚下的段必须"站得住"（`Material::standable()`）—— 铁丝网挡路，但站不上去；
/// 2. 头顶 `clearance` 的区间必须**完全空**（半开区间，见 `World::overlaps`）。
fn standable_top(w: &World, cx: u32, cz: u32, p: &NavParams) -> Option<i32> {
    let segs = w.segments(cx, cz);
    // 段按 bottom 升序 ⇒ 从高到低遍历
    for s in segs.iter().rev() {
        if !w.material(s.material).standable() {
            continue;
        }
        let top = s.top_mm;
        if !w.overlaps(cx, cz, top, top.saturating_add(p.clearance_mm)) {
            return Some(top);
        }
    }
    None
}

/// 流场：从目标反向 Dijkstra，得到每柱的累计代价与"下一格"。
///
/// 一个目标一个场；单位只查表，不寻路 —— 400 个单位共用一个场，成本与单位数无关。
pub struct FlowField {
    dim: usize,
    cost: Vec<u32>,
    next: Vec<u32>,
    goal: (i64, i64),
    /// 作用半径（切比雪夫距离，柱）；0 = 不限
    radius_cells: i64,
    reached: usize,
}

impl FlowField {
    pub fn new(dim_cells: u32) -> Self {
        let dim = dim_cells as usize;
        FlowField {
            dim,
            cost: vec![UNREACHABLE; dim * dim],
            next: vec![NO_NEXT; dim * dim],
            goal: (0, 0),
            radius_cells: 0,
            reached: 0,
        }
    }

    #[inline]
    pub fn dim(&self) -> usize {
        self.dim
    }

    #[inline]
    pub fn goal(&self) -> (i64, i64) {
        self.goal
    }

    /// 本次计算覆盖到的柱数（可用于判断"目标被完全围死"）
    #[inline]
    pub fn reached_cells(&self) -> usize {
        self.reached
    }

    /// 作用半径（0 = 不限）。全图 2048² = 419 万柱的 Dijkstra 太贵，
    /// 所以实战里每个班组目标的场都限半径（冻结值 `nav.radius_mm`）。
    #[inline]
    pub fn set_radius_cells(&mut self, cells: i64) {
        self.radius_cells = if cells < 0 { 0 } else { cells };
    }

    #[inline]
    fn idx(&self, cx: i64, cz: i64) -> Option<usize> {
        if cx < 0 || cz < 0 {
            return None;
        }
        let (x, z) = (cx as usize, cz as usize);
        if x >= self.dim || z >= self.dim {
            return None;
        }
        Some(z * self.dim + x)
    }

    /// 该柱到目标的累计代价；不可达返回 `UNREACHABLE`。
    #[inline]
    pub fn cost_at(&self, cx: i64, cz: i64) -> u32 {
        match self.idx(cx, cz) {
            Some(i) => self.cost[i],
            None => UNREACHABLE,
        }
    }

    #[inline]
    pub fn reachable(&self, cx: i64, cz: i64) -> bool {
        self.cost_at(cx, cz) != UNREACHABLE
    }

    /// 该柱的"下一格"（朝目标）；目标自身与不可达返回 `None`。
    pub fn next_cell(&self, cx: i64, cz: i64) -> Option<(i64, i64)> {
        let i = self.idx(cx, cz)?;
        let n = self.next[i];
        if n == NO_NEXT {
            return None;
        }
        let dim = self.dim as u32;
        Some(((n % dim) as i64, (n / dim) as i64))
    }

    /// 同 `next_cell`，返回相对偏移 `(dx, dz)`（每个分量 ∈ {−1,0,1}）。
    pub fn dir_at(&self, cx: i64, cz: i64) -> Option<(i64, i64)> {
        let (nx, nz) = self.next_cell(cx, cz)?;
        Some((nx - cx, nz - cz))
    }

    /// 计算流场。
    ///
    /// - 目标柱不可站立 ⇒ 得到空场（调用方应换一个目标点，见 `nearest_walkable`）；
    /// - `extra` 是每柱的附加代价（M2 的威胁场），`None` 表示纯距离场。
    pub fn compute(
        &mut self,
        hf: &HeightField,
        goal: (i64, i64),
        p: &NavParams,
        extra: Option<&[u32]>,
    ) {
        let dim = self.dim;
        assert_eq!(hf.dim(), dim, "高度场与流场的维度必须一致");
        for c in self.cost.iter_mut() {
            *c = UNREACHABLE;
        }
        for n in self.next.iter_mut() {
            *n = NO_NEXT;
        }
        self.goal = goal;
        self.reached = 0;

        let gi = match self.idx(goal.0, goal.1) {
            Some(i) => i,
            None => return,
        };
        if !hf.walkable(goal.0, goal.1) {
            return; // 目标站不住 → 空场
        }
        if let Some(e) = extra {
            assert_eq!(e.len(), dim * dim, "附加代价场的长度必须与柱数一致");
        }

        // 堆项 = (Reverse(代价), Reverse(柱索引))：同代价时索引小者先出堆 ⇒ 全序、确定性
        let mut heap: BinaryHeap<(Reverse<u32>, Reverse<u32>)> = BinaryHeap::new();
        self.cost[gi] = 0;
        heap.push((Reverse(0), Reverse(gi as u32)));

        while let Some((Reverse(c), Reverse(vi))) = heap.pop() {
            let vi = vi as usize;
            if c > self.cost[vi] {
                continue; // 惰性删除：这是过期堆项
            }
            let (vx, vz) = ((vi % dim) as i64, (vi / dim) as i64);
            for (d, dir) in DIRS.iter().enumerate() {
                let (ux, uz) = (vx + dir.0, vz + dir.1);
                let ui = match self.idx(ux, uz) {
                    Some(i) => i,
                    None => continue,
                };
                if self.radius_cells > 0
                    && (ux - goal.0).abs().max((uz - goal.1).abs()) > self.radius_cells
                {
                    continue;
                }
                // u 要能走到 v（更靠近目标的一侧）
                if !hf.can_step(ux, uz, vx, vz, p) {
                    continue;
                }
                if d >= 4 {
                    // 不切角：两个正交邻居都必须能走，否则会从墙角"穿"过去
                    if !hf.can_step(ux, uz, vx, uz, p) || !hf.can_step(ux, uz, ux, vz, p) {
                        continue;
                    }
                }
                let step = if d >= 4 { p.cost_diag } else { p.cost_ortho };
                let add = match extra {
                    Some(e) => e[ui],
                    None => 0,
                };
                let nc = c.saturating_add(step).saturating_add(add);
                if nc < self.cost[ui] {
                    self.cost[ui] = nc;
                    self.next[ui] = vi as u32;
                    heap.push((Reverse(nc), Reverse(ui as u32)));
                }
            }
        }

        self.reached = self.cost.iter().filter(|c| **c != UNREACHABLE).count();
    }
}

/// 从 `pos` 朝 `target` 走一步，最多走 `max_step_mm`（全整数：长度用整数开方，缩放用整除）。
///
/// 距离 ≤ 步长时直接到达（不会过冲抖动）。这是"单位沿流场走"的位移函数，
/// 命令行工具与 Godot 绑定共用同一个 —— 两处走同一条路，表现层才不会和 sim 分叉。
#[inline]
pub fn step_toward(pos: (i64, i64), target: (i64, i64), max_step_mm: i64) -> (i64, i64) {
    let dx = target.0 - pos.0;
    let dz = target.1 - pos.1;
    if dx * dx + dz * dz <= max_step_mm * max_step_mm {
        return target;
    }
    let d = isqrt_i64(dx * dx + dz * dz).max(1);
    (pos.0 + dx * max_step_mm / d, pos.1 + dz * max_step_mm / d)
}

/// 目标点落在不可站立的柱上（墙里 / 空中）时，找最近的可站立柱（切比雪夫搜索）。
///
/// 半径用**柱**计：目标通常只偏一两格，全图搜索在这里没有意义。
pub fn nearest_walkable(
    hf: &HeightField,
    cx: i64,
    cz: i64,
    max_radius_cells: i64,
) -> Option<(i64, i64)> {
    if hf.walkable(cx, cz) {
        return Some((cx, cz));
    }
    for r in 1..=max_radius_cells {
        for dz in -r..=r {
            for dx in -r..=r {
                if dx.abs() != r && dz.abs() != r {
                    continue; // 只扫外圈
                }
                let (nx, nz) = (cx + dx, cz + dz);
                if hf.walkable(nx, nz) {
                    return Some((nx, nz));
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::{mat, Segment};

    fn params() -> NavParams {
        NavParams::default()
    }

    /// 一块平地（地面段 [-8000, 0]）；`extra` 只加在 (3,3) 上，避免影响其他用例
    fn flat_world(dim: u32, extra: Option<Segment>) -> World {
        let mut w = World::new(dim, 4);
        for cz in 0..dim {
            for cx in 0..dim {
                w.push_segment(cx, cz, Segment::new(-8000, 0, mat::GROUND, u16::MAX));
                if let Some(s) = extra {
                    if cx == 3 && cz == 3 {
                        w.push_segment(cx, cz, s);
                    }
                }
            }
        }
        w
    }

    #[test]
    fn flat_ground_is_walkable_everywhere() {
        let w = flat_world(8, None);
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        for cz in 0..8 {
            for cx in 0..8 {
                assert_eq!(hf.walk_top(cx, cz), Some(0), "({}, {})", cx, cz);
            }
        }
        assert!(hf.can_step(0, 0, 1, 1, &params()));
    }

    #[test]
    fn void_columns_are_unwalkable() {
        let w = World::new(8, 4); // 没有地面
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        assert_eq!(hf.walk_top(4, 4), None);
        assert!(!hf.walkable(4, 4));
        assert!(!hf.can_step(4, 4, 4, 5, &params()));
    }

    #[test]
    fn bridge_deck_is_walkable_but_you_cannot_climb_it() {
        // 桥面 [1000,1500] 悬在地面之上：2D 高度场只能表达"更高的那个"（桥面），
        // 桥下的通行空间要等显式图（§10.5.2，M1+）
        let w = flat_world(8, Some(Segment::new(1000, 1500, mat::CONCRETE, 600)));
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        assert_eq!(hf.walk_top(3, 3), Some(1500), "桥面可站立");
        assert_eq!(hf.walk_top(2, 2), Some(0), "旁边是地面");
        assert!(!hf.can_step(2, 3, 3, 3, &params()), "1500mm 高差跨不上去（要坡道/楼梯）");
    }

    #[test]
    fn wire_blocks_the_column_and_is_not_a_surface() {
        let w = flat_world(4, Some(Segment::new(0, 1000, mat::WIRE, 30)));
        let mut hf = HeightField::new(4);
        hf.rebuild_all(&w, &params());
        // 铁丝网：能看见、能打穿、走不过，而且**站不到它顶上** ⇒ 该柱不可通行
        assert_eq!(hf.walk_top(3, 3), None);
        assert!(!hf.walkable(3, 3));
        assert_eq!(hf.walk_top(2, 2), Some(0));
    }

    #[test]
    fn step_up_and_down_limits() {
        let p = params();
        let mut w = World::new(4, 4);
        for cz in 0..4 {
            for cx in 0..4 {
                w.push_segment(cx, cz, Segment::new(-8000, 0, mat::GROUND, u16::MAX));
            }
        }
        w.push_segment(1, 0, Segment::new(0, 300, mat::CONCRETE, 600)); // 能跨上（300 ≤ 400）
        w.push_segment(2, 0, Segment::new(0, 900, mat::CONCRETE, 600)); // 太高
        let mut hf = HeightField::new(4);
        hf.rebuild_all(&w, &p);
        assert_eq!(hf.walk_top(1, 0), Some(300));
        assert_eq!(hf.walk_top(2, 0), Some(900));
        assert!(hf.can_step(0, 0, 1, 0, &p), "300mm 台阶应该能跨上");
        assert!(!hf.can_step(0, 0, 2, 0, &p), "900mm 不该能跨上");
        assert!(!hf.can_step(2, 0, 0, 0, &p), "900mm 落差超过 step_down(700)");
        assert!(hf.can_step(1, 0, 0, 0, &p), "300mm 落差可以走下");
    }

    #[test]
    fn wall_top_is_standable_but_unreachable_on_foot() {
        // 墙顶是实体顶面（能站），但 3000mm 高差远超 step_up ⇒ 走不上去。
        // 这正是"二维场靠 can_step 挡住爬墙"的机制，别改成"墙柱不可站立"
        // （那样会把"被炸矮的墙"也一起排除掉）。
        let mut w = flat_world(8, None);
        for cz in 0..8 {
            w.push_segment(4, cz, Segment::new(0, 3000, mat::CONCRETE, 600));
        }
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        assert_eq!(hf.walk_top(4, 4), Some(3000));
        assert!(!hf.can_step(3, 4, 4, 4, &params()));
        assert!(!hf.can_step(4, 4, 3, 4, &params()));
    }

    #[test]
    fn flow_field_shortest_path_on_flat_ground() {
        let w = flat_world(8, None);
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        let mut ff = FlowField::new(8);
        ff.compute(&hf, (7, 7), &params(), None);
        // 平地对角：7 步对角 = 7 × 14142
        assert_eq!(ff.cost_at(0, 0), 7 * 14142);
        assert_eq!(ff.reached_cells(), 64);
        // 从 (0,0) 一路跟到底必须到达目标，且不长于 7 步
        let mut cur = (0i64, 0i64);
        let mut steps = 0;
        while let Some(n) = ff.next_cell(cur.0, cur.1) {
            cur = n;
            steps += 1;
            assert!(steps <= 7, "流场出现了环或绕路");
        }
        assert_eq!(cur, (7, 7));
        assert_eq!(steps, 7);
    }

    #[test]
    fn flow_field_routes_around_a_wall() {
        let p = params();
        let mut w = flat_world(8, None);
        // x=4 立一堵贯穿墙，只留 z=0 一个缺口
        for cz in 1..8 {
            w.push_segment(4, cz, Segment::new(0, 3000, mat::CONCRETE, 600));
        }
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &p);
        let mut ff = FlowField::new(8);
        ff.compute(&hf, (7, 4), &p, None);
        assert!(ff.reachable(0, 4), "应该能绕过去");
        let mut cur = (0i64, 4i64);
        let mut steps = 0;
        while let Some(n) = ff.next_cell(cur.0, cur.1) {
            assert!(!(n.0 == 4 && n.1 >= 1), "路线穿墙了：{:?}", n);
            cur = n;
            steps += 1;
            assert!(steps < 200);
        }
        assert_eq!(cur, (7, 4));
    }

    #[test]
    fn no_corner_cutting() {
        let p = params();
        let mut w = flat_world(4, None);
        // (1,0) 与 (0,1) 都立墙 ⇒ 不允许从 (0,0) 斜穿到 (1,1)
        w.push_segment(1, 0, Segment::new(0, 3000, mat::CONCRETE, 600));
        w.push_segment(0, 1, Segment::new(0, 3000, mat::CONCRETE, 600));
        let mut hf = HeightField::new(4);
        hf.rebuild_all(&w, &p);
        let mut ff = FlowField::new(4);
        ff.compute(&hf, (1, 1), &p, None);
        let d = ff.dir_at(0, 0);
        assert!(d != Some((1, 1)), "不允许斜穿墙角：{:?}", d);
    }

    #[test]
    fn destruction_opens_a_path() {
        let p = params();
        let mut w = flat_world(8, None);
        for cz in 0..8 {
            w.push_segment(4, cz, Segment::new(0, 3000, mat::CONCRETE, 600));
        }
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &p);
        let mut ff = FlowField::new(8);
        ff.compute(&hf, (7, 0), &p, None);
        assert!(!ff.reachable(0, 0), "整堵墙时不可达");

        // 炸掉 (4,0) 的墙段（索引 1：0 是地面）→ 局部重建 → 通了
        assert!(w.damage(4, 0, 1, 600), "混凝土 600hp 应该被一发打掉");
        hf.rebuild_area(&w, 3, 0, 6, 2, &p);
        let mut ff2 = FlowField::new(8);
        ff2.compute(&hf, (7, 0), &p, None);
        assert!(ff2.reachable(0, 0), "炸开缺口后应该可达");
        assert!(ff2.cost_at(0, 0) < UNREACHABLE);
    }

    #[test]
    fn compute_is_deterministic() {
        let w = flat_world(8, Some(Segment::new(0, 3000, mat::CONCRETE, 600)));
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        let mut a = FlowField::new(8);
        let mut b = FlowField::new(8);
        a.compute(&hf, (7, 7), &params(), None);
        b.compute(&hf, (7, 7), &params(), None);
        assert_eq!(a.cost, b.cost);
        assert_eq!(a.next, b.next);

        // 附加代价场（M2 威胁场）也要一致
        let extra: Vec<u32> = (0..64).map(|i| (i % 7) as u32 * 1000).collect();
        let mut c = FlowField::new(8);
        let mut d = FlowField::new(8);
        c.compute(&hf, (7, 7), &params(), Some(&extra));
        d.compute(&hf, (7, 7), &params(), Some(&extra));
        assert_eq!(c.cost, d.cost);
        assert_eq!(c.next, d.next);
    }

    #[test]
    fn unreachable_target_yields_empty_field() {
        // (2,2) 挖成坑（虚空）⇒ 以它为目标得到空场
        let mut w = World::new(8, 4);
        for cz in 0..8 {
            for cx in 0..8 {
                if cx == 2 && cz == 2 {
                    continue;
                }
                w.push_segment(cx, cz, Segment::new(-8000, 0, mat::GROUND, u16::MAX));
            }
        }
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        assert!(!hf.walkable(2, 2));
        let mut ff = FlowField::new(8);
        ff.compute(&hf, (2, 2), &params(), None);
        assert_eq!(ff.reached_cells(), 0);
        assert_eq!(ff.next_cell(0, 0), None);
        // 目标点落在坑里时，退化到最近的可站立柱
        assert_eq!(nearest_walkable(&hf, 2, 2, 4), Some((1, 1)));
    }

    #[test]
    fn radius_limits_the_field() {
        let w = flat_world(8, None);
        let mut hf = HeightField::new(8);
        hf.rebuild_all(&w, &params());
        let mut ff = FlowField::new(8);
        ff.set_radius_cells(2);
        ff.compute(&hf, (4, 4), &params(), None);
        assert!(ff.reachable(4, 4));
        assert!(ff.reachable(2, 4), "半径内");
        assert!(!ff.reachable(0, 0), "半径外应不可达");
        assert_eq!(ff.reached_cells(), 25, "以 (4,4) 为中心半径 2 的正方形 = 5×5");
    }

    #[test]
    fn step_toward_moves_at_most_one_step() {
        assert_eq!(step_toward((0, 0), (0, 0), 50), (0, 0));
        assert_eq!(step_toward((0, 0), (10, 0), 50), (10, 0), "距离小于步长时直接到达");
        assert_eq!(step_toward((0, 0), (1000, 0), 50), (50, 0));
        // 斜向：每轴分量都不超过步长，且方向不变
        let p = step_toward((0, 0), (1000, 1000), 50);
        assert!(p.0 <= 50 && p.1 <= 50 && p.0 >= 35 && p.1 >= 35, "{:?}", p);
        // 负方向
        assert_eq!(step_toward((0, 0), (-1000, 0), 50), (-50, 0));
    }
}
