//! `sim_math` —— tacord 模拟层的确定性数学库。
//!
//! 设计约束（全部由 CI / lint 强制）：
//!
//! 1. **不使用浮点**：`#![deny(clippy::float_arithmetic)]`。浮点在不同编译器/平台下可能有
//!    1ulp 差异，会毁掉 bit-exact lockstep 与逐位一致的回放。
//! 2. **不使用 libm**：`sin/cos/atan2` 全部走烘焙的查找表 + 整数线性插值。表由
//!    `tools/gen_trig.py` 生成并提交进仓库（见 `tables.rs` 的注释说明为什么不能用 build.rs）。
//! 3. **所有运算是整数运算**：溢出语义明确（debug 下 panic，release 下 wrapping），
//!    算术右移 `>>` 对负数是向下取整，跨编译器一致。
//!
//! 定标约定（与 `docs/design/05-frozen-parameters.md` §5 一致）：
//!
//! | 类型 | 表示 | 范围 / 精度 |
//! | --- | --- | --- |
//! | `Mm` | `i32` 毫米 | ±2147 km，1 mm |
//! | `Ang` | `u16` 角度 | 0..65535 ≡ 0..2π，1 单位 ≈ 0.0055° |
//! | `Q16` | `i32` Q16.16 | ±32767.99998，精度 1.5e-5 |
//! | `Prob` | `u16` 概率 | 0..65535 ≡ 0..1 |

#![deny(unsafe_code)]
#![deny(clippy::float_arithmetic)]

pub mod tables;

use core::ops::{Add, AddAssign, Mul, Neg, Sub, SubAssign};

// ═══════════════════════════════════ Q16 定点标量 ═══════════════════════════════════

/// 四分之一波表的区间数（表长 N+1 = 1025）。
const TRIG_N: usize = 1024;
/// 一个直角（π/2）在 `Ang` 单位下的值。
const ANG_QUARTER: u32 = 16384;
/// atan 表中 65536 对应的角度：π/4。
const ATAN_QUARTER: i64 = 65536;
/// 直角（π/2）在 atan 表单位下的值。
const ATAN_HALF_PI: i64 = ATAN_QUARTER * 2;

/// Q16.16 定点数：`raw = round(real × 65536)`。
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct Q16(pub i32);

impl Q16 {
    pub const ZERO: Q16 = Q16(0);
    pub const ONE: Q16 = Q16(65536);
    pub const HALF: Q16 = Q16(32768);

    #[inline]
    pub const fn from_raw(raw: i32) -> Self {
        Q16(raw)
    }
    #[inline]
    pub const fn raw(self) -> i32 {
        self.0
    }
    #[inline]
    pub const fn from_int(v: i32) -> Self {
        Q16(v << 16)
    }
    /// 向下取整到整数部分。
    #[inline]
    pub const fn to_int_floor(self) -> i32 {
        self.0 >> 16
    }
    /// 乘法：`(a × b) >> 16`，用 64 位中间值避免溢出。
    #[inline]
    pub const fn mul(self, rhs: Q16) -> Q16 {
        Q16((((self.0 as i64) * (rhs.0 as i64)) >> 16) as i32)
    }
    /// 除法：`(a << 16) / b`。调用方保证 `rhs != 0`。
    #[inline]
    pub const fn div(self, rhs: Q16) -> Q16 {
        Q16((((self.0 as i64) << 16) / (rhs.0 as i64)) as i32)
    }
    /// 整数倍缩放（精确，无舍入）。
    #[inline]
    pub const fn scale_int(self, v: i32) -> Q16 {
        Q16(self.0.wrapping_mul(v))
    }
    #[inline]
    pub const fn abs(self) -> Q16 {
        if self.0 < 0 {
            Q16(-self.0)
        } else {
            self
        }
    }
    #[inline]
    pub const fn min(self, rhs: Q16) -> Q16 {
        if self.0 < rhs.0 {
            self
        } else {
            rhs
        }
    }
    #[inline]
    pub const fn max(self, rhs: Q16) -> Q16 {
        if self.0 > rhs.0 {
            self
        } else {
            rhs
        }
    }
    #[inline]
    pub const fn clamp(self, lo: Q16, hi: Q16) -> Q16 {
        self.max(lo).min(hi)
    }
    /// 平方根（整数位运算，完全确定性）。负数返回 0。
    #[inline]
    pub fn sqrt(self) -> Q16 {
        if self.0 <= 0 {
            return Q16::ZERO;
        }
        // raw_result = isqrt(raw << 16)
        Q16(isqrt((self.0 as u64) << 16) as i32)
    }
}

