# 20 · 掩体系统与感知系统

> 支柱 P1、P2、P3 的实现细节。这一份是整个项目技术含量最高、也最不能走捷径的部分。

## 20.1 掩体：从真实几何派生

### 20.1.1 设计原则

1. **零手工标记**：关卡里只有几何（墙、箱子、车、残骸、战壕、弹坑）。掩体槽在世界加载与几何变更时自动生成。
2. **遮挡 = 射线，不用"高度查表"**：判断一个位置能否藏住人，就是对该威胁方向做若干条真实射线（体素 DDA）。这样窗户、破洞、倾斜的残骸、被打掉一半的墙全都自动正确。
3. **缓存 + 事件失效**：射线很贵，所以缓存；但世界一变、威胁一移动、友军一占坑，缓存立即失效。
4. **能看见 = 能打中**：AI 的"我暴露了吗"和射击系统的"我能打中他吗"共用同一个函数 `exposure_samples(posture) -> [Point]` + `ray_blocked(a, b)`。绝不允许两套规则各说各话。

### 20.1.2 掩体槽的生成

对每根 **SOLID 柱**（实体段）的每个 **自由侧面**（相邻柱在该高度区间为空），在其外侧相邻空柱生成候选槽：

```
for each solid column c at (x,z) with solid segment [b, t]:
  for each of 4 neighbor dirs d in {N,E,S,W}:
     n = column at (x,z) + d*0.5m
     if n 在 [b, t'] 区间为空 且 地面可行走:
         slot = {
            pos:      n 的中心 (mm)
            normal:   -d                     // 面朝外，量化到 u16
            height:   t - ground_height      // 遮挡物高度 mm
            width:    沿墙面连续自由面的长度（左右扫描，上限 8m）
            type:     classify(height, width, material)   // LOW_WALL / HIGH_WALL / CORNER / WINDOW / WRECK / TRENCH / SANDBAG ...
            solidity: material.hp / material.max_hp       // 已被打得千疮百孔的墙，掩体价值下降
         }
```

**类型判定**（初值，可调）：

| 类型 | 条件 | 可用姿态 | 玩法含义 |
| --- | --- | --- | --- |
| `TRENCH` | 柱 flags 含 TRENCH（地面低于周围） | Prone / Crouch（站立完全暴露） | 战壕内可低姿快速机动 |
| `LOW_WALL` | 0.4m ≤ h < 1.1m | Prone / Crouch（蹲下完全藏住）；站立需 `PEEK_OVER` | 蹲下=安全，起身开火=暴露 |
| `HIGH_WALL` | h ≥ 1.1m 且 width ≥ 1.0m | Crouch / Peek（左右探身） | 从墙角侧身射击 |
| `CORNER` | 两个相邻自由面（转角） | Peek（左/右，可双向选择） | 最灵活，也最容易两边同时被压 |
| `WINDOW` | 段中间有空洞的立面（楼层结构） | `PEEK_OVER`（从窗台探头） | 室内战斗的核心，可从二楼压制 |
| `WRECK` | 车辆/残骸（材质为 metal/wreck） | 同 LOW_WALL，但 solidity 下降快 | 会被打穿，掩体会"越打越没用" |
| `PILLAR` | width < 1.0m 的窄柱 | Crouch（只藏半个身位） | 勉强可用，评分天然低 |

- 槽的**占用**：`occupant: EntityHandle?` + `reserved_until_tick`。一个槽按 width 可容纳 `floor(width / 0.8m)` 个单位，最少 1 个。
- 槽的**顶点/边标记**：`is_corner`（自由面在墙面两端）→ 允许 peek 方向选择（左/右）。

### 20.1.3 遮挡度 Blocking：真实射线

**身体采样点**（相对脚底高度，单位 mm；权重用于伤害与暴露）：

