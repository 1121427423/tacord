# tacord

指挥官只下达战术命令，AI 士兵根据地形、掩体和战局自主判断与作战。

3D 战术指挥游戏 · macOS Apple Silicon (arm64) 一等公民 · 深度掩体 AI

---

## 核心理念

- **真实的墙，真实的掩体** —— 每一堵墙、每只木箱、每辆汽车、每具残骸、每条战壕、每扇窗户都能当掩体，因为士兵根据周围物体的实际形状来判断。没有手工掩体标记，没有脚本。一旦被侧翼包抄，这处掩体立刻失效。
- **他们像真正的士兵一样作战** —— 矮墙后蹲下、起身开火、再伏低；高墙边探身、侧射、缩回。蹲下就真的看不见，站起来就真的会暴露。
- **他们会听，会记，也想活下去** —— 转向看不见的枪声，用无线电共享敌情，记住子弹从哪来。除非你下令，否则不会穿过火力杀伤区。
- **每一发子弹都算数** —— 近失弹会压得人抬不起头；弹药真的会打光，阵地会沉寂，士兵会从尸体上摸走弹匣。
- **绝不丢下任何人** —— 倒下不等于阵亡：爬行、呼救、被拖回、救治、归队。但每次倒下都更虚弱，好运迟早会用完。
- **没有什么是凭空建成的** —— 放下蓝图，士兵走过去亲手把它建起来，战斗仍在他们周围继续。补给靠卡车沿路运输，链路被切断，断点之后全线瘫痪。

## 文档

设计文档在 [`docs/design/`](docs/design/)：

| 文档 | 内容 |
| --- | --- |
| [05-frozen-parameters.md](docs/design/05-frozen-parameters.md) | **参数冻结表**：按改动代价分级的跨系统常量、AI 实现方式裁定、审查修复对照 R1–R11（动工前必读） |
| [00-overview.md](docs/design/00-overview.md) | 设计总纲：支柱、范围、参考素材拆解、玩法循环、术语表 |
| [10-architecture.md](docs/design/10-architecture.md) | 技术选型、macOS/ARM 方案、仓库结构、确定性模拟核心、性能预算、网络、CI |
| [20-cover-perception.md](docs/design/20-cover-perception.md) | 掩体系统（真实几何派生）、感知、记忆与无线电、压制、威胁场 |
| [30-soldier-ai-combat.md](docs/design/30-soldier-ai-combat.md) | 三层 AI、士气与指挥链、姿态与动作集、弹道/穿透/跳弹、弹药经济 |
| [40-wounded-intel-base.md](docs/design/40-wounded-intel-base.md) | 伤员与医疗链路、俘虏与情报战、坦克/FPV、FOB 与补给链 |
| [90-roadmap-acceptance.md](docs/design/90-roadmap-acceptance.md) | 里程碑、量化验收标准、风险登记、开放问题 |
| [_open_visual_questions.md](docs/design/_open_visual_questions.md) | 参考视频待人工确认的视觉/手感问题 |

## 参考素材

`assets/` 下为两段官方参考预告片（`Defilade_Steam_Trailer_720p_part1/2.mp4`，42s + 84s，1280×720@30fps）。

## 技术栈（拟定）

- **引擎**：Godot 4.7.x（原生 arm64 编辑器，Apple Silicon 上有原生 Metal 后端，MoltenVK 回退）
- **模拟核心**：`sim_core` —— 与引擎无关的 Rust 库（定点数学、确定性、可 headless 回放与 bench）
- **绑定**：GDExtension 薄层；GDScript 只做 UI/相机/特效胶水
- **多人**：确定性 Lockstep + 命令延迟（输入只有命令，天然适合）

详细理由与备选方案见 [`10-architecture.md`](docs/design/10-architecture.md)。

## 状态

设计文档 v1.1：已完成第一轮评审的 11 项修复（R1–R11）。
当前阶段：**M0 技术验证**（M0.1 定点数学库已完成，CI 全绿；M0.2 体素世界与射线进行中）。当前阶段：**先出设计文档**，实现从 M0（技术验证）开始。