impl Add for Q16 {
    type Output = Q16;
    #[inline]
    fn add(self, rhs: Q16) -> Q16 {
        Q16(self.0 + rhs.0)
    }
}
impl Sub for Q16 {
    type Output = Q16;
    #[inline]
    fn sub(self, rhs: Q16) -> Q16 {
        Q16(self.0 - rhs.0)
    }
}
impl Neg for Q16 {
    type Output = Q16;
    #[inline]
    fn neg(self) -> Q16 {
        Q16(-self.0)
    }
}

/// 64 位整数平方根（逐位算法，floor）。
fn isqrt(n: u64) -> u64 {
    if n < 2 {
        return n;
    }
    let mut rem: u64 = n;
    let mut root: u64 = 0;
    let mut d: u64 = 1 << 62;
    while d > n {
        d >>= 2;
    }
    while d != 0 {
        if rem >= root.wrapping_add(d) {
            rem -= root.wrapping_add(d);
            root = (root >> 1).wrapping_add(d);
        } else {
            root >>= 1;
        }
        d >>= 2;
    }
    root
}

// ═══════════════════════════════════ Mm 长度 ═══════════════════════════════════

/// 长度/坐标：`i32` 毫米。
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct Mm(pub i32);

impl Mm {
    pub const ZERO: Mm = Mm(0);

    #[inline]
    pub const fn from_mm(mm: i32) -> Self {
        Mm(mm)
    }
    #[inline]
    pub const fn from_m(m: i32) -> Self {
        Mm(m * 1000)
    }
    #[inline]
    pub const fn raw(self) -> i32 {
        self.0
    }
    /// 向下取整到米。
    #[inline]
    pub const fn to_m_floor(self) -> i32 {
        self.0 / 1000
    }
    #[inline]
    pub const fn abs(self) -> Mm {
        if self.0 < 0 {
            Mm(-self.0)
        } else {
            self
        }
    }
    #[inline]
    pub const fn min(self, rhs: Mm) -> Mm {
        if self.0 < rhs.0 {
            self
        } else {
            rhs
        }
    }
    #[inline]
    pub const fn max(self, rhs: Mm) -> Mm {
        if self.0 > rhs.0 {
            self
        } else {
            rhs
        }
    }
    /// 按 Q16 系数缩放：`(mm × q) >> 16`。
    #[inline]
    pub const fn mul_q16(self, q: Q16) -> Mm {
        Mm((((self.0 as i64) * (q.0 as i64)) >> 16) as i32)
    }
    /// 除以 Q16 系数。
    #[inline]
    pub const fn div_q16(self, q: Q16) -> Mm {
        Mm((((self.0 as i64) << 16) / (q.0 as i64)) as i32)
    }
}

impl Add for Mm {
    type Output = Mm;
    #[inline]
    fn add(self, rhs: Mm) -> Mm {
        Mm(self.0 + rhs.0)
    }
}
impl Sub for Mm {
    type Output = Mm;
    #[inline]
    fn sub(self, rhs: Mm) -> Mm {
        Mm(self.0 - rhs.0)
    }
}
impl Neg for Mm {
    type Output = Mm;
    #[inline]
    fn neg(self) -> Mm {
        Mm(-self.0)
    }
}
impl Mul<Q16> for Mm {
    type Output = Mm;
    #[inline]
    fn mul(self, rhs: Q16) -> Mm {
        self.mul_q16(rhs)
    }
}

