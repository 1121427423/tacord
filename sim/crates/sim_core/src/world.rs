//! 体素世界：柱（cell）→ 段（segment）列表，分块（chunk）CSR 存储。
//!
//! 设计要点（对应设计文档 §10.5 / §10.5.1）：
//! - **段之间允许空隙** → 可以表达二楼楼板、窗洞、悬挑、阳台、桥下通行空间。
//! - 每柱最多 `MAX_SEGS` 段（冻结为 4）。
//! - 破坏 / 挖掘走同一条管线：改段 → chunk 标脏 → 上层（掩体、导航、渲染）按需重建。
//! - **权威几何**：掩体派生、LOS、弹道、破坏、导航代价只走这里，不碰渲染网格。

use super::CELL_MM;

/// 每柱最大段数（冻结值，见 `constants.ron` 的 `world.max_segments`）。
pub const MAX_SEGS: usize = 4;

/// 一个垂直段（实体区间）。段之间可以有空隙 —— 空隙就是窗洞 / 桥下 / 悬挑。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Segment {
    pub bottom_mm: i32,
    pub top_mm: i32,
    pub material: u16,
    pub hp: u16,
}

impl Segment {
    #[inline]
    pub const fn new(bottom_mm: i32, top_mm: i32, material: u16, hp: u16) -> Self {
        Segment {
            bottom_mm,
            top_mm,
            material,
            hp,
        }
    }
}

/// 材质属性。注意三门分开：`blocks_sight`（看得见吗）、`blocks_bullet`（打得中吗）、
/// `blocks_move`（走得过去吗）—— 铁丝网就是"看得见、打得过、走不过"。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Material {
    pub blocks_sight: bool,
    pub blocks_bullet: bool,
    pub blocks_move: bool,
    pub hp: u16,
}

impl Material {
    pub const EMPTY: Material = Material {
        blocks_sight: false,
        blocks_bullet: false,
        blocks_move: false,
        hp: 0,
    };
    /// 地面 / 基岩：什么都挡，且不可破坏。
    pub const GROUND: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: u16::MAX,
    };
    pub const CONCRETE: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 600,
    };
    pub const BRICK: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 180,
    };
    pub const WOOD: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 45,
    };
    pub const GLASS: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 5,
    };
    /// 车辆残骸：能挡，但会被打穿（掩体"越打越没用"）。
    pub const WRECK: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 250,
    };
    pub const SANDBAG: Material = Material {
        blocks_sight: true,
        blocks_bullet: true,
        blocks_move: true,
        hp: 120,
    };
    /// 铁丝网：看得见、打得过，但走不过去。
    pub const WIRE: Material = Material {
        blocks_sight: false,
        blocks_bullet: false,
        blocks_move: true,
        hp: 30,
    };

    #[inline]
    pub const fn is_air(&self) -> bool {
        !self.blocks_sight && !self.blocks_bullet && !self.blocks_move
    }
}

/// 材质表索引（顺序必须与 `World::default_materials()` 一致）。
pub mod mat {
    pub const EMPTY: u16 = 0;
    pub const GROUND: u16 = 1;
    pub const CONCRETE: u16 = 2;
    pub const BRICK: u16 = 3;
    pub const WOOD: u16 = 4;
    pub const GLASS: u16 = 5;
    pub const WRECK: u16 = 6;
    pub const SANDBAG: u16 = 7;
    pub const WIRE: u16 = 8;
}

/// 一个 chunk：`chunk_cells²` 个柱，段用 CSR（`seg_start` + `segs`）紧凑存储。
///
/// 选 CSR 而不是"每柱固定数组"是因为：空柱（无段）在 CSR 里不占空间，
/// 而固定数组要为每柱预留 `MAX_SEGS` 个段（全图 4.19M 柱 × 52B ≈ 218 MB，超预算）。
#[derive(Clone, Debug)]
pub struct Chunk {
    pub cx: u32,
    pub cz: u32,
    /// 长度 `cells² + 1`：柱 i 的段区间是 `seg_start[i]..seg_start[i+1]`。
    seg_start: Vec<u32>,
    segs: Vec<Segment>,
    pub dirty: bool,
}

impl Chunk {
    fn new(cx: u32, cz: u32, cells: usize) -> Self {
        Chunk {
            cx,
            cz,
            seg_start: vec![0u32; cells * cells + 1],
            segs: Vec::new(),
            dirty: false,
        }
    }
}

