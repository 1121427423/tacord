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
- Utility AI 五行为：`seek_cover` / `advance` / `flank` / `hold` / `rescue`
- **真实几何掩体评估**（无预设掩体点，侧翼被绕后掩体自动失效）
- 交火：视线、散布、伤害
- 压制：近失子弹产生压制值，压制会改变效用打分与机动能力
- 倒地 / 拖救 / 就地包扎（医疗兵效率 x2）/ 多次倒地才阵亡

**MVP 外（M4+，按顺序推进）**
- 感知与记忆（听枪声、记住子弹来向、无线电共享敌情）
- 医疗帐篷等固定救治设施、呼救语音气泡
- 弹药与后勤（打光弹药、从尸体摸弹匣、补给线）
- 建造与 FOB（士兵亲手施工、FOB 归属即胜负）
- 俘虏与审讯、翻越/滑铲/扑倒/肉搏、坦克与无人机、对话气泡本地化

---

## 3. 当前进度（M0 + M1 已完成）

```
tacord/
├── project.godot                    # 4.7.x / Compatibility / 1280x720 / autoload Game
├── icon.svg                         # 占位图标
├── .gitignore
├── scenes/
│   ├── main.tscn                    # Main(Node2D) + Camera2D + BattleMap 实例 + HUD
│   ├── battle/battle_map.tscn       # Node2D + battle_map.gd
│   └── units/soldier.tscn           # CharacterBody2D + ColorRect + CollisionShape2D + SoldierAI
├── tests/smoke_test.tscn            # 引擎原生 headless 测试（76 项断言，退出码判定）
├── .github/workflows/               # ci.yml（lint + 冒烟测试）、web.yml（导出 + Pages）
├── export_presets.cfg               # Web 导出预设（单线程），CI 复现用
├── scripts/
│   ├── core/game.gd                 # autoload：引导、命令下发、全局查询
│   ├── core/battle_map.gd           # 网格/地形/AStar2D/视线/掩体评估/占位渲染
│   ├── core/main.gd                 # 主场景装配、演示地形与双方占位单位、HUD
│   ├── ai/utility.gd                # 通用 Utility AI（Consideration + 响应曲线）
│   ├── ai/blackboard.gd             # 小队黑板：同队共享的目击与枪声记忆
│   ├── ai/behavior_tree.gd          # 极简 BT：Action / Condition / Sequence / Selector
│   ├── ai/soldier_ai.gd             # 3+1 个考虑因素 + 每个行为一棵树
│   ├── units/soldier.gd             # 移动 / HP / 命令 / 压制 / 占位绘制 / 曳光
│   └── units/weapon.gd              # hitscan 武器：散布、冷却、命中判定、近失压制
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
> M1 让子弹飞起来，M2 让「被打」产生行为后果，M3 让「打死」变成可挽回的状态，
> M4 让士兵只知道自己该知道的（去掉透视）；下一步是让火力有尽头——M5 弹药与后勤。

### M1 · 交火与视线 ✅ 已完成
- `scripts/units/weapon.gd`：射程、射速、散布、射线命中（第 1 层单位 + 第 2 层障碍）
- 士兵在"有 LOS + 在射程内"时自动开火，无需玩家微操
- 验收：✅ CI 断言通过，其中「无遮挡面对面时命中掉血」直接覆盖这一条（M1 落地时全套 32 项）。

### M2 · 压制与暴露 ✅ 已完成
- 近失子弹（射线未命中但距离很近）→ 目标 `suppression` 上升，随时间衰减
- `suppression` 接入 `seek_cover` 的原始输入，并降低 `move_speed`
- 开火事件广播（为 M4 的"听枪声"复用）——`shot_fired(from, to, hit_target)` 已在 M1 就位
- 验收：✅ 被压制的士兵会主动缩到掩体后，火力停止后恢复推进。

实现要点（都是可调参数，不是硬编码）：

| 参数 | 位置 | 值 | 作用 |
| --- | --- | --- | --- |
| `near_miss_radius` | `weapon.gd` | 40 px | 弹道多大范围内算擦身而过 |
| `suppression_per_near_miss` | `weapon.gd` | 0.3 | 贴脸近失的压制量，按点到弹道的距离线性衰减 |
| `SUPPRESSION_DECAY` | `soldier.gd` | 0.22 / s | 压制衰减速率（满压制约 4.5 s 恢复） |
| `SUPPRESSION_SPEED_PENALTY` | `soldier.gd` | 0.6 | 满压制时只剩 40% 移动速度 |
| `PINNED_FIRE_THRESHOLD` | `soldier_ai.gd` | 0.75 | 超过就停火 |

近失判定用「点到弹道线段的最短距离」而不是射线是否命中，所以**真正中弹的人也会拿到接近满额的
压制**——中弹当然更压人。压制的三处后果：`seek_cover` 加 `pinned * 0.65`、`advance` 乘
`(1 - suppression)`、`flank` 乘 `(1 - suppression * 0.8)`（被压着还想去包抄的人死得最快）。

验收（CI 里 42/42，其中 10 条覆盖 M2）：满压制时速度实测 `80 → 32`；30 帧后压制从 1.00 衰减到
**0.89**（= 1 - 0.22 × 0.5，与公式一致）；弹道旁 20 px 的旁观者拿到 **0.150**
（= 0.3 × (1 - 20/40)，与公式一致）；200 px 外的人压制为 0；满压制时 `advance = 0` 且
`seek_cover > advance`，把压制清零后 `advance` 恢复到 1.0。

### M3 · 倒地 / 救援 / 救治 ✅ 已完成
- `hp <= 0` → `downed`（不是 `dead`）：失血计时、爬行、呼救
- 队友救援 BT 子树：压制火力 → 接近 → 拖回掩体 → 包扎（医疗兵速度 x2）
- 每次倒地叠加"虚弱"，多次倒地才真正阵亡
- 验收：✅ 打倒一个士兵后，能看到队友在掩护下把他拖回并救活。

状态机（`soldier.gd`）：

```
hp > 0 ──take_damage──> hp <= 0 ──go_down()──> downed ──apply_rescue 满 3s──> 站起来（虚弱 +1）
                                                 │
                                                 ├─ bleed_timer 归零 ──> die()（失血致死）
                                                 └─ down_count > 3   ──> die()（伤重不治）
