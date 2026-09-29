# TACORD 开发计划（MVP → 完整版）

> 本文档回答两件事：**技术栈要不要调整**，以及**按什么顺序把系统做出来**。
> 目标形态参考 Defilade 式体验（真实几何掩体、压制、倒地救援、俘虏审讯、FOB 建设），
> 但严格按最小 MVP 推进：先让"士兵自己想活下去"这件事跑通，再往上叠。

---

## 1. 技术栈结论

### 1.1 需要调整的地方

| 项 | 原方案 | 调整后 | 原因 |
| --- | --- | --- | --- |
| 引擎版本 | Godot 4.2+ | **锁定 Godot 4.7.x stable（当前稳定版 4.7.2）**，脚本保持 4.2+ 语法兼容 | 4.2 的 Web 导出必须依赖 `SharedArrayBuffer` + `COOP/COEP` 跨域隔离头，且在 macOS/iOS 上多线程导出有已知兼容问题；**自 4.3 起支持单线程 Web 导出**，不需要特殊响应头，macOS/iOS 上也更稳。 |
| 渲染方式 | 未指定 | **Compatibility（`gl_compatibility`）** | Web 平台只能 WebGL 2.0，即只能用 Compatibility；同一份配置在 macOS 26 上也避开 MoltenVK/Forward+ 的额外变量。2D 项目用 Compatibility 无功能损失。 |
| 语言 | GDScript | **不变（GDScript）** | C# 版 Godot 4 **无法导出 Web**，这一条独立地否决了 C#。 |
| 寻路 | Godot 内置 AStar2D | **不变，MVP 用 `AStar2D`** | 需求指定。注意一个容易踩的坑：引擎源码里 `AStarGrid2D` 的继承是 `RefCounted`，**它不是 `AStar2D` 的子类**，不能当"更省事的 AStar2D"直接替换。若后续要换，属于换类而不是换实现。 |
| AI | Utility AI + BT 混合 | **不变，已落地最小实现** | Utility 决定"做什么"，BT 决定"怎么做"，职责分开后压制/救援这类长序列行为才能被打断。 |
| 掩体 | 未指定 | **无预设掩体点，纯几何评估** | 掩体分数由"真实碰撞体的射线遮蔽率 + 相邻不可走格 + 地形"实时算出。侧翼被绕后 → 射线不再被挡 → 分数立刻下降。 |

### 1.2 保持不变的约束

- 2D 模式、`CharacterBody2D` 单位、`ColorRect` 占位美术、零第三方插件/资源。
- `.tscn` 不写 `.uid` 引用（引擎首次导入时自动生成）。
- 物理层约定：**1 = 单位，2 = 静态障碍**（视线射线只打第 2 层）。

### 1.3 平台目标

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| 桌面（macOS 26 / Win / Linux） | 主开发目标 | 编辑器内 F5 直接跑。引擎给 macOS 导出包写的 `Info.plist` 里 `LSMinimumSystemVersion` = **10.12**（见 `platform/macos/export/export_plugin.cpp`），官方模板是 **Universal 2**（arm64+x86_64），macOS 26 远高于最低要求。分发需要签名 + 公证（**本沙箱内无法验证，需在真机上做一次导出冒烟**）。 |
| Web（HTML5） | 一等目标 | 用 **单线程导出**。4.7.2 源码 `platform/web/export/export_plugin.cpp` 里 `variant/thread_support` **默认值就是 false**，所以默认配置即无需 COOP/COEP 头，普通静态托管 / itch.io 可直接跑。注意：`file://` 打不开，必须走 HTTP。 |
| 联机 | 暂缓（M6 之后） | Web 端需要 `WebSocketMultiplayerPeer`，与桌面 ENet 不是同一套传输层，早期不要为它做设计妥协。 |

---

## 2. MVP 范围界定

对照参考简介，把功能分成"现在做 / 以后做"：