/// 世界。
#[derive(Clone, Debug)]
pub struct World {
    /// 每边多少柱（冻结 2048）。
    pub dim_cells: u32,
    /// 每个 chunk 每边多少柱（冻结 32）。
    pub chunk_cells: u32,
    chunks_x: u32,
    chunks: Vec<Chunk>,
    /// 脏 chunk 队列（去重由 `Chunk::dirty` 保证）。
    dirty: Vec<u32>,
    materials: Vec<Material>,
}

impl World {
    /// 建一个空世界（没有任何段，包括地面）。测试与程序化生成用。
    pub fn new(dim_cells: u32, chunk_cells: u32) -> Self {
        assert!(dim_cells > 0 && chunk_cells > 0);
        assert!(dim_cells % chunk_cells == 0, "dim 必须是 chunk 的整数倍");
        let chunks_x = dim_cells / chunk_cells;
        let n = (chunks_x * chunks_x) as usize;
        let mut chunks = Vec::with_capacity(n);
        for i in 0..n {
            let cx = (i as u32) % chunks_x;
            let cz = (i as u32) / chunks_x;
            chunks.push(Chunk::new(cx, cz, chunk_cells as usize));
        }
        World {
            dim_cells,
            chunk_cells,
            chunks_x,
            chunks,
            dirty: Vec::new(),
            materials: Self::default_materials(),
        }
    }

    /// 建一个"平地"世界：每柱一段地面 `[-8000, 0]`。
    /// 注意：地面用**显式段**表示（简单、通用、可挖），代价是每柱一段（全图 ≈ 50 MB）。
    /// 若将来内存吃紧，可改为"隐式基岩"优化 —— 属于 T1 改动，不进 1.0。
    pub fn new_flat(dim_cells: u32, chunk_cells: u32, ground_bottom_mm: i32) -> Self {
        let mut w = Self::new(dim_cells, chunk_cells);
        for cz in 0..dim_cells {
            for cx in 0..dim_cells {
                w.push_segment(cx, cz, Segment::new(ground_bottom_mm, 0, mat::GROUND, u16::MAX));
            }
        }
        w
    }

    pub fn default_materials() -> Vec<Material> {
        vec![
            Material::EMPTY,
            Material::GROUND,
            Material::CONCRETE,
            Material::BRICK,
            Material::WOOD,
            Material::GLASS,
            Material::WRECK,
            Material::SANDBAG,
            Material::WIRE,
        ]
    }

    #[inline]
    pub fn material(&self, id: u16) -> Material {
        self.materials
            .get(id as usize)
            .copied()
            .unwrap_or(Material::EMPTY)
    }

    pub fn set_material(&mut self, id: u16, m: Material) {
        while self.materials.len() <= id as usize {
            self.materials.push(Material::EMPTY);
        }
        self.materials[id as usize] = m;
    }

    #[inline]
    fn chunk_index(&self, cx: u32, cz: u32) -> usize {
        ((cz / self.chunk_cells) * self.chunks_x + (cx / self.chunk_cells)) as usize
    }

    #[inline]
    fn local_index(&self, cx: u32, cz: u32) -> usize {
        ((cz % self.chunk_cells) * self.chunk_cells + (cx % self.chunk_cells)) as usize
    }

    /// 某柱的段（按 `bottom_mm` 升序）。越界返回空切片。
    pub fn segments(&self, cx: u32, cz: u32) -> &[Segment] {
        if cx >= self.dim_cells || cz >= self.dim_cells {
            return &[];
        }
        let ci = self.chunk_index(cx, cz);
        let li = self.local_index(cx, cz);
        let ch = &self.chunks[ci];
        let s = ch.seg_start[li] as usize;
        let e = ch.seg_start[li + 1] as usize;
        &ch.segs[s..e]
    }

    /// 追加一段（用于世界生成 / 建造）。段数达上限则忽略并返回 false。
    pub fn push_segment(&mut self, cx: u32, cz: u32, seg: Segment) -> bool {
        if cx >= self.dim_cells || cz >= self.dim_cells {
            return false;
        }
        if self.segments(cx, cz).len() >= MAX_SEGS {
            return false;
        }
        let ci = self.chunk_index(cx, cz);
        let li = self.local_index(cx, cz);
        // 插到该柱区间的末尾，然后只对该区间按 bottom 排序（保持段有序）
        let end = self.chunks[ci].seg_start[li + 1] as usize;
        self.chunks[ci].segs.insert(end, seg);
        let start = self.chunks[ci].seg_start[li] as usize;
        self.chunks[ci].segs[start..end + 1].sort_by_key(|s| s.bottom_mm);
        let cells = (self.chunk_cells * self.chunk_cells) as usize;
        for j in (li + 1)..=cells {
            self.chunks[ci].seg_start[j] += 1;
        }
        self.mark_dirty(ci);
        true
    }