| 姿态 | 采样点（高 mm, 权重） | 眼高 |
| --- | --- | --- |
| Stand | 1700(0.30 头) / 1350(0.35 胸) / 1000(0.20 腹) / 550(0.15 腿) | 1650 |
| Crouch | 1150(0.35) / 850(0.40) / 550(0.25) | 1050 |
| Prone | 450(0.40) / 300(0.35) / 150(0.25) | 400 |
| Crawl（伤员） | 350(0.50) / 200(0.50) | 300 |
| Peek（左/右探身 0.45m） | 1300(0.4 头) / 1000(0.4 肩) / 700(0.2) —— 只在外侧半边 | 1250 |
| PeekOver（探头上沿） | 1500(0.5 头) / 1250(0.5 肩) | 1450 |

```
fn blocking(threat: Vec3, unit_pos, posture, world) -> f32 /* 0..1 */ {
    let pts = exposure_samples(posture, unit_pos, facing);
    let mut blocked_w = 0.0; let mut total_w = 0.0;
    for (p, w) in pts {
        total_w += w;
        if ray_blocked(threat + eye_offset_of_shooter, p, world) { blocked_w += w; }
    }
    blocked_w / total_w
}
```

- 为了兼顾性能：采样点数量按 LOD 裁剪（Full = 全部，Reduced = 头+胸两点，Dormant = 1 点）。
- `ray_blocked` 用 **体素 DDA（Amanatides–Woo）** 遍历柱，遇到 SOLID 段且射线高度落在该段区间 → 命中。**不穿**则继续；材质穿透在射击系统单独处理（视觉上看不见 vs 子弹能打穿是两件事：这里只看"能否被看见"）。

#### 20.1.3.1 汇总 blocking 的**唯一**用途（R3）

> 原设计用 `blocking < 1.0` 作为"能否开枪命中"的门槛（§30.3.2），这是错的：
> 只要有一个采样点露出，汇总 blocking 就 < 1.0，于是整条命中的判定就放行了——
> 哪怕子弹实际会打在被墙挡住的躯干上。这让"掩体"在最关键的判定上失效。

**裁定：汇总 `blocking` 只用于两件事，绝不用于命中判定：**

| 用途 | 函数 | 说明 |
| --- | --- | --- |
| AI 掩体评分 | `blocking_aggregate()` | 加权汇总值，衡量"总体藏得多好"，适合横向比较候选掩体 |
| 视觉探测速率 | `exposure_factor = 1 - blocking_aggregate` | 露得越多，被发现越快（一个连续量，天然适合做速率） |

**命中与"看得见"一律走逐点判定**（§30.3.2 已按此重写）：

```
visible_any(target)  = ∃ 采样点 p: !ray_blocked(shooter_eye, p)      // 看见：任一点
can_hit(point)       = !ray_blocked(muzzle, point)                   // 命中：具体那一点
```

这样"能看见 = 能打中"的承诺被精确化为：**"看得见的那个部位，才是能被击中的部位"**——
同一套采样点、同一个 `ray_blocked`，只是不再用汇总值做门槛。半身露头会被打头，藏在墙后的躯干打不到。

### 20.1.4 有效遮挡角与"被包抄"

槽的 `blocking` 只对**一定角度范围**内的威胁成立：

> **角度定义统一（R10）**：原文档 §20 用"覆盖角/2 + 25°"，§90 B2 验收却写"绕到 coverage + 25°"，
> 且没说明 coverage 是全角还是半角——测试与实现会用不同阈值。这里一次性定死 **半角** 语义。

```
// coverage_angle 是【全角】；判定时一律用它的半角
coverage_angle(slot)     = clamp(60° + 30° * (slot.width / 2.0m), 60°, 110°)   // 越宽的墙，能挡的范围越大
cover_half_angle(slot)   = coverage_angle(slot) / 2                            // 30°..55°
FLANK_MARGIN_DEG         = 25°                                                 // 常量，见 constants.ron
```

对威胁方向 `d`（单位 → 威胁的水平向量）与槽法线 `n` 的夹角 `α = angle(d, n)`（**半角，0..180°**）：

```
angular_factor(α, slot) -> Q16:
    if α <= cover_half_angle(slot):                       return 1.0
    if α >= cover_half_angle(slot) + FLANK_MARGIN_DEG:    return 0.0   // 已被包抄，对此威胁失效
    else:                                                 线性衰减（1 → 0）
```

