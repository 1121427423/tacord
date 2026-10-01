# tacord 设计文档

> 指挥官只下达战术命令，AI 士兵根据地形、掩体和战局自主判断与作战。
> 3D · macOS Apple Silicon (arm64) 一等公民 · 深度掩体 AI

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [05-frozen-parameters.md](05-frozen-parameters.md) | **参数冻结表（动工前必读）**：按改动代价分级的跨系统常量、AI 实现方式裁定、未冻结参数清单、**§21 审查修复对照 R1–R11** |
| [00-overview.md](00-overview.md) | 设计总纲：支柱、范围与非目标、参考素材拆解、玩法循环、术语表 |
| [10-architecture.md](10-architecture.md) | 技术选型与 macOS/ARM 方案、仓库结构、确定性模拟核心、渲染与性能预算、网络、CI |
| [20-cover-perception.md](20-cover-perception.md) | 掩体系统（真实几何派生）、视线/听觉/记忆/无线电、压制、威胁场与杀伤区 |
| [30-soldier-ai-combat.md](30-soldier-ai-combat.md) | 三层 AI 架构、士气与指挥链、姿态与动作集、弹道/穿透/跳弹、弹药经济、手榴弹与爆炸、表现层 |
| [40-wounded-intel-base.md](40-wounded-intel-base.md) | 伤员与医疗链路、俘虏与情报战、坦克/无人机、基地建造与补给链、占领与失败条件 |
| [90-roadmap-acceptance.md](90-roadmap-acceptance.md) | 里程碑、量化验收标准、风险登记、开放问题、参数总表索引 |

## 阅读顺序

1. 先看 `00-overview.md` 确认目标与边界，再读 **`05-frozen-parameters.md`**（所有 T0 常量在此定死，避免后期返工）；
2. 技术负责人看 `10-architecture.md`（选型与 macOS 方案在此定稿）；
3. 系统实现按 `20 → 30 → 40` 顺序，每份文档末尾都有"实现清单（DoD）"；
4. 排期与验收看 `90-roadmap-acceptance.md`。

> **v1.1（2026-10-01）**：完成第一轮设计评审的 11 项修复（R1–R11），
> 集中在：lockstep 的模拟边界与信息可见性、逐点命中规则、几何与导航表示、伤员状态机、
> M1 依赖、范围与排期、性能与跨平台验收口径。逐条对照见 [05 §21](05-frozen-parameters.md#21-审查修复对照r1r11)。

## 实现进度（M0 技术验证）

| 步骤 | 内容 | 状态 |
| --- | --- | --- |
| M0.1 | `sim_math` 确定性定点数学（`Mm`/`Ang`/`Q16`/`Prob`/`Vec2`、sin/cos/atan2、sqrt、Pcg32） | ✅ 已完成（45 项单测，CI 双构建通过） |
| M0.1b | 查找表生成器 `tools/gen_trig.py` + `tools/check_constants.py` 常量自检 | ✅ 已完成（CI 强制） |
| M0.2 | `sim_core` 体素柱世界 + 破坏/挖掘 + 体素 DDA 射线 | ⬜ 下一步 |
| M0.3 | `sim_cli bench`（400 单位 / 10 万 tick 性能基线） | ⬜ |
| M0.4 | Godot 薄绑定 + macOS arm64 导出 | ⬜ |

## 状态

- 版本：v0.1（初稿，待评审）
- 已定稿：**目标平台（macOS arm64）**、**掩体必须来自真实几何**、**模拟与表现解耦**
- 已拍板：**D-1 Rust**、**D-2 定点**、D-3…D-8 全部裁定（见 `05-frozen-parameters.md` §17）；推翻 D-1/D-2 只能在本周内提出（之后属 T0 返工）
- 参数单一数据源：`sim/data/constants.ron`，由 `tools/check_constants.py` 做 38 项一致性自检（CI 强制）
