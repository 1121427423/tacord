# 10 · 技术架构（含 macOS / Apple Silicon 方案）

## 10.1 选型结论（先给答案）

| 层 | 选择 | 理由 |
| --- | --- | --- |
| 引擎 / 编辑器 / 渲染 / UI | **Godot 4.7.x**（稳定线；4.8 仍在 dev） | MIT 许可；**原生 arm64 macOS 编辑器**；Apple Silicon 上有**原生 Metal 后端**（4.4 起，仅 arm64），Intel Mac 走 MoltenVK；内置导航、物理、动画、UI、导出模板 |
| 模拟核心（AI / 掩体 / 弹道 / 经济） | **独立库 `sim_core`**，不依赖引擎，可被 headless CLI 与 CI 直接跑 | AI 是本项目 80% 的复杂度与风险，必须与表现层解耦，才能确定性回放、批量测试、并行优化、将来做服务器权威 |
| `sim_core` 语言 | **首选 Rust**（`gdext` 绑定，5.1k★，2026 年仍活跃维护）；**备选 C++20 / godot-cpp** | 数据导向、无 GC 抖动、`rayon` 并行、内存安全；`cargo test` + `proptest` 直接跑在 CI |
| 绑定方式 | Rust `cdylib` → GDExtension（`gdext`）；若 `gdext` 在某版本卡住，**退路**：`cbindgen` 导出 C ABI，用一层薄的 C++ GDExtension 包装 | 把"绑定风险"限制在一个可替换的薄层里 |
| 脚本层 | GDScript 只做**胶水**：UI、相机、特效、音频触发、关卡装载 | 保持热重载的迭代速度；所有游戏规则一律在 `sim_core` |
| 多人 | **确定性 Lockstep + 命令延迟**（输入只有命令，频率低，天然适合 RTS 式同步） | 支持回放、观战、断线重连、反作弊校验；见 §10.9 |

> 决策点 D-1（Rust vs C++）、D-2（定点 vs 浮点）见 `90-roadmap-acceptance.md`。默认按 Rust + 定点执行。

### 10.1.1 为什么不选其他方案

| 方案 | 否决原因 |
| --- | --- |
| Unreal 5 | 编辑器和着色器编译在 M 系列上迭代慢；Nanite/Lumen 对低多边形俯视 3D 是负担；授权与包体成本高 |
| Unity 6 | 技术能力足够（DOTS/ECS 适合大规模 AI），但许可政策与编辑器体积/启动成本对 1–2 人团队不友好；金属后端成熟是加分项 |
| Bevy / 自研 wgpu | 数据导向 ECS 天然契合本项目，但编辑器、动画、地形与美术工具链要全部自研，工期风险不可接受 |
| 纯 GDScript | 400 单位 ×30Hz 的射线级模拟无法达标（解释器开销 + GC 抖动） |
| Godot C# | macOS 公证需要 JIT entitlement，Hardened Runtime 下摩擦大；且我们需要的是"引擎无关的 sim"，不是更快的脚本 |

## 10.2 macOS / Apple Silicon 专项

这是"一等公民"承诺的落地清单，逐条都要有人负责。

### 10.2.1 渲染后端
- **默认：Metal 后端**（Godot 4.4+ 提供，仅 Apple Silicon）。在 `boot` 时探测：支持 Metal 的 arm64 设备 → `--rendering-driver metal`；否则回退 MoltenVK（Vulkan）→ 再回退 Compatibility（GL，仅 Intel Mac 应急）。
- 提供启动参数与设置项 `video/driver: auto|metal|vulkan|gl`，玩家可手动覆盖，崩溃两次自动降级并写日志。
- **禁止**依赖硬件光追、mesh shader、bindless（Metal 3 有部分能力但 Godot 封装不可控）。
- Tile-based GPU 注意：减少全屏 pass 数量，后处理合并为 1–2 个；避免不必要的 `render_target` 读写回。