**验收必须调用生产函数，不得重述阈值**（§90.3 B2 已改为）：

```
B2: 敌人移动到使 angular_factor(slot, threat) == 0 的位置后，
    单位在 1.5s 内放弃该掩体，成功率 ≥ 90%
```
测试代码直接 `use sim_core::cover::angular_factor` —— 阈值一改，测试自动跟随，不可能出现两套标准。

- **被包抄的即时反馈**：当某个已知威胁的 `angular_factor` 从 >0.5 掉到 0 时，触发 `COVER_FLANKED` 事件 → 该单位立即（不等摊还周期）重新评估掩体；班组层会尝试压制该方向或呼叫支援。
- 反向也成立：如果 **敌人在掩体的另一侧**（比如同一堵墙的另一面，距离 < 2m），掩体对该敌人无效（近距离绕墙判定：`α > 120°` 且距离 < 3m → factor = 0）。注意这里的 `120°` 同样以**半角**理解（来自槽法线），与上式一致。

### 20.1.5 掩体评分（Utility）

对单位 `u`、候选槽 `s`、当前已知威胁集合 `T`：

```
score(u, s, T) =
      W_BLOCK   * block_score(s, T, posture)      // 最重要
    + W_ANGLE   * angle_score(s, T)               // 是否面对主要威胁
    + W_ESCAPE  * escape_score(s)                 // 背后是否有退路/下一处掩体
    + W_REACH   * reach_score(u, s)               // 到达时间与路径危险度的反比
    + W_FIRE    * firesupport_score(s, T)         // 从这里能否有效开火（有射界、在射程内）
    - W_SUPPRESS* suppression_field(s)            // 这处掩体正在挨打吗
    - W_CROWD   * crowding_penalty(s)             // 已被占用 / 太挤（避免全队挤一个坑）
    + W_OBJECTIVE * objective_pull(s, u.order)    // 是否朝向任务目标
    + W_LEADER  * leader_proximity(s, u.squad)    // 不要离班长太远
    + noise(u.personality, s)                     // 个性扰动：胆量高的人更愿意选激进位置
```

**初值权重**（`ai_weights.ron`，需大量调优）：`W_BLOCK 1.00 / W_ANGLE 0.45 / W_ESCAPE 0.30 / W_REACH 0.35 / W_FIRE 0.40 / W_SUPPRESS 0.60 / W_CROWD 0.25 / W_OBJECTIVE 0.50 / W_LEADER 0.15`。

- `block_score`：对每个已知威胁按 (置信度 × 距离权重) 加权平均 `blocking × angular_factor`；没有已知威胁时退化为"选择 blocking 高且朝向任务方向/上次交火方向"的槽。
- `escape_score`：查**掩体图**（§20.1.6）里该槽的邻居数量与"是否连通到撤退方向"。
- `firesupport_score`：从槽位置对主要威胁做一次射界测试（能否在 `PEEK` 姿态下命中），以及是否在武器有效射程内（超出射程的"完美掩体"没有价值）。

**候选剪枝**（性能关键）：
1. 以单位为中心，取半径 `SEARCH_R = min(18m, 任务相关区域)` 内的槽（空间哈希）；
2. 用便宜的预筛（法线朝向 + 距离）去掉 70%；
3. 对剩余 **≤ 12 个**候选做完整 `blocking` 射线（Full LOD 下 ≤ 12 × 2 点 = 24 条射线/单位，5Hz → 400 单位 = 9600 射线/秒，完全可接受）；
4. 取 top-3 缓存，1.5 秒内复用（除非事件失效）。

### 20.1.6 掩体图（Cover Graph）

- 相邻槽连边：`dist(a,b) ≤ 8m` 且 路径可行走 且 中途 `threat_field` 代价 < 阈值。
- 用途：
  - **转移**：被压制/被包抄时选下一个槽（不是随便跑，而是沿着掩体链"跳"过去）；
  - **包抄**：班组层用掩体图 + A* 规划侧翼路线（路径上每个节点都要求对主要威胁 `blocking ≥ 0.5`）；
  - **撤退链**：`escape_score` 的数据来源。