/// 三维点/向量（毫米）。`y` 为**高度**，`x`/`z` 为地面平面
/// （与 `Vec2` 的 `x`/`y` 对应同一个地面平面，注意命名差异）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Vec3 {
    pub x: Mm,
    pub y: Mm,
    pub z: Mm,
}

impl Vec3 {
    #[inline]
    pub const fn new(x: Mm, y: Mm, z: Mm) -> Self {
        Vec3 { x, y, z }
    }
    #[inline]
    pub const fn add(self, rhs: Vec3) -> Vec3 {
        Vec3 {
            x: Mm(self.x.0 + rhs.x.0),
            y: Mm(self.y.0 + rhs.y.0),
            z: Mm(self.z.0 + rhs.z.0),
        }
    }
    #[inline]
    pub const fn sub(self, rhs: Vec3) -> Vec3 {
        Vec3 {
            x: Mm(self.x.0 - rhs.x.0),
            y: Mm(self.y.0 - rhs.y.0),
            z: Mm(self.z.0 - rhs.z.0),
        }
    }
}

/// 地面平面上的二维向量（X-Z，单位毫米）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Vec2 {
    pub x: Mm,
    pub y: Mm,
}

impl Vec2 {
    pub const ZERO: Vec2 = Vec2 { x: Mm(0), y: Mm(0) };

    #[inline]
    pub const fn new(x: Mm, y: Mm) -> Self {
        Vec2 { x, y }
    }
    #[inline]
    pub const fn add(self, rhs: Vec2) -> Vec2 {
        Vec2 {
            x: Mm(self.x.0 + rhs.x.0),
            y: Mm(self.y.0 + rhs.y.0),
        }
    }
    #[inline]
    pub const fn sub(self, rhs: Vec2) -> Vec2 {
        Vec2 {
            x: Mm(self.x.0 - rhs.x.0),
            y: Mm(self.y.0 - rhs.y.0),
        }
    }
    #[inline]
    pub const fn scaled(self, q: Q16) -> Vec2 {
        Vec2 {
            x: self.x.mul_q16(q),
            y: self.y.mul_q16(q),
        }
    }
    /// 平方长度（i64，毫米²）。
    #[inline]
    pub const fn len_sq(self) -> i64 {
        (self.x.0 as i64) * (self.x.0 as i64) + (self.y.0 as i64) * (self.y.0 as i64)
    }
    /// 欧氏长度（向下取整到毫米）。
    #[inline]
    pub fn len(self) -> Mm {
        Mm(isqrt(self.len_sq() as u64) as i32)
    }
    /// 曼哈顿距离（DDA 与粗略剔除用，比 `len` 便宜）。
    #[inline]
    pub const fn manhattan(self) -> Mm {
        Mm(self.x.abs().0 + self.y.abs().0)
    }
    /// 切比雪夫距离（方形范围剔除用）。
    #[inline]
    pub const fn chebyshev(self) -> Mm {
        let ax = self.x.abs().0;
        let ay = self.y.abs().0;
        if ax > ay {
            Mm(ax)
        } else {
            Mm(ay)
        }
    }
}

// ═══════════════════════════════════ Ang 角度 ═══════════════════════════════════

/// 角度：`u16`，0..65535 ≡ 0..2π（1 单位 ≈ 0.0055°），`0 = -Z（北）`，顺时针递增。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Ang(pub u16);

impl Ang {
    pub const ZERO: Ang = Ang(0);
    /// 直角（π/2）。
    pub const QUARTER: Ang = Ang(16384);
    /// 平角（π）。
    pub const HALF: Ang = Ang(32768);

