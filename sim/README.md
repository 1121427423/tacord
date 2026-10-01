# sim · 模拟核心

与引擎无关的模拟层。**不依赖 Godot**，可在无渲染环境下跑测试、回放与 bench —— 这是本项目
"AI 与表现解耦"原则的落地点，也是 CI 能在 Linux 上验证全部逻辑的原因。

## 已实现

| crate | 状态 | 内容 |
| --- | --- | --- |
| `sim_math` | ✅ M0.1 | 确定性定点数学：`Mm` / `Ang` / `Q16` / `Prob` / `Vec2`、`sin/cos/atan2`（烘焙查找表 + 整数插值）、整数 `sqrt`、`Pcg32`（按 system/entity/tick 分流） |
| `sim_core` | ⬜ M0.2 | 体素柱世界、破坏与挖掘、体素 DDA 射线 |
| `sim_cli` | ⬜ M0.3 | 跑图 / 回放 / bench / 调试导出 |

## 硬性约束

1. **禁止浮点**：`#![deny(clippy::float_arithmetic)]`。浮点在不同平台可能有 1ulp 差异，会毁掉
   bit-exact lockstep 与逐位一致的回放。
2. **禁止 libm**：三角函数走 `tools/gen_trig.py` 生成并**提交进仓库**的查找表。
   > 为什么不能用 `build.rs` 生成表：build.rs 依赖宿主机 libm 的 `sin()`，不同平台的 1ulp
   > 差异会让两台机器拿到不同的表 → 静默 desync。表必须烘焙。
3. **禁止 Godot 依赖**：CI grep 强制（`sim/` 里出现 `godot` 即失败）。

## 构建与测试

```bash
cd sim
cargo test                 # 调试构建（开启溢出检查 —— 定点运算最容易在这里翻车）
cargo test --release       # 性能与最终验证
python3 tools/gen_trig.py --check      # 查找表必须与生成器一致
python3 tools/check_constants.py       # 常量自检（38 项）
```

> **沙箱开发机没有 Rust 工具链**（`sh.rustup.rs` 被网络策略拦截、无 root 装不了 deb）。
> 因此 `.github/workflows/sim.yml` 同时充当编译器：推送后由 GitHub Actions 真正编译并跑单测，
> 用 `gh run list --workflow=sim.yml` / `gh run view <id>` 查看结果。
> 日志下载域名在本沙箱被拦截，定位失败用例的办法是：用 `tools/` 下的 Python 参考实现
> 复现同一套整数算法（逐位一致），在本地二分出断言。

## 定标速查

| 类型 | 表示 | 范围 / 精度 |
| --- | --- | --- |
| `Mm` | `i32` 毫米 | ±2147 km，1 mm |
| `Ang` | `u16` 角度 | 0..65535 ≡ 0..2π，1 单位 ≈ 0.0055° |
| `Q16` | `i32` Q16.16 | ±32767.99998，精度 1.5e-5 |
| `Prob` | `u16` 概率 | 0..65535 ≡ 0..1 |

常量（地图尺寸、tick 频率、单位上限…）一律来自 `sim/data/constants.ron`，
详见 [`docs/design/05-frozen-parameters.md`](../docs/design/05-frozen-parameters.md)。