### 10.2.2 内存（统一内存架构，8GB 是硬约束）
| 预算项 | 上限 |
| --- | --- |
| sim 状态（400 单位 + 世界柱 + 掩体缓存） | ≤ 384 MB |
| 几何（chunk 网格 + 实例） | ≤ 1.5 GB |
| 纹理（ASTC 压缩，Metal 原生） | ≤ 1.0 GB |
| 音频（流式，短音效常驻） | ≤ 256 MB |
| 渲染 target（1080p，含阴影图） | ≤ 400 MB |
| **合计（M1 8GB 目标）** | **≤ 3.5 GB** |

- 统一内存没有独立显存，CPU/GPU 共享带宽：**避免 CPU 每帧回读 GPU 数据**（如 GPU 拾取、读回缓冲）；拾取一律在 CPU 侧用 sim 的柱数据做射线。
- 柱数据用 SoA + 分块 RLE；远景 chunk 只保留碰撞/掩体用的精简层（"碰撞 LOD"），不保留渲染网格。

### 10.2.3 CPU 与调度
- Apple Silicon 有性能核/能效核：**不要用 `num_cpus` 盲目起满线程**。用 `rayon` 的默认线程池（会读取逻辑核数），但对长任务启用 QoS（`pthread_set_qos_class_self_np`/`dispatch` 默认继承），并在"省电模式"下把 job 线程数限制到性能核数量。
- 帧率上限默认 60（可选 30 / 60 / 120 / 不限制）；后台自动降到 30 并把 AI tick 降到 15Hz。
- 热节流：监测帧时间滑动窗口，连续 2 秒超预算 → 依次降级：后处理 → 阴影级数 → 单位渲染距离 → AI LOD 距离 → 分辨率缩放（最低 0.75x）。

### 10.2.4 打包、签名与公证
- 导出 **arm64-only** app bundle（`macos` 导出模板，arch=arm64）。不做 universal2（体积翻倍、且我们不支持 Intel）。
- Hardened Runtime + `codesign --timestamp`；提供两条通道：
  - **开发/分发的 ad-hoc 签名**：`codesign -s -`，能在本机与已授权机器运行；
  - **正式分发**：Developer ID Application 签名 + `notarytool` 公证 + stapling（需要 Apple 开发者账号，$99/年）。CI 里通过 secrets 注入证书，未配置时自动产出 ad-hoc 版本并标记为未公证。
- 必要 entitlements：`com.apple.security.cs.allow-jit`（仅当绑定层需要）、`com.apple.security.device.audio-input`（若做语音）、`com.apple.security.files.user-selected.read-write`（关卡/回放导入导出）。**若用 Rust/C++ 而非 C#，则不需要 JIT 权限**，这是选 Rust/C++ 的一个附加收益。
- `.dmg` 采用简单的拖拽式布局；同时提供 `.zip`。Gatekeeper 首启动说明写进 README。

### 10.2.5 构建矩阵与 CI
| Runner | 任务 |
| --- | --- |
| `ubuntu-latest` | `cargo test`（单测 + 属性测试）、`cargo bench`（性能回归）、确定性回放黄金用例、Godot headless 冒烟、Linux 构建 |
| `macos-15`（arm64，固定版本避免 `macos-latest` 漂移） | 构建 arm64 app bundle、签名、`.dmg`、启动自检（打开 → 跑 30 秒 → 退出码 0 → 校验日志无 ERROR） |
| `macos-26`（arm64） | 前瞻验证（可选，允许失败） |
| `ubuntu-latest` + Godot Web 模板 | 导出 Web 版本，推送到 Pages 供快速预览（**注意**：Web 版性能不代表真机，仅用于逻辑/UI 走查） |

- 沙箱开发机是 **Linux x86_64**，无法产出/验证 macOS 构建。因此：**所有能在 Linux 上验证的东西（sim、逻辑、回放、bench）都必须在 Linux 上验证**，macOS runner 只负责"打包 + 能启动"。这是本项目的测试策略基石。

## 10.3 仓库结构