    #[inline]
    pub const fn from_raw(raw: u16) -> Self {
        Ang(raw)
    }
    #[inline]
    pub const fn raw(self) -> u16 {
        self.0
    }
    /// 由角度制构造（负值与超范围值取模）。
    #[inline]
    pub const fn from_degrees(deg: i32) -> Ang {
        let d = ((deg % 360) + 360) % 360;
        Ang(((d as i64 * 65536 / 360) & 0xFFFF) as u16)
    }
    #[inline]
    pub const fn wrapping_add(self, rhs: Ang) -> Ang {
        Ang(self.0.wrapping_add(rhs.0))
    }
    #[inline]
    pub const fn wrapping_sub(self, rhs: Ang) -> Ang {
        Ang(self.0.wrapping_sub(rhs.0))
    }
    /// 反向（+π）。
    #[inline]
    pub const fn opposite(self) -> Ang {
        Ang(self.0.wrapping_add(32768))
    }
    /// 有符号最短差值（`other - self`，范围 −32768..32767）。
    #[inline]
    pub const fn diff_to(self, other: Ang) -> i16 {
        other.0.wrapping_sub(self.0) as i16
    }
    /// 无符号夹角（0..32768，即 0..π）。掩体"是否被侧翼包抄"判定用。
    #[inline]
    pub const fn abs_diff(self, other: Ang) -> u16 {
        let d = self.0.wrapping_sub(other.0);
        let n = (0u16.wrapping_sub(d)) as u16;
        if d < n {
            d
        } else {
            n
        }
    }

    /// 正弦（查表 + 整数线性插值，误差 < 1 Q16 单位 ≈ 1.5e-5）。
    pub fn sin(self) -> Q16 {
        let a = self.0 as u32;
        let quarter = (a >> 14) & 3;
        let within = a & 0x3FFF; // 0..16383
        let v = match quarter {
            0 => sin_quarter(within),
            1 => sin_quarter(ANG_QUARTER - within),
            2 => -sin_quarter(within),
            _ => -sin_quarter(ANG_QUARTER - within),
        };
        Q16(v)
    }

    /// 余弦：`sin(a + π/2)`。
    #[inline]
    pub fn cos(self) -> Q16 {
        self.wrapping_add(Ang::QUARTER).sin()
    }

    /// 单位方向向量（分量以 Q16 表示，范围 ±1）。
    #[inline]
    pub fn to_dir(self) -> (Q16, Q16) {
        (self.cos(), self.sin())
    }
}

/// 查四分之一波表：`t ∈ [0, 16384]` 映射到 `[0, π/2]`，返回 Q16 的 sin 值。
#[inline]
fn sin_quarter(t: u32) -> i32 {
    let i = (t >> 4) as usize; // 0..1024
    let frac = (t & 15) as i32; // 0..15
    let lo = tables::SIN_QUARTER[i];
    if i >= TRIG_N {
        return lo; // t == 16384：精确端点，无需插值
    }
    let hi = tables::SIN_QUARTER[i + 1];
    lo + ((hi - lo) * frac) / 16
}

/// 反正切：`atan2(y, x)` —— 返回向量 (x, y) 与 +x 轴的夹角，逆时针为正。
/// `(0, 0)` 返回 0。误差 < 3 Ang 单位（≈ 0.017°）。
pub fn atan2(y: Mm, x: Mm) -> Ang {
    let xi = x.0 as i64;
    let yi = y.0 as i64;
    if xi == 0 && yi == 0 {
        return Ang::ZERO;
    }
    let ax = xi.abs();
    let ay = yi.abs();
    let (mn, mx) = if ay > ax { (ax, ay) } else { (ay, ax) };
    let swapped = ay > ax;
    // r = min/max，Q16（0..65536）
    let r: i64 = if mx == 0 { 0 } else { (mn << 16) / mx };
    // 表索引：1024 个区间覆盖 [0,1] → i = r >> 6
    let i = (r >> 6) as usize; // 0..1024
    let frac = (r & 63) as i32;
    let lo = tables::ATAN_RATIO[i];
    let hi = if i < TRIG_N {
        tables::ATAN_RATIO[i + 1]
    } else {
        lo
    };
    let ang_q: i64 = lo as i64 + ((hi as i64 - lo as i64) * frac as i64) / 64; // 单位：65536 ≡ π/4
    // θ ∈ [0, π/2]，单位同上（π/2 = 131072）
    let theta_units: i64 = if swapped {
        ATAN_HALF_PI - ang_q
    } else {
        ang_q
    };
    // 转成 Ang 单位（π/2 = 16384）
    let theta: i64 = theta_units / 8;
    // 象限修正（π/2 = 16384，π = 32768）：
    //   x≥0,y≥0 → θ          x<0,y≥0 → π − θ
    //   x<0,y<0 → π + θ      x≥0,y<0 → 2π − θ
    let units: i64 = if xi < 0 {
        if yi < 0 {
            32768 + theta
        } else {
            32768 - theta
        }
    } else if yi < 0 {
        65536 - theta
    } else {
        theta
    };
    Ang((units & 0xFFFF) as u16)
}