- 维护：世界破坏 → 脏 chunk 内的槽删除/新增 → 局部重连边（只重算受影响节点的邻边）。

### 20.1.7 失效与重评估（事件表）

| 事件 | 影响范围 | 响应 |
| --- | --- | --- |
| 柱被破坏/高度变化 | 该 chunk 及邻 chunk 的槽 | 重建槽、重连图、唤醒半径 30m 内单位重评估 |
| 威胁首次出现 / 消失 | 视野内单位 | 立即重评估 |
| 威胁移动到 flank 角 | 绑定到该槽的单位 | `COVER_FLANKED` → 立即重评估 |
| 槽被占满 | 后续候选者 | 换槽（crowding penalty 自然处理） |
| 单位被压制升级 | 该单位 | 换到 blocking 更高的槽 or 就地缩头（Pinned 时后者） |
| 收到新命令/目标变更 | 该班组 | 重评估（含 objective_pull 变化） |
| 单位受伤 | 该单位 | 重评估（倾向更保守的槽） |

### 20.1.8 反脚本化验证（必须写进测试）

1. 程序化生成 1000 个随机场景（随机建筑、残骸、车辆、战壕），场景中**没有任何手工掩体标记**；
2. 放置 1 个士兵 + 1 个敌人在随机位置，敌人开火；
3. 断言：
   - 3 秒内，士兵所在位置的 `blocking ≥ 0.7`，成功率 ≥ 95%；
   - 敌人移动到使 `angular_factor(slot, threat) == 0` 的位置后，士兵在 1.5 秒内放弃该掩体，成功率 ≥ 90%；
   - 把那堵墙炸掉后，该位置在 0.5 秒内被判定为失效（blocking < 0.2）。
4. 这套测试是 CI 的一部分，也是"我们没有偷偷加掩体标记"的证据。

---

## 20.2 感知系统

### 20.2.1 视觉

- **视锥**：水平 ±110°（视野中心 60° 内识别速度 ×2），垂直 ±55°。静止观察时头部可缓慢转动（±35°，1.5 秒扫一次），移动时视锥跟随移动方向。
- **探测是累积的，不是瞬间的**：
  ```
  detection[target] += rate * dt
  rate = BASE
       * fov_factor(angle_to_target)          // 0.15（视野边缘）~ 1.0（正中）
       * dist_factor(d)                       // 1.0 @ <=40m，线性降到 0.15 @ 180m
       * exposure_factor(blocking)            // 关键：与掩体系统同一个 blocking 值，1-blocking
       * move_factor(target_speed)            // 静止 0.6 / 走 1.0 / 跑 1.6
       * light_factor(time_of_day, muzzle_flash, fire)  // 夜间 0.35，枪口焰/燃烧 1.8
       * stance_factor(shooter_posture)       // 卧倒观察 0.8（看得更久更稳）/ 移动中 0.7
       * attention_share                      // 见下
       * skill_factor(unit.skill)
  ```
- **`attention_share`（注意力预算）**：每个单位每感知周期只能"认真看" **≤ 3 个**目标（按威胁排序），其余目标 `rate × 0.25`。这会产生真实的侧翼盲区——不是 bug，是我们要的战术空间。
- **识别阈值**：`detection ≥ 1.0` → 确认接触（confidence 0.6 起，持续观察 1.5 秒升到 1.0）。`0.3 ≤ detection < 1.0` → 生成"SUSPECT"（疑似接触，会让单位转向观察、降低移动速度、向班组报告"好像有动静"），**不作开火依据**。
- **视距上限**：白天 180m、夜间 70m（有夜视仪 120m）、枪口焰/爆炸火光 300m（事件型，瞬时）。

### 20.2.2 听觉

声音事件（`SoundEvent { pos, kind, loudness, tick }`）：

| 来源 | 响度（参考值，衰减半径） |
| --- | --- |
| 消音武器 | 25 m |
| 手枪 | 120 m |
| 步枪/机枪 | 350 m |
| 爆炸 | 700 m |
| 手榴弹落地弹跳 | 40 m |
| 脚步（跑） | 30 m /（蹲行）8 m |
| 车辆引擎（怠速/行驶） | 250 / 500 m |
| FPV 无人机 | 60 m（特征频率，方向感差） |
| 喊话（"MEDIC!" / "CONTACT!"） | 90 m |
| 建筑倒塌 | 900 m |