    /// 移除一段（破坏/挖掘的结果）。
    pub fn remove_segment(&mut self, cx: u32, cz: u32, idx: u32) -> bool {
        if cx >= self.dim_cells || cz >= self.dim_cells {
            return false;
        }
        let ci = self.chunk_index(cx, cz);
        let li = self.local_index(cx, cz);
        let start = self.chunks[ci].seg_start[li] as usize;
        let end = self.chunks[ci].seg_start[li + 1] as usize;
        let pos = start + idx as usize;
        if pos >= end {
            return false;
        }
        self.chunks[ci].segs.remove(pos);
        let cells = (self.chunk_cells * self.chunk_cells) as usize;
        for j in (li + 1)..=cells {
            self.chunks[ci].seg_start[j] -= 1;
        }
        self.mark_dirty(ci);
        true
    }

    /// 对某段造成伤害。返回是否**被摧毁**（hp 归零 → 移除）。
    pub fn damage(&mut self, cx: u32, cz: u32, idx: u32, dmg: u16) -> bool {
        if cx >= self.dim_cells || cz >= self.dim_cells {
            return false;
        }
        let ci = self.chunk_index(cx, cz);
        let li = self.local_index(cx, cz);
        let start = self.chunks[ci].seg_start[li] as usize;
        let end = self.chunks[ci].seg_start[li + 1] as usize;
        let pos = start + idx as usize;
        if pos >= end || dmg == 0 {
            return false;
        }
        let hp = self.chunks[ci].segs[pos].hp;
        if hp <= dmg {
            self.remove_segment(cx, cz, idx);
            true
        } else {
            self.chunks[ci].segs[pos].hp -= dmg;
            self.mark_dirty(ci);
            false
        }
    }

    /// 该柱最高的实体顶面（mm）。没有段时返回 `i32::MIN`（表示"虚空"）。
    pub fn top_mm(&self, cx: u32, cz: u32) -> i32 {
        self.segments(cx, cz)
            .iter()
            .map(|s| s.top_mm)
            .max()
            .unwrap_or(i32::MIN)
    }

    fn mark_dirty(&mut self, ci: usize) {
        if !self.chunks[ci].dirty {
            self.chunks[ci].dirty = true;
            self.dirty.push(ci as u32);
        }
    }

    /// 取出至多 `max` 个脏 chunk（调用方负责重建掩体/导航/网格，然后清除脏标记）。
    pub fn take_dirty(&mut self, max: usize) -> Vec<u32> {
        let n = max.min(self.dirty.len());
        let out: Vec<u32> = self.dirty.drain(..n).collect();
        for ci in out.iter() {
            self.chunks[*ci as usize].dirty = false;
        }
        out
    }

    #[inline]
    pub fn dirty_count(&self) -> usize {
        self.dirty.len()
    }

    /// 段总数（调试用）。
    pub fn segment_count(&self) -> usize {
        self.chunks.iter().map(|c| c.segs.len()).sum()
    }