```
tacord/
├── README.md
├── assets/                     # 原始参考素材（视频/原画），不参与构建
│   └── *.mp4
├── docs/design/                # 本文档集
├── sim/                        # Rust workspace：引擎无关的模拟核心
│   ├── Cargo.toml
│   ├── crates/
│   │   ├── sim_core/           # 世界、柱、掩体、感知、AI、战斗、经济
│   │   │   └── src/{world,cover,perception,ai,combat,wounded,intel,economy,vehicles,math}
│   │   ├── sim_math/           # 定点数学、查表三角、定点随机、定点向量
│   │   └── sim_cli/            # headless：跑图、回放、bench、场景生成、调试导出
│   └── data/                   # 数据驱动参数（ron/toml）
│       ├── weapons.ron  materials.ron  units.ron  ai_weights.ron  build_costs.ron
├── godot/                      # Godot 4 工程
│   ├── project.godot
│   ├── tacord.gdextension
│   ├── bin/                    # 编译产物（各平台动态库，gitignore）
│   ├── scripts/                # GDScript 胶水
│   ├── scenes/  art/  ui/  audio/
├── levels/                     # 关卡（高度图 + 建筑布局 + 初始部署，ron）
├── replays/                    # 黄金回放（输入 + 期望校验和）
├── tools/
│   ├── build.sh  export_macos.sh  notarize.sh  gen_level.py
└── .github/workflows/{sim.yml,export.yml,pages.yml}
```

**规则**：`sim/` 里不允许出现任何 `godot` 的 import；`godot/scripts/` 里不允许出现任何游戏规则（只允许读 sim 状态 → 表现）。CI 用 grep 强制这条边界。

## 10.4 确定性模拟核心

### 10.4.1 时间步进
| 层 | 频率 | 内容 |
| --- | --- | --- |
| 渲染 | 显示刷新率（自由） | 插值 sim 状态、粒子、UI |
| **Sim tick** | **固定 30 Hz（33.33ms）** | 移动、弹道、物理、感知、AI 执行、经济 |
| 感知更新 | 10 Hz（每 3 tick） | 视线检测、听觉事件、contact 更新 |
| 掩体评估 | 5 Hz（每 6 tick） | 候选掩体打分、姿态决策（事件可打断） |
| 班组层 | 2 Hz | 角色分配、跃进节奏、救援调度 |
| 指挥层 | 1 Hz | 目标选择、兵力分配、补给与建造优先级 |
| 掩体/导航重建 | 事件驱动 + 摊还 | 柱被破坏 → chunk 标脏 → 每帧最多重建 2 个 chunk |

- 所有"低频系统"用**摊还调度**（分桶：每 tick 处理 1/N 的单位/班组），保证单 tick 峰值可控。事件（受伤、发现敌人、命令变更、掩体失效、掩体被毁）可**立即触发**重算，绕过摊还。

### 10.4.2 定点数学（`sim_math`）
- 位置：`i32`，单位 **毫米**（±2147 km，1mm 精度）。
- 方向/角度：`u16`（0..65535 ≡ 0..2π）。
- 标量（速度、概率、系数）：`Q16.16` 的 `i32`（±32767.99998，精度 1.5e-5）。
- 三角/开方：查表 + 线性插值（`sin` 4096 项表 + 插值），`atan2` 用定点多项式。**不使用 `libm`**（跨平台/跨编译器的 `sin/sqrt` 可能有 1ulp 差异，会毁掉 lockstep）。
- 随机：每个系统一条独立的 `xorshift128`/`pcg32` 流，seed 来自 `(level_seed, system_id, entity_id, tick)`，保证并行执行顺序无关。
- 编译约束：`-C opt-level=3`，**禁用**任何 fast-math（Rust 无此开关，天然安全）；禁止在 sim 里使用 `f32/f64`；用 `#[deny]` + CI grep 强制。