```
perceived_loudness = loudness * exp(-dist / attenuation_k)
                   * occlusion_factor(world)   // 每穿过一道墙 ×0.55，穿两层以上基本只剩方向感
if perceived_loudness > hearing_threshold(unit):
    生成/更新 contact：来源 = HEARD，位置误差 = f(perceived_loudness, occlusion)，方向误差 ±(8°~45°)
```

- **行为**：听到未识别来源的枪声 → 单位**转向声源**（`TURN_TO`，0.4 秒），把方向加入"关注扇区"（提升该扇区的视觉 `fov_factor` 1.5×），并向班组广播。
- **定位不准**：听觉 contact 的位置误差是高斯分布（近距离 ±3m，远距离 ±25m），这会自然产生"朝错误的方向压制"——保留它。

### 20.2.3 记忆与无线电（Contact 系统）

```
Contact {
  id, team, unit_type_guess,
  pos_mm, vel,              // 最后一次观测
  confidence: 0..1,
  source: SEEN | HEARD | RADIO | INTEL | DEDUCED,
  first_seen_tick, last_seen_tick, last_confirm_tick,
  squad_shared: bool,
}
```

**衰减曲线**（无新观测时）：
| 年龄 | 状态 | 位置误差 | 用途 |
| --- | --- | --- | --- |
| 0–3 s | ACTIVE | ≤ 2 m | 可直接开火、精确压制 |
| 3–12 s | RECENT | ≤ 6 m | 可压制该区域、视锥偏向该方向 |
| 12–45 s | STALE | ≤ 25 m | 仅用于威胁场权重与警戒朝向 |
| > 45 s | FORGOTTEN | — | 删除（除非该区域有持续声音或己方单位在场） |

**无线电共享**（班组级，游戏规则的一部分）：
- 每个班组每 **2 秒**只能广播 **1 条** contact（优先级：新发现 > 确认度高 > 距离近 > 威胁大）。
- 广播有 **0.3–0.8 秒**延迟（模拟通话），并有"通话被打断"的可能（该单位正在被压制 → 延迟 ×2 或放弃）。
- 收到广播的单位把它作为 `source = RADIO` 的 contact 加入记忆（置信度 × 0.8）。
- **情报上限**：班组共享的 contact 表上限 12 条（超出则淘汰最旧/最不确定的）——这让"信息过载"成为真实的战场限制。

### 20.2.4 压制（Suppression）

`suppression: 0..1`，每 tick 衰减 `τ = 4.0 s`。

| 事件 | 增量 |
| --- | --- |
| 子弹在 **1.5 m** 内掠过（近失） | +0.30（距离越近越大，1.5m 处 0.30 → 0.3m 处 0.55） |
| 子弹命中附近（< 3m，打到身边的墙/队友） | +0.22 |
| 爆炸在 8m 内 | +0.60（按距离衰减） |
| 队友在 6m 内倒下 | +0.25 |
| 看到敌人枪口/曳光指向自己（方向夹角 < 20°，持续） | +0.15 / 秒 |
| 处于已知敌人射界内且无掩体（blocking < 0.2） | +0.08 / 秒 |

**等级与效果**：

| 等级 | 区间 | 效果 |
| --- | --- | --- |
| CALM | 0.00–0.30 | 正常 |
| HESITANT | 0.30–0.60 | 射击误差 ×1.6；主动换位概率 ×0.4；开火间隔 +40%；`PEEK` 时间缩短（缩短暴露） |
| **PINNED** | 0.60–1.00 | **不主动换位**（被钉住）；只做盲射/短点射（误差 ×3，射速 -60%）；视野收缩 40%（缩头）；不响应"前进"类命令（只响应撤退/固守）；呼救概率上升 |