    /// 确定性校验和（FNV-1a）：跨平台逐位一致的前提是遍历顺序固定 —— 这里按 chunk → 柱 → 段。
    pub fn checksum(&self) -> u64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for ch in self.chunks.iter() {
            for li in 0..(self.chunk_cells * self.chunk_cells) as usize {
                let s = ch.seg_start[li] as usize;
                let e = ch.seg_start[li + 1] as usize;
                for seg in ch.segs[s..e].iter() {
                    for v in [seg.bottom_mm as u32, seg.top_mm as u32] {
                        h ^= v as u64;
                        h = h.wrapping_mul(0x100_0000_01b3);
                    }
                    h ^= seg.material as u64;
                    h = h.wrapping_mul(0x100_0000_01b3);
                    h ^= seg.hp as u64;
                    h = h.wrapping_mul(0x100_0000_01b3);
                }
            }
        }
        h
    }

    /// 世界尺寸（mm）。
    #[inline]
    pub fn size_mm(&self) -> i64 {
        self.dim_cells as i64 * CELL_MM
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat() -> World {
        World::new_flat(8, 4, -8000)
    }

    #[test]
    fn flat_world_has_ground_everywhere() {
        let w = flat();
        assert_eq!(w.segment_count() as u32, 8 * 8, "每柱一段地面");
        assert_eq!(w.segments(0, 0), &[Segment::new(-8000, 0, mat::GROUND, u16::MAX)]);
        assert_eq!(w.top_mm(3, 3), 0);
    }

    #[test]
    fn out_of_bounds_is_empty_not_panic() {
        let w = flat();
        assert!(w.segments(100, 100).is_empty());
        assert!(w.segments(u32::MAX, 0).is_empty());
        assert_eq!(w.top_mm(999, 0), i32::MIN);
    }

    #[test]
    fn segments_stay_sorted_and_allow_gaps() {
        let mut w = flat();
        // 在地面之上加"楼板 + 屋顶"，中间留窗洞 → 段之间有空隙
        assert!(w.push_segment(2, 2, Segment::new(3000, 3200, mat::CONCRETE, 600)));
        assert!(w.push_segment(2, 2, Segment::new(0, 1800, mat::BRICK, 180)));
        let segs = w.segments(2, 2).to_vec();
        assert_eq!(segs.len(), 3);
        assert!(segs.windows(2).all(|p| p[0].bottom_mm <= p[1].bottom_mm), "必须按 bottom 升序");
        // 空隙 [1800, 3000] 存在 → 能表达窗洞
        assert_eq!(segs[1].top_mm, 1800);
        assert_eq!(segs[2].bottom_mm, 3000);
    }

    #[test]
    fn max_segments_per_column_enforced() {
        let mut w = World::new(4, 4);
        for i in 0..MAX_SEGS {
            assert!(w.push_segment(1, 1, Segment::new(i as i32 * 100, i as i32 * 100 + 50, mat::WOOD, 10)));
        }
        assert!(!w.push_segment(1, 1, Segment::new(9999, 10000, mat::WOOD, 10)), "超过 MAX_SEGS 必须被拒绝");
        assert_eq!(w.segments(1, 1).len(), MAX_SEGS);
    }

    #[test]
    fn damage_destroys_and_marks_dirty() {
        let mut w = World::new(4, 4);
        w.push_segment(1, 1, Segment::new(0, 2000, mat::WOOD, 100));
        assert_eq!(w.dirty_count(), 1);
        assert!(!w.damage(1, 1, 0, 40), "未摧毁");
        assert_eq!(w.segments(1, 1)[0].hp, 60);
        assert!(w.damage(1, 1, 0, 60), "hp 归零 → 摧毁");
        assert!(w.segments(1, 1).is_empty());
        // 脏队列去重：连续修改同一 chunk 不应无限堆积
        let before = w.dirty_count();
        w.push_segment(1, 2, Segment::new(0, 100, mat::WOOD, 10));
        assert_eq!(w.dirty_count(), before, "同一 chunk 只入队一次");
        let taken = w.take_dirty(10);
        assert_eq!(taken.len(), before);
        assert_eq!(w.dirty_count(), 0, "取出后清空");
        assert!(w.take_dirty(10).is_empty());
    }

    #[test]
    fn take_dirty_respects_max_for_amortized_rebuild() {
        let mut w = World::new(16, 4);
        for i in 0..16 {
            w.push_segment(i, i, Segment::new(0, 500, mat::WOOD, 10));
        }
        let total = w.dirty_count();
        assert!(total > 2);
        assert_eq!(w.take_dirty(2).len(), 2, "每帧最多重建 2 个 chunk（预算摊还）");
        assert_eq!(w.dirty_count(), total - 2);
    }

    #[test]
    fn checksum_is_deterministic_and_order_sensitive() {
        let a = flat();
        let b = flat();
        assert_eq!(a.checksum(), b.checksum());
        let mut c = flat();
        c.push_segment(5, 5, Segment::new(0, 2000, mat::CONCRETE, 600));
        assert_ne!(a.checksum(), c.checksum(), "内容变了校验和必须变");
        let mut d = flat();
        d.push_segment(5, 6, Segment::new(0, 2000, mat::CONCRETE, 600));
        assert_ne!(c.checksum(), d.checksum(), "位置不同校验和必须不同");
    }

    #[test]
    fn material_flags_are_independent() {
        let w = flat();
        let wire = w.material(mat::WIRE);
        assert!(!wire.blocks_sight, "铁丝网挡不住视线");
        assert!(!wire.blocks_bullet, "铁丝网挡不住子弹");
        assert!(wire.blocks_move, "但走不过去");
        assert!(!wire.is_air());
        assert!(w.material(mat::EMPTY).is_air());
        assert!(w.material(999).is_air(), "未知材质按空气处理，不 panic");
    }
}