```

| 参数 | 值 | 作用 |
| --- | --- | --- |
| `BLEED_OUT_TIME` | 20 s | 无人救治的失血致死时间（`bleed_out_time` 是导出项，可调） |
| `BLEED_PER_DAMAGE` | 0.12 s/点 | 倒地后再中弹，每点伤害提前这么多秒死亡 |
| `RESCUE_TIME` | 3 s | 标准包扎耗时；医疗兵按 `RESCUE_SPEED_MEDIC = 2.0` 倍速 |
| `REVIVE_HP` | 30 | 被救活时的血量 |
| `WEAKNESS_PER_DOWN` | 15 | 每次被救活永久损失的最大血量 |
| `MAX_DOWNS` | 3 | 倒满这么多次后，再倒一次即阵亡 |
| `CRAWL_SPEED_FACTOR` | 0.35 | 被拖动时的爬行速度系数 |
| `RESCUE_SCAN_RADIUS` | 900 px | 愿意为救人跑多远 |
| `MEDIC_SCORE_BONUS` | 1.6 | 医疗兵的救援意愿加成 |
| `DOWNED_ALLY_ORDER_PENALTY` | 0.5 | 有战友倒地时，推进/包抄欲望打对折 |

两个设计决定值得记下来：
1. **掩护火力不做成 BT 子树。** `_combat_step()` 每帧都会对可见敌人还击，与当前行为无关，
   所以医疗兵天然是"一边压着对面一边救人"，不需要额外的火力组节点。
2. **必须有 `DOWNED_ALLY_ORDER_PENALTY`。** 否则 `attack` 命令下 `_consider_advance` 恒为 1.0，
   永远压过救援分数——医疗兵根本不会动，M3 的验收标准就成了空话。

验收（CI 里 65/65，其中 23 条覆盖 M3）：失血计时到点真的 `die()`；倒地后 `try_fire` 返回 false、
`apply_suppression` 无效、`effective_speed` = 80 × 0.35 = 28；`apply_rescue(1.0)` 后
`rescue_ratio` = 1/3，医疗兵 2 倍速一次补满即救活；救活后 `hp = 30`、`max_hp = 85`；
连续倒地到第 4 次才 `is_dead`；没人倒地时 `_consider_rescue() == 0`，
有战友倒地时 `_consider_advance()` 从 1.00 掉到 **0.50** 且医疗兵救援分数反超。

最后一条是端到端的：把 `hurt` 打倒后完全不做干预，只等物理帧——队友自己跑过去、拖、包扎，
**135 帧（2.25 秒模拟时间）** 后 `is_downed` 变回 false，且没有死。这条才是 M3 验收标准本身，
前面 22 条只是把它的每个零件钉住。

### M4 · 感知与记忆 ✅ 已完成
- 听觉事件、"最后已知位置"记忆、小队黑板共享敌情
- 验收：✅ 士兵会转向看不见的枪声，并向最后已知位置搜索而不是原地发呆。

M4 真正改掉的是一处**作弊**：`_pick_advance_target` 原来调 `_nearest_enemy(1e9)`，
不看通视直接拿敌人真实坐标——等于每个士兵都开着全图透视。现在推进是三级优先：

```
看得见的敌人（有通视） ──> 压到 2 格开火距离
        │ 看不见
        ▼
黑板上有记忆 ──────────> 去查最后已知位置（目击优先于枪声）
        │ 什么都不知道
        ▼