> **退路（方案 B，见 D-2）**：若定点改造成本过高，则 sim 用 `f64` + 严格纪律（固定同一编译器版本、禁用 FMA 收缩、统一 libm、CI 三平台校验和比对），并**放弃 lockstep**，改用服务器权威快照同步。代价：回放/bench 的价值下降、多人带宽上升。不推荐，但保留。

### 10.4.3 数据布局
- 自研 SoA（不是通用 ECS 框架）：每个系统拥有自己的列式数组（`positions: Vec<Vec2i>`, `postures: Vec<Posture>`, ...）。理由：sim 的实体种类少、生命周期简单，自研比通用 ECS 更易确定性排序与内存预算。
- 实体句柄：`u32`（index 24bit + generation 8bit），失效句柄访问在 debug 下 panic。
- 命令缓冲：AI 决策阶段只写入 `CommandBuffer`，在 tick 末统一 apply，保证并行阶段无别名写入。

### 10.4.4 并行
```
tick 内阶段（阶段内并行，阶段间串行）：
 1. 输入            （应用玩家命令 / 网络命令）
 2. 世界事件摊还    （dirty chunk 重建：掩体槽、导航代价、碰撞层）
 3. 感知            （批量射线 rayon 并行 → contact 增量）
 4. 决策            （指挥层 → 班组层 → 士兵层；按 squad 分片并行，写 CommandBuffer）
 5. 执行            （移动、弹道、动作状态机；并行，写 CommandBuffer）
 6. 结算            （伤害、压制、士气、经济、胜负判定；串行）
 7. 校验和          （每 30 tick 计算一次 sim 状态哈希）
```
- 目标：400 单位时，阶段 3–5 在 M1 上并行后 **≤ 8ms/tick**（见 §10.7 预算）。

## 10.5 世界表示

- **体素柱（Voxel Column）**：XZ 平面 0.5m 栅格，每根柱记录：
  ```
  height_mm: i32          // 实体顶面高度（地面或建筑顶面）
  material: u16           // 索引 materials.ron
  hp: u16                 // 结构强度（破坏用）
  flags: u8               // SOLID / DESTRUCTIBLE / CLIMBABLE / TRENCH / WATER / DOOR / TUNNEL ...
  occupancy: u8           // 被单位/工事临时占用的标记（不阻挡视线时可忽略）
  ```
  多层结构（二楼、桥、窗户）用 **layer list**（每柱 1–4 段 `{bottom_mm, top_mm, material, hp}`），支持"窗户可射击、楼板可打穿、可从二楼阳台往下打"。
- 地图规模：**1024 m × 1024 m → 2048×2048 = 4.19M 柱**。按 32×32 chunk 分块（64×64 = 4096 chunk）。尺寸为 2 的幂（1024=2^10 m / 0.5=2^-1 m / 32=2^5），索引与空间哈希全部可用位移实现。空旷地面柱用 RLE 压缩，实测目标 ≤ 62 MB（CI 自检 `tools/check_constants.py` 会校验内存估算）。
- **破坏**：伤害 → 减少段 hp → 归零则该段消失（或降级为"残骸段"，高度减半）→ chunk 标脏 → 触发掩体槽、导航代价、渲染网格的局部重建。
- **挖掘**：战壕/地道是"降低柱高度 + 标记 TRENCH/TUNNEL"，与破坏共用同一条修改管线（这是让"挖战壕"真实存在的关键）。

## 10.6 渲染与表现（Godot 侧）

