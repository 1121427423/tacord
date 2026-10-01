//! `sim_core` —— 体素世界、射线与破坏管线。
//!
//! 与 `sim_math` 一样：无浮点、无 libm、无引擎依赖。
//!
//! **最重要的一条**：`ray::cast` 是**唯一**的"这条线被挡住了吗"判定。
//! 掩体派生（"我藏住了吗"）、视线（"我看得见他吗"）、弹道（"我打得中吗"）
//! 全部调用它，因此三者不可能出现规则分歧（设计文档 §20.1.3.1 / §30.3.2）。

#![deny(unsafe_code)]
#![deny(clippy::float_arithmetic)]

pub mod ray;
pub mod world;

pub use ray::{blocked, cast, hit_point, RayHit, RayMode};
pub use world::{Material, Segment, World};

/// 每根柱（cell）的边长：500 mm（= `constants.ron` 的 `world.column_size_mm`）。
pub const CELL_MM: i64 = 500;

/// 向零截断的整除（Rust 的 `/` 语义，这里显式写出以免误读）。
#[inline]
pub(crate) const fn tdiv(a: i64, b: i64) -> i64 {
    a / b
}

/// 地板除（`b > 0`），处理负数：Rust 的 `/` 向零截断，需要修正。
#[inline]
pub(crate) fn floor_div(a: i64, b: i64) -> i64 {
    if a >= 0 {
        a / b
    } else {
        (a - b + 1) / b
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floor_div_matches_floor_semantics() {
        // 关键：-1..-499 的负数必须向下取整，而不是向零截断（否则整张地图的
        // 世界外格子会整体偏移一格 —— 原型阶段真实踩到过）
        assert_eq!(floor_div(0, 500), 0);
        assert_eq!(floor_div(499, 500), 0);
        assert_eq!(floor_div(500, 500), 1);
        assert_eq!(floor_div(-1, 500), -1);
        assert_eq!(floor_div(-499, 500), -1);
        assert_eq!(floor_div(-500, 500), -1);
        assert_eq!(floor_div(-501, 500), -2);
        assert_eq!(floor_div(-1000, 500), -2);
        assert_eq!(floor_div(-1001, 500), -3);
    }
}