// ═══════════════════════════════════ Prob 概率 ═══════════════════════════════════

/// 概率：`u16`，0..65535 ≡ 0..1。
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct Prob(pub u16);

impl Prob {
    pub const NEVER: Prob = Prob(0);
    pub const ALWAYS: Prob = Prob(65535);

    #[inline]
    pub const fn from_raw(raw: u16) -> Self {
        Prob(raw)
    }
    /// 由 Q16（0..1）构造，超范围会被截断。
    #[inline]
    pub const fn from_q16(q: Q16) -> Prob {
        let v = q.raw();
        if v <= 0 {
            Prob(0)
        } else if v >= 65536 {
            Prob(65535)
        } else {
            Prob((v as u32 * 65535 / 65536) as u16)
        }
    }
    /// 由百分比的千分之一构造（`from_permille(250)` = 25%）。
    #[inline]
    pub const fn from_permille(p: u32) -> Prob {
        if p >= 1000 {
            Prob(65535)
        } else {
            Prob((p * 65535 / 1000) as u16)
        }
    }
    #[inline]
    pub const fn raw(self) -> u16 {
        self.0
    }
}

// ═══════════════════════════════════ PCG32 随机 ═══════════════════════════════════

/// PCG32（LCG + xorshift/rotate 输出置换）。**不使用任何浮点**，跨平台逐位一致。
///
/// 随机数流必须按 `(system, entity, tick)` 分流，这样并行执行顺序不影响结果
/// （见 `Pcg32::for_decision`）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Pcg32 {
    state: u64,
    inc: u64,
}

const PCG_MULT: u64 = 6364136223846793005;

impl Pcg32 {
    /// 用 `(seed, stream)` 初始化，并预热一步。
    pub fn new(seed: u64, stream: u64) -> Self {
        let inc = (stream << 1) | 1;
        let mut rng = Pcg32 {
            state: seed.wrapping_add(inc),
            inc,
        };
        let _ = rng.next_u32();
        rng
    }

    /// 为一次决策派生独立的随机流：`(level_seed, system, entity, tick)` → 独立序列。
    ///
    /// 同一 `(system, entity, tick)` 永远得到同一个流 → 并行/乱序执行结果一致。
    pub fn for_decision(level_seed: u64, system: u16, entity: u32, tick: u32) -> Self {
        Self::new(mix(level_seed, system, entity, tick), system as u64)
    }

    #[inline]
    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(PCG_MULT).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    #[inline]
    pub fn next_u16(&mut self) -> u16 {
        (self.next_u32() >> 16) as u16
    }

    /// `[0, 1)` 的 Q16 值（raw ∈ 0..65535）。
    #[inline]
    pub fn next_q16_unit(&mut self) -> Q16 {
        Q16((self.next_u32() >> 16) as i32)
    }

    /// 以概率 `p` 返回 true。
    #[inline]
    pub fn chance(&mut self, p: Prob) -> bool {
        self.next_u16() < p.raw()
    }

    /// `[0, n)` 的无偏采样（Lemire 拒绝法）。
    pub fn next_range(&mut self, n: u32) -> u32 {
        if n == 0 {
            return 0;
        }
        let threshold = (0u32.wrapping_sub(n)) % n;
        loop {
            let x = self.next_u32();
            if x >= threshold {
                return x % n;
            }
        }
    }
}

/// splitmix64 风格的整数混合：把 `(seed, system, entity, tick)` 打散成一个 64 位种子。
#[inline]
fn mix(seed: u64, system: u16, entity: u32, tick: u32) -> u64 {
    let mut z = seed
        ^ ((system as u64) << 48)
        ^ ((entity as u64) << 16)
        ^ (tick as u64);
    z = z.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z ^= z >> 30;
    z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z ^= z >> 27;
    z
}