**MVP 内（M0–M3）**
- 网格地图 + 地形（open / cover / high / blocked）+ AStar2D 寻路
- 指挥官宏观命令：进攻 / 防守 / 包抄 / 待命
- Utility AI 四行为：`seek_cover` / `advance` / `flank` / `hold`
- **真实几何掩体评估**（无预设掩体点，侧翼被绕后掩体自动失效）
- 交火：视线、散布、伤害、阵亡
- 压制：近失子弹产生压制值，压制会改变效用打分与机动能力

**MVP 外（M4+，按顺序推进）**
- 感知与记忆（听枪声、记住子弹来向、无线电共享敌情）
- 倒地 / 呼救 / 拖救 / 就地救治 / 医疗帐篷
- 弹药与后勤（打光弹药、从尸体摸弹匣、补给线）
- 建造与 FOB（士兵亲手施工、FOB 归属即胜负）
- 俘虏与审讯、翻越/滑铲/扑倒/肉搏、坦克与无人机、对话气泡本地化

---

## 3. 当前进度（M0 已完成）

```
tacord/
├── project.godot                    # 4.7.x / Compatibility / 1280x720 / autoload Game
├── icon.svg                         # 占位图标
├── .gitignore
├── scenes/
│   ├── main.tscn                    # Main(Node2D) + Camera2D + BattleMap 实例 + HUD
│   ├── battle/battle_map.tscn       # Node2D + battle_map.gd
│   └── units/soldier.tscn           # CharacterBody2D + ColorRect + CollisionShape2D + SoldierAI
├── scripts/
│   ├── core/game.gd                 # autoload：引导、命令下发、全局查询
│   ├── core/battle_map.gd           # 网格/地形/AStar2D/视线/掩体评估/占位渲染
│   ├── core/main.gd                 # 主场景装配、演示地形与双方占位单位、HUD
│   ├── ai/utility.gd                # 通用 Utility AI（Consideration + 响应曲线）
│   ├── ai/behavior_tree.gd          # 极简 BT：Action / Condition / Sequence / Selector
│   ├── ai/soldier_ai.gd             # 3+1 个考虑因素 + 每个行为一棵树
│   └── units/soldier.gd             # 移动 / HP / 命令 / 占位绘制
├── assets/.gitkeep
└── PLAN.md
```

**运行方式**：Godot 4.7.x 打开工程 → F5。
- `1 / 2 / 3 / 4` = 进攻 / 防守 / 包抄 / 待命（作用于蓝方）
- `F1` = 掩体热区可视化（绿=掩体好，红=暴露）
- `R` = 重开一局

**开局行为**：蓝方初始命令 `defend`，红方 `attack`；双方会自主向中线推进，进入感知半径后
效用分数开始分化——被通视的一方转 `seek_cover`，看到对方侧面暴露的一方转 `flank`。

---

## 4. 下一步顺序（含验收标准）

> 原则：**先让掩体有后果，再让掩体有代价，最后才加复杂度。**
> 现在掩体评估已经能算分，但没人开枪，所以掩体毫无意义——M1 是优先级最高的一块。

### M1 · 交火与视线（先做这个）
- `scripts/units/weapon.gd`：射程、射速、散布、射线命中（第 1 层单位 + 第 2 层障碍）
- 士兵在"有 LOS + 在射程内"时自动开火，无需玩家微操
- 验收：红蓝双方在演示地图上自发交火，有人阵亡；HUD 显示存活数下降。

### M2 · 压制与暴露
- 近失子弹（射线未命中但距离很近）→ 目标 `suppression` 上升，随时间衰减
- `suppression` 接入 `seek_cover` 的原始输入，并降低 `move_speed`
- 开火事件广播（为 M4 的"听枪声"复用）
- 验收：被压制的士兵会主动缩到掩体后，火力停止后恢复推进。

### M3 · 倒地 / 救援 / 救治
- `hp <= 0` → `downed`（不是 `dead`）：失血计时、爬行、呼救
- 队友救援 BT 子树：压制火力 → 接近 → 拖回掩体 → 包扎（医疗兵速度 x2）
- 每次倒地叠加"虚弱"，多次倒地才真正阵亡
- 验收：打倒一个士兵后，能看到队友在掩护下把他拖回并救活。