| 项目 | 方案 |
| --- | --- |
| 地形/建筑网格 | 每个 chunk 做 surface-nets/greedy 网格化，生成静态 `ArrayMesh`；破坏只重建脏 chunk，**每帧最多 2 个**（预算 1ms） |
| 单位 | 角色 ≤ 3000 三角、≤ 30 骨骼；用 **MultiMesh/InstancedMesh + 骨骼动画烘焙到纹理（bone texture / VAT）**，每阵营每 LOD 1 个 draw call；近景（≤ 30m 且 ≤ 12 个）切真实 `Skeleton3D` 以获得精细动画 |
| 阴影 | 单方向光 + CSM 3 级（2048/1024/512，覆盖 400m）；单位用 blob/contact shadow 补充 |
| 后处理 | 至多：TAA/FXAA + 色调映射 + 轻微暗角；**不用 SSAO**（用烘焙 AO + 接触阴影代替） |
| 可读性（俯视 3D 的生命线） | ①脚下阵营环（可关）；②被建筑遮挡时用 **X 光描边** shader 显示单位轮廓；③曳光弹 + 弹着尘土 + 枪口焰；④按住 Alt 显示附近掩体槽评分热力；⑤选中单位显示视锥、目标、威胁箭头；⑥AI 调试层（F1–F4：掩体图 / 威胁场 / contact 表 / 当前任务与评分） |
| 相机 | 斜俯视轨道相机：俯角 20°–75°、距离 15–120m、WASD/边缘平移、滚轮缩放、双击单位跟随；"Cinematic"只读跟随（肩后/头顶），不改变控制方式 |

## 10.7 性能预算（Apple Silicon）

**目标**：M1（8GB）1080p / 60fps / 400 单位同屏；M4 Pro 1440p / 120fps / 800 单位。

单帧 16.67ms 预算（M1）：
| 项 | 预算 |
| --- | --- |
| sim tick（30Hz，摊到 60fps 帧上约 0.5 次/帧） | 8.0 ms（AI+感知 ≤ 5.0，弹道/移动 ≤ 1.5，世界维护 ≤ 1.5） |
| 渲染提交（CPU） | 3.0 ms |
| GPU | 5.0 ms |
| 余量 / 系统 | 0.67 ms |

Sim tick 内部 33.33ms 预算（400 单位）：
| 系统 | 预算 | 手段 |
| --- | --- | --- |
| 感知（LOS/听觉） | 4.0 ms | 批量射线、摊还到 10Hz（即每 tick 1/3 单位）、距离剔除、cache |
| 掩体评估 | 2.0 ms | 摊还到 5Hz、候选集 top-K 剪枝（≤ 12 个槽）、评分缓存 |
| 决策（指挥/班/兵） | 1.5 ms | 低频 + 事件驱动 |
| 移动 / 避让 | 1.0 ms | flow field + 局部 steering |
| 弹道 | 1.0 ms | 段射线、按 chunk 空间哈希、实体上限 4000 |
| 世界维护（破坏/重建） | 1.5 ms | 摊还、脏队列 |
| **合计** | **11.0 ms / 33.33ms** | 余量用于 GC-free 抖动与降级空间 |

**AI LOD**（按到相机距离 + 是否在战斗中）：
| 级别 | 条件 | 行为 |
| --- | --- | --- |
| Full | ≤ 80m 或 玩家选中/关注 | 10Hz 感知、5Hz 掩体评估、完整动作集 |
| Reduced | ≤ 250m | 3Hz 感知、1.5Hz 掩体评估、简化的动作集（无翻越/滑铲动画，只有位移） |
| Dormant | > 250m 且 无战斗事件 | 0.5Hz，只更新位置与存亡；进入战斗事件立即唤醒 |

**禁止项**（性能红线）：sim tick 内不做堆分配（用 arena/池）、不做字符串操作、不做 Godot 调用、不做文件 IO；所有日志走结构化环形缓冲（debug 构建才写盘）。

## 10.8 数据驱动与调试工具

- 所有可调参数放 `sim/data/*.ron`：`weapons.ron`（弹速/伤害/穿透/误差锥）、`materials.ron`（穿透代价/破坏阈值/声音）、`units.ron`（模板：血量、nerve、携弹、视野）、`ai_weights.ron`（掩体评分权重、威胁场权重、士气曲线）、`build_costs.ron`。开发期支持热重载（文件变化 → 重建只读表，不重启）。
- `sim_cli` 子命令：
  - `sim_cli bench --units 400 --ticks 10000`：输出各系统 p50/p99 耗时；CI 做回归阈值。
  - `sim_cli replay <file> --verify`：跑黄金回放并比对校验和。
  - `sim_cli headless --level x --script cmds.txt`：无渲染跑完一局，输出统计（伤亡、命中率、弹药消耗、投降次数）。
  - `sim_cli dump --what cover|threat|contacts --png`：把内部数据导出为可视化图（调试神器，也用于文档配图）。