// ═══════════════════════════════════ 测试 ═══════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(actual: i32, expected: i32, tol: i32, what: &str) {
        assert!(
            (actual - expected).abs() <= tol,
            "{what}: 实际 {actual}, 期望 {expected} ±{tol}"
        );
    }

    // ── Q16 ──
    #[test]
    fn q16_mul_div_identities() {
        assert_eq!(Q16::from_int(2).mul(Q16::HALF), Q16::ONE);
        assert_eq!(Q16::ONE.div(Q16::from_int(4)), Q16(Q16::ONE.raw() / 4));
        assert_eq!(Q16::from_int(7).mul(Q16::from_int(3)), Q16::from_int(21));
        assert_eq!(Q16::from_int(-3).abs(), Q16::from_int(3));
        assert_eq!(Q16::from_int(5).clamp(Q16::ZERO, Q16::ONE), Q16::ONE);
    }

    #[test]
    fn q16_sqrt() {
        assert_eq!(Q16::from_int(4).sqrt(), Q16::from_int(2));
        assert_eq!(Q16::ONE.sqrt(), Q16::ONE);
        assert_near(Q16::from_int(2).sqrt().raw(), 92681, 2, "sqrt(2)");
        assert_near(Q16(16384).sqrt().raw(), 32768, 2, "sqrt(0.25)");
        assert_eq!(Q16::from_int(-9).sqrt(), Q16::ZERO);
        assert_eq!(Q16::ZERO.sqrt(), Q16::ZERO);
    }

    // ── 三角函数：端点与象限 ──
    #[test]
    fn trig_endpoints() {
        assert_near(Ang::from_degrees(0).sin().raw(), 0, 1, "sin(0°)");
        assert_near(Ang::from_degrees(90).sin().raw(), 65536, 2, "sin(90°)");
        assert_near(Ang::from_degrees(180).sin().raw(), 0, 2, "sin(180°)");
        assert_near(Ang::from_degrees(270).sin().raw(), -65536, 2, "sin(270°)");
        assert_near(Ang::from_degrees(0).cos().raw(), 65536, 2, "cos(0°)");
        assert_near(Ang::from_degrees(90).cos().raw(), 0, 2, "cos(90°)");
        assert_near(Ang::from_degrees(180).cos().raw(), -65536, 2, "cos(180°)");
    }

    #[test]
    fn trig_pythagoras_and_continuity() {
        // sin² + cos² ≈ 1（Q16）
        let mut a: u32 = 0;
        while a < 65536 {
            let ang = Ang::from_raw(a as u16);
            let s = ang.sin().raw() as i64;
            let c = ang.cos().raw() as i64;
            let r = (s * s + c * c) >> 16;
            assert_near(r as i32, 65536, 4, &format!("sin²+cos² @ {a}"));
            a += 37; // 互质步长，覆盖整圈
        }
        // 跨象限连续：相邻角度的 sin 跳变应 < 100 Q16 单位（1 单位角 ≈ 0.0055°）
        let mut prev = Ang::from_raw(0).sin().raw();
        let mut a: u32 = 1;
        while a <= 65536 {
            let cur = Ang::from_raw((a & 0xFFFF) as u16).sin().raw();
            assert!((cur - prev).abs() < 200, "sin 在 {a} 处跳变过大");
            prev = cur;
            a += 1;
        }
    }

    #[test]
    fn trig_known_values() {
        // sin(30°) = 0.5 → 32768
        assert_near(Ang::from_degrees(30).sin().raw(), 32768, 3, "sin(30°)");
        // sin(45°) = 0.7071 → 46341
        assert_near(Ang::from_degrees(45).sin().raw(), 46341, 3, "sin(45°)");
        // sin(60°) = 0.8660 → 56756
        assert_near(Ang::from_degrees(60).sin().raw(), 56756, 3, "sin(60°)");
        assert_near(Ang::from_degrees(-30).sin().raw(), -32768, 3, "sin(-30°)");
    }

    // ── atan2 ──
    #[test]
    fn atan2_quadrants() {
        // 角度以 +x 轴为 0，逆时针为正
        let cases: [(i32, i32, i32); 8] = [
            (0, 1000, 0),      //  +x → 0°
            (1000, 1000, 45),  //  45°
            (1000, 0, 90),     //  +y → 90°
            (1000, -1000, 135),
            (0, -1000, 180),
            (-1000, -1000, 225),
            (-1000, 0, 270),
            (-1000, 1000, 315),
        ];
        for (y, x, deg) in cases {
            let got = atan2(Mm::from_m(y), Mm::from_m(x));
            let want = Ang::from_degrees(deg).raw() as i32;
            let d = (got.raw() as i32 - want).abs();
            assert!(d <= 3 || d >= 65533, "atan2({y},{x}) = {:?}, 期望 {deg}°", got);
        }
        assert_eq!(atan2(Mm::ZERO, Mm::ZERO), Ang::ZERO);
    }

    #[test]
    fn atan2_known_slopes() {
        // tan(30°) ≈ 0.5774 → dy/dx = 577/1000
        let a = atan2(Mm::from_mm(577), Mm::from_mm(1000));
        assert_near(a.raw() as i32, Ang::from_degrees(30).raw() as i32, 3, "atan(0.577)");
        // 往返一致性：atan2 出来的角度再转回 sin/cos，方向应与原向量同向
        let v = Vec2::new(Mm::from_mm(-300), Mm::from_mm(400));
        let ang = atan2(v.y, v.x);
        let (c, s) = ang.to_dir();
        // 单位化后与原向量同向：cross ≈ 0 且 dot > 0
        let len = v.len();
        let ux = Q16::from_int(v.x.raw()).div(Q16::from_int(len.raw().max(1)));
        let uy = Q16::from_int(v.y.raw()).div(Q16::from_int(len.raw().max(1)));
        let cross = c.mul(uy).raw() as i64 - s.mul(ux).raw() as i64;
        assert!(cross.abs() < 400, "方向不一致，cross={cross}");
    }

    // ── Ang 工具 ──
    #[test]
    fn ang_helpers() {
        assert_eq!(Ang::from_degrees(0).abs_diff(Ang::from_degrees(90)), 16384);
        // 350° 与 10° 的夹角 = 20° ≈ 3641 单位
        assert_near(
            Ang::from_degrees(350).abs_diff(Ang::from_degrees(10)) as i32,
            3641,
            3,
            "abs_diff(350°, 10°)",
        );
        assert_eq!(Ang::from_degrees(10).opposite(), Ang::from_degrees(190));
        assert_eq!(Ang::from_degrees(0).diff_to(Ang::from_degrees(90)), 16384);
        assert_near(
            Ang::from_degrees(0).diff_to(Ang::from_degrees(350)) as i32,
            -1821,
            3,
            "diff_to(0° → 350°)",
        );
    }

    // ── Vec2 / Mm ──
    #[test]
    fn vec2_lengths() {
        let v = Vec2::new(Mm::from_m(3), Mm::from_m(4));
        assert_eq!(v.len(), Mm::from_m(5));
        assert_eq!(v.len_sq(), 25_000_000);
        assert_eq!(v.manhattan(), Mm::from_m(7));
        assert_eq!(v.chebyshev(), Mm::from_m(4));
        // 长距离不溢出：地图对角线 1024m × 1024m
        let d = Vec2::new(Mm::from_m(1024), Mm::from_m(1024));
        assert_near(d.len().raw(), 1_448_154, 2, "对角线长度(mm)");
    }

    #[test]
    fn mm_scaling() {
        assert_eq!(Mm::from_m(3).mul_q16(Q16::HALF), Mm::from_mm(1500));
        assert_eq!(Mm::from_m(1).raw(), 1000);
        assert_eq!(Mm::from_m(-2).abs(), Mm::from_m(2));
    }

    // ── 表完整性（防止有人手改生成物）──
    #[test]
    fn tables_sane() {
        assert_eq!(tables::SIN_QUARTER.len(), 1025);
        assert_eq!(tables::ATAN_RATIO.len(), 1025);
        assert_eq!(tables::SIN_QUARTER[0], 0);
        assert_eq!(tables::SIN_QUARTER[1024], 65536);
        assert_eq!(tables::ATAN_RATIO[0], 0);
        assert_eq!(tables::ATAN_RATIO[1024], 65536);
        for i in 1..1025 {
            assert!(
                tables::SIN_QUARTER[i] >= tables::SIN_QUARTER[i - 1],
                "sin 表在 {i} 处非单调"
            );
            assert!(
                tables::ATAN_RATIO[i] >= tables::ATAN_RATIO[i - 1],
                "atan 表在 {i} 处非单调"
            );
        }
    }

    // ── PCG32：与 tools/gen_trig.py 的参考实现逐位一致 ──
    #[test]
    fn pcg32_matches_reference() {
        // 参考值由 `python3 tools/gen_trig.py --emit-pcg` 生成（seed=0x1234_5678_9ABC_DEF0, stream=7）
        let expected: [u32; 4] = [0x11905EAA, 0x20B66266, 0x145F726E, 0x801BDF1F];
        let mut rng = Pcg32::new(0x1234_5678_9ABC_DEF0, 7);
        for (i, e) in expected.iter().enumerate() {
            assert_eq!(rng.next_u32(), *e, "第 {i} 个输出与参考实现不一致");
        }
    }

    #[test]
    fn pcg32_determinism_and_streams() {
        let a: Vec<u32> = {
            let mut r = Pcg32::new(42, 1);
            (0..16).map(|_| r.next_u32()).collect()
        };
        let b: Vec<u32> = {
            let mut r = Pcg32::new(42, 1);
            (0..16).map(|_| r.next_u32()).collect()
        };
        assert_eq!(a, b, "同种子必须产生相同序列");

        // 不同流必须产生不同序列
        let c: Vec<u32> = {
            let mut r = Pcg32::new(42, 2);
            (0..16).map(|_| r.next_u32()).collect()
        };
        assert_ne!(a, c, "不同 stream 必须产生不同序列");

        // 决策流：同 (system, entity, tick) 必须复现
        let d1 = Pcg32::for_decision(1, 3, 17, 900).next_u32();
        let d2 = Pcg32::for_decision(1, 3, 17, 900).next_u32();
        assert_eq!(d1, d2);
        assert_ne!(d1, Pcg32::for_decision(1, 3, 17, 901).next_u32());
    }

    #[test]
    fn pcg32_ranges_and_chance() {
        let mut rng = Pcg32::new(7, 3);
        for _ in 0..10_000 {
            let v = rng.next_range(10);
            assert!(v < 10, "越界: {v}");
        }
        // 概率 0 与 1 必须是确定的
        let mut r = Pcg32::new(9, 1);
        assert!(!r.chance(Prob::NEVER));
        assert!(r.chance(Prob::ALWAYS));
        // 50% 的粗略分布检查（有种子，确定性）
        let mut r = Pcg32::new(11, 5);
        let mut hits = 0;
        for _ in 0..10_000 {
            if r.chance(Prob::from_permille(500)) {
                hits += 1;
            }
        }
        assert!((4500..=5500).contains(&hits), "分布异常: {hits}/10000");
        // Q16 单位值在 [0, 1)
        let mut r = Pcg32::new(13, 1);
        for _ in 0..1000 {
            let q = r.next_q16_unit();
            assert!(q.raw() >= 0 && q.raw() < 65536);
        }
    }

    #[test]
    fn prob_conversions() {
        assert_eq!(Prob::from_q16(Q16::ZERO), Prob::NEVER);
        assert_eq!(Prob::from_q16(Q16::ONE), Prob::ALWAYS);
        assert_near(
            Prob::from_q16(Q16::HALF).raw() as i32,
            32767,
            2,
            "Prob::from_q16(0.5)",
        );
        assert_near(Prob::from_permille(250).raw() as i32, 16383, 2, "25%");
        assert_eq!(Prob::from_permille(1000), Prob::ALWAYS);
    }
}