### M4 · 感知与记忆
- 听觉事件、"最后已知位置"记忆、小队黑板共享敌情
- 验收：士兵会转向看不见的枪声，并向最后已知位置搜索而不是原地发呆。

### M5 · 弹药与后勤（轻量版）
- 弹匣 / 换弹 / 弹药耗尽导致火力衰减；路过尸体可补弹
- 验收：一场持续交火后能观察到"阵地渐渐沉寂"。

### M6 · 建造与 FOB
- 建筑落点 → 士兵走过去施工（战斗不中断）；FOB 提供部队上限与弹药补给
- 失去最后一座 FOB = 失败
- 验收：放下一座 FOB，能看到士兵跑过去把它建起来。

### M7 · 俘虏与审讯（可选）
- 被包围 + 被压制 + 无援 → 投降；押送、审讯、情报落到雷达上
- 验收：抓一个俘虏，敌方基地出现在地图上。

### 贯穿始终的两件事
- **平台冒烟**：M1 结束就跑一次 Web 导出 + 一次 macOS 导出，别把兼容问题留到最后。
- **性能预算**：AI tick 已按 `think_interval = 0.25s` 打散相位；射线查询按"每 tick 每单位
  有限次数"设计。单位数上到 50+ 时，掩体评估需要改成局部增量更新，而不是全图重算。

---

## 5. 主要风险与对策

| 风险 | 对策 |
| --- | --- |
| Web 单线程导出性能不足 | AI tick 分批、掩体评估缓存、避免每帧射线；渲染只用 Compatibility |
| 掩体评估射线开销随单位数平方增长 | 按小队共享威胁列表；结果缓存 1–2 个 tick；只对候选格采样 |
| Utility AI 行为抖动 | 已内置 `stickiness`（当前行为加分）；必要时再加最小驻留时间 |
| AStar2D 在 32x24 上够用，但动态障碍会频繁重建点图 | 重建只在 `set_terrain` 时发生；建造系统落地前评估是否换 `NavigationServer2D` |
| macOS 26 导出/公证未在本环境验证 | M1 结束时在真机做一次导出冒烟，尽早暴露签名问题 |

---

## 6. 本仓库的验证状态（诚实声明）

已在沙箱内执行的检查：

- `gdparse`（gdtoolkit 4.5.0，Godot 4 GDScript 语法）：**7 个脚本全部通过**
- `gdlint`：**no problems found**
- 引擎 API 交叉核对：把脚本里 **112 处**引擎/项目符号逐个比对 Godot 源码自带的
  `doc/classes/*.xml`（方法名、参数、常量、继承链），**4.7.2-stable 与 4.2-stable 两个版本
  各跑一遍，均 0 问题**——这使"脚本兼容 4.2+"成为已验证结论而非假设。
  这一步实际抓到一个真 bug：`battle_map.gd` 调用了未定义的 `_init_terrain()`，已补上。
- 跨文件鸭子调用核对：**126 处**（`map.xxx()` / `soldier.call("xxx")` / `unit.get("xxx")` 等）：**0 问题**
- `project.godot` 的每个设置项都在引擎源码里确认存在（`project_settings.cpp`、`main.cpp`、
  `physics_server_2d.cpp`、`world_2d.cpp` 等）
- `.tscn` 结构检查：资源路径全部存在、`load_steps` 计数正确、无 `uid=` 引用、节点类型与属性名
  均见于引擎类文档；`uid` 可省略由 `resource_format_text.cpp` 的 `next_tag.fields.has("uid")` 确认

**未验证**：本沙箱无法下载 Godot 可执行文件（GitHub release 资源 CDN 被网络策略拦截），
因此**没有真正跑起引擎**——"按 F5 看到网格和士兵"这一步属于未验证，需要在本地 Godot 4.7.x
里确认一次。脚本语法、引擎 API 签名、场景文件结构都已静态验证。