- **AI 可解释性是硬需求**：任何决策都能回答"他为什么这么做"（当前任务、候选掩体评分 top-3、威胁方向、contact 源、被否决的原因）。UI 与 CLI 都要能展示。

## 10.9 网络（Lockstep）

- 输入只有"命令"（玩家下达、低频、小体积）→ 天然适合 lockstep。
- 每个客户端在本地跑完整 sim；命令附带执行 tick = 当前 tick + `input_delay`（默认 6 tick ≈ 200ms，可调；被压制/距离远时增加，模拟"无线电传递"延迟，且是玩法的一部分）。
- 每 tick 广播命令（可靠有序），收到落后 tick 的命令 → 请求对端重传；超过窗口未收到 → 暂停（stall）等待（显示"等待指挥网络"）。
- **校验和**：每 30 tick 广播 sim 状态哈希；不一致 → 立即保存分歧点前后 60 tick 的回放并断线（用于定位不确定性 bug，这是选定点数最大的回报）。
- **快照**：每 1800 tick（60 秒）存一次全量压缩快照（差量 + zstd），用于观战加入与断线重连（重连 = 拉最近快照 + 追帧）。
- 合作模式：2 名玩家共享一个阵营的控制权，命令合并进同一命令流，权限可配置（全局 / 按班组 / 只读观察）。
- 对战模式：同上，各自阵营。
- **防作弊**：因为每个客户端都有全量状态，反作弊依赖"校验和一致性 + 断线即败"；不做隐藏信息（本作无战争迷雾式隐藏，但感知是真实的：你看到的敌情=你单位看到的敌情，这是设计的一部分）。

## 10.10 测试策略

| 层级 | 内容 |
| --- | --- |
| 单元 | `sim_math` 定点数学（含边界、插值一致性）、穿透/跳弹公式、评分函数 |
| 属性测试（proptest） | ①任意几何 → 掩体槽与真实遮挡一致（用暴力采样做 oracle）；②任意命令序列 → 不 panic、不越界、无 NaN/溢出；③单位不会静止在 blocking < 0.1 的位置超过 X 秒（除非被命令强制） |
| 黄金回放 | ≥ 20 个场景（含巷战、开阔地、夜战、多 FOB、坦克、无人机），记录命令流 seed，CI 三平台校验和比对 |
| 性能回归 | `bench` 阈值（p99 超预算 10% 即失败） |
| 冒烟 | macOS runner 上启动 → 加载关卡 → 跑 30 秒 → 退出码 0 → 日志无 `ERROR` |
| 玩法验证 | 每周一次"可玩性评审"，用 §90 的量化指标打分 |

## 10.11 实现清单（DoD，架构层）

- [x] `sim_math` 定点库 + 查表三角 + 定点随机（**M0.1 已完成**：45 项单测，release + debug(溢出检查) 双构建通过；表 `tools/gen_trig.py` 烘焙入库）
- [ ] `sim_core` 世界/柱/chunk + 破坏与挖掘管线（含脏队列与摊还重建）
- [ ] `sim_cli` bench 跑通 400 单位 / 10 万 tick，p99 ≤ 预算
- [ ] Rust → Godot GDExtension 薄绑定跑通（node 每帧驱动 sim tick，渲染读状态）
- [ ] macOS arm64 导出 + 签名 + 启动自检在 CI 通过（ad-hoc 通道）
- [ ] CI grep 强制边界：`sim/` 无 godot 依赖、`godot/scripts/` 无规则逻辑
- [ ] 三平台（Linux/macOS 各一种）黄金回放校验和一致

---

**下一步**：[20-cover-perception.md](20-cover-perception.md)（掩体与感知——本项目的技术心脏）