就近 6 格随机搜索 ─────> 绝不原地发呆
```

| 参数 | 位置 | 值 | 作用 |
| --- | --- | --- | --- |
| `GUNSHOT_HEAR_RADIUS` | `soldier_ai.gd` | 520 px | 枪声传播半径（声音不看视线） |
| `AWARENESS_RADIUS` | `soldier_ai.gd` | 720 px | 视觉搜索上限（能否看见仍由通视决定） |
| `PATROL_RADIUS_CELLS` | `soldier_ai.gd` | 6 格 | 毫无情报时的搜索半径 |
| `MEMORY_TTL` | `blackboard.gd` | 12 s | 记忆保鲜期，过期即遗忘 |
| `MAX_GUNSHOTS` | `blackboard.gd` | 8 | 一块黑板最多记住几声枪响 |

三个设计决定：
1. **枪声记在敌人的黑板上。** `Game.hear_gunshot()` 把每声枪响分发给所有**敌队**的黑板——
   自己队不用记（他们知道自己在开枪），枪声的全部价值就在于让看不见的人暴露位置。
   （第一版写成记在自己队黑板上，被 `nearest_enemy_gunshot` 的友军过滤一夹就永远听不见，
   是写测试时推演出来的。）
2. **转头只对"新的一声"响应。** 枪声带自增 id，`_heard_shot_id` 去重；
   否则士兵会僵在同一朝向上，别的判断全被冻住。
3. **黑板的时钟由 Game 统一推进。** 放在士兵身上会让一队 6 个人的记忆走快 6 倍。

HUD 新增一行「情报: 蓝方 sighting 3.2s 前 @(848,208)　红方 无」，
让"看不见敌人、靠记忆去搜"这件事在画面上直接可见。

验收（CI 里 76/76，其中 11 条覆盖 M4）：黑板本体 7 条（目击记忆 / 超期遗忘 /
听得见敌队枪声 / 自己队枪声不算威胁 / 超半径听不见 / 目击优先于枪声）；
端到端 3 条——看不见敌人时朝向实测 `facing=(0.00,-1.00)`（正北，即枪声方向）、
敌队真的开火后 320 px 外的听者转向声源（这条专门验证分发路由）、
毫无情报时 1 秒内走了 **73 px** 而不是发呆。

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

- `gdparse`（gdtoolkit 4.5.0，Godot 4 GDScript 语法）：**8 个脚本 + `tests/smoke_test.gd` 全部通过**
- `gdlint`：**no problems found**
- 引擎 API 交叉核对：把脚本里 **112 处**引擎/项目符号逐个比对 Godot 源码自带的
  `doc/classes/*.xml`（方法名、参数、常量、继承链），**4.7.2-stable 与 4.2-stable 两个版本
  各跑一遍，均 0 问题**——这使"脚本兼容 4.2+"成为已验证结论而非假设。
  这一步实际抓到一个真 bug：`battle_map.gd` 调用了未定义的 `_init_terrain()`，已补上。
- 跨文件鸭子调用核对（M0/M1 期间那次审计）：**126 处**（`map.xxx()` / `soldier.call("xxx")` /
  `unit.get("xxx")` 等）：**0 问题**
- `project.godot` 的每个设置项都在引擎源码里确认存在（`project_settings.cpp`、`main.cpp`、
  `physics_server_2d.cpp`、`world_2d.cpp` 等）
- `.tscn` 结构检查：资源路径全部存在、`load_steps` 计数正确、无 `uid=` 引用、节点类型与属性名
  均见于引擎类文档；`uid` 可省略由 `resource_format_text.cpp` 的 `next_tag.fields.has("uid")` 确认

**已在真实引擎中验证**：GitHub Actions（`.github/workflows/ci.yml`）用 Godot 4.7.2 headless
执行 `tests/smoke_test.tscn`，**76/76 断言通过**（M2 的 10 条、M3 的 23 条、M4 的 11 条都在最新一次 CI 里逐条 PASS）；
`.github/workflows/web.yml` 的 Web 导出也已成功产出 10.3 MB 的 `github-pages` artifact。

这套测试工作累计抓到 5 个真 bug（均已修）。前两个是 CI 跑出来的：
1. `cover` 地形此前算作「可走」，而 `add_obstacle()` 会生成实体碰撞体 → A\* 规划出穿墙路径，
   士兵被 `move_and_slide` 卡在墙上，`has_arrived()` 永远为假、行为树一直 RUNNING。
2. `find_path` 曾把 `AStar2D.get_point_path` 的 `allow_partial_path` 传 `true` → 目标不可达时
   返回「走到墙边为止」的半截路径，调用方无法区分到达终点与卡在半路。

后三个是写断言时推演出来的（推演比跑起来更早发现问题）：

3. `die()` 没有清 `is_downed` / `bleed_timer` → 死人和「可救援的倒地者」分不开，
   救援判定和 HUD 都会把尸体当成能救的伤员。
4. 枪声只记在**开枪者自己队**的黑板上，而 `nearest_enemy_gunshot` 又会过滤掉本队枪声
   → 两边一夹，听声转头永远不会触发，M4 第一条验收标准直接落空。改成由 Game 分发给敌队。
5. `clear_boards()` 原来 `_boards.clear()` 丢掉整个字典，而活着的士兵手里握着旧黑板引用
   → 重开一局后 `hear_gunshot` 会写进一块没人读的新黑板。改成逐块清内容。

**仍未验证**：① 浏览器里的实际画面（需开启 GitHub Pages，或下载 artifact 本地预览）；
② macOS 签名/公证（需真机）。