- PINNED 是**玩法核心**：它让"压制"成为一个真实的战术动作（用机枪把一个班的头按下去，另一班去包抄）。玩家的 UI 必须能看见每个单位的压制条。
- 恢复：压制衰减 + 队友火力支援（己方火力压过对方时衰减 ×2）+ 班长在 15m 内（衰减 ×1.5）+ 老兵（衰减 ×1.3）。

### 20.2.5 威胁场（Threat Field）与杀伤区

低分辨率场：**8 m 栅格**，每格 4 个通道，每 tick 指数衰减（τ = 6 s）：

| 通道 | 来源 | 含义 |
| --- | --- | --- |
| `bullet_density` | 每颗经过的子弹在其路径格上 +1 | "这里正在挨打" |
| `enemy_influence` | 每个已知 contact 按 `confidence × (1 - d/120m)` 高斯扩散 | "敌人大概能控制这里" |
| `openness` | 静态预计算：该格到周围掩体的平均距离与 blocking | "这里天生开阔"（缓存，破坏时重算） |
| `casualty` | 己方伤亡发生地 | "这里刚死了人"（衰减慢，τ = 60s） |

```
threat(g) = 0.40*norm(bullet_density) + 0.35*enemy_influence
          + 0.15*openness + 0.10*casualty
```

**用途**：
1. **寻路代价叠加**：`path_cost = base_cost + W_THREAT * threat(g) * (1 + suppression_factor_of_unit)`。典型 `W_THREAT` 让"穿过一片正在被机枪扫射的空地"的代价是绕行 300m 的 3 倍。
2. **硬性否决**：当最短路径上有一段 `threat > KILLZONE_THRESHOLD (0.75)` 且长度 > 15m → **AI 不会走**（P3："除非你下令，否则他们不会大摇大摆穿过火力杀伤区"）。玩家强制命令时，单位会执行但带 `reluctant` 标记（走得慢、中途可能趴下、士气下降），并在 UI 上把该路径标红。
3. **伏击点选择**：敌方 AI 用同样的场找"我方必经且高威胁"的位置设伏（包括伏击补给卡车）。
4. **可视化调试**：F2 键在地形上以热力图渲染。

### 20.2.6 感知系统的性能与摊还

- 每单位 **10 Hz** 更新（每 3 tick 一次），按 `unit_id % 3` 分桶，天然摊平。
- 每次更新只做：可见集合查询（空间哈希 + 距离剔除 ≤ 200m）→ 对 top-3 目标做 LOS 射线（每目标 1–2 条）。
- 400 单位 × 10Hz × 3 射线 = 12,000 射线/秒（每个射线是体素 DDA，典型 20–60 步）→ 约 0.3–1.0 ms/tick 的预算，需要 `rayon` 并行分片（按 chunk 分片以避免锁）。
- `Dormant` 单位（> 250m 且无战斗）：0.5Hz，只做声音事件检测（无射线）。

## 20.3 实现清单（DoD，掩体与感知）

- [ ] 体素 DDA 射线 + `ray_blocked` / `ray_hit_first`（含层结构、窗户空洞、TRENCH 标记）
- [ ] 掩体槽生成（chunk 粒度）+ 分类 + 占用管理
- [ ] `blocking` / `angular_factor` 计算，与射击系统**共用** `exposure_samples`
- [ ] 掩体评分函数（权重外置到 `ai_weights.ron`）+ top-K 剪枝 + 缓存与事件失效
- [ ] 掩体图（建边、局部重连、A*/flow 查询）
- [ ] 视觉累积探测 + 注意力预算 + SUSPECT 状态
- [ ] 声音事件系统 + 遮挡衰减 + 转向声源行为
- [ ] Contact 记忆与衰减 + 班组无线电共享（含带宽限制与延迟）
- [ ] 压制累加/衰减/分级效果
- [ ] 威胁场 4 通道 + 寻路叠加 + 杀伤区否决
- [ ] §20.1.8 的 1000 场景随机化测试通过
- [ ] `sim_cli dump --what cover|threat` 可视化输出

---

**下一步**：[30-soldier-ai-combat.md](30-soldier-ai-combat.md)（AI 决策架构与战斗细节）
