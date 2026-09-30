# TACORD

指挥官只下达战术命令，AI 士兵根据地形、掩体和战局自主判断与作战。

2D 俯视角战术 RTS · Godot 4.7.x · GDScript · Utility AI + 行为树 · 无预设掩体点

---

## 一、依赖

### 必需（只有这一项）

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| **Godot Engine** | **4.7.2 stable**（或任意 4.7.x） | 用**标准版**，不要用 `.NET / Mono` 版 |

下载地址（官方，二选一）：

- 下载页：<https://godotengine.org/download/archive/4.7.2-stable/>
- GitHub Release：<https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable>

| 平台 | 文件 | 大小 |
| --- | --- | --- |
| macOS（Apple Silicon / Intel 通用） | `Godot_v4.7.2-stable_macos.universal.zip` | 170.6 MB |
| Windows 64 位 | `Godot_v4.7.2-stable_win64.exe.zip` | 86.0 MB |
| Linux x86_64 | `Godot_v4.7.2-stable_linux.x86_64.zip` | 77.9 MB |

> **为什么锁 4.7.x 而不是 4.2**：4.2 的 Web 导出必须依赖 `SharedArrayBuffer` + COOP/COEP 响应头，
> 且在 macOS/iOS 上多线程导出有已知兼容问题；自 4.3 起支持单线程 Web 导出。
> 本工程脚本只用 4.2+ 就有的 API，所以**用 4.3 ~ 4.7 任意版本打开都能跑**，推荐直接用 4.7.2。

### 明确不需要的东西

- ❌ 任何第三方插件 / AssetLib 资源 / GDExtension
- ❌ C#/.NET（C# 版 Godot 4 无法导出 Web，这是硬约束）
- ❌ 外部美术资源（当前全是 `ColorRect` + `_draw()` 占位，后续换 Kenney 素材）
- ❌ 额外的寻路/行为树库（`AStar2D` 与 BT 都在仓库内实现）

### 可选依赖

| 用途 | 依赖 | 安装 |
| --- | --- | --- |
| 静态检查 GDScript（不需要开编辑器） | Python 3.9+ 与 `gdtoolkit 4.5.0` | `pip install gdtoolkit==4.5.0` |
| 导出 Web / macOS / 其他平台 | Godot **Export Templates 4.7.2.stable**（约 **1.28 GB**） | 编辑器菜单 `Editor → Manage Export Templates → Download`，只在要导出时装 |
| macOS 签名与公证 | Xcode 或 Command Line Tools + Apple 开发者证书 | 只有正式分发才需要 |

---

## 二、搭建手册

### 步骤 1 · 安装 Godot

**macOS**

```bash
# 1) 解压 zip，把 Godot.app 拖进 /Applications
# 2) 若被 Gatekeeper 拦（"无法验证开发者"），执行：
xattr -dr com.apple.quarantine /Applications/Godot.app
```

**Windows**：解压 `..._win64.exe.zip`，双击 `Godot_v4.7.2-stable_win64.exe` 即可（免安装）。

**Linux**

```bash
unzip Godot_v4.7.2-stable_linux.x86_64.zip
chmod +x Godot_v4.7.2-stable_linux.x86_64
sudo mv Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot
```

### 步骤 2 · 打开工程

```bash
git clone https://github.com/1121427423/tacord.git
cd tacord
```

- 图形界面：启动 Godot → `Import` → 选中本目录的 **`project.godot`** → `Import & Edit`
- 命令行：

```bash
godot --path .            # 直接跑游戏
godot --path . --editor   # 打开编辑器
```

### 步骤 3 · 首次导入

第一次打开时 Godot 会生成 `.godot/` 目录和 `*.import` 文件。
**这两者都已在 `.gitignore` 里**，所以：

- 别人克隆仓库后第一次打开需要重新导入（几秒钟，正常现象）
- 不要手动提交 `.godot/`

### 步骤 4 · 运行（F5）

主场景是 `scenes/main.tscn`，会看到 32×24 的网格地图、中央带缺口的墙、几堆木箱，
左侧 3 个蓝色士兵、右侧 3 个红色士兵，以及每方一辆装甲车和一架沿航点绕场的侦察无人机。

| 按键 | 作用 |
| --- | --- |
| `1` / `2` / `3` / `4` | 对**蓝方**下达：进攻 / 防守 / 包抄 / 待命 |
| `5` / `6` | 在蓝方首个存活士兵所在格放下 **FOB** / **沙袋** |
| `F1` | 掩体热区可视化（绿 = 掩体好，红 = 暴露） |
| `R` | 重开一局 |

开局蓝方命令是 `defend`、红方是 `attack`，双方会自主向中线推进；进入感知半径后效用分数开始
分化——被通视的一方自己转 `seek_cover`，看到对方侧面暴露的一方转 `flank`。左上角 HUD 实时
显示每个士兵的 hp / 压制 / 命令 / 当前行为。

血量归零不会立刻死：士兵先**倒地**（红十字标记 + 失血条），20 秒内没人救就失血致死。
每队第 3 人是医疗兵（名字带「医」），他会一边朝可见敌人还击一边跑过去，把伤员往附近掩体拖，
包扎 3 秒（医疗兵 2 倍速）把人救活——救活后只有 30 血，且最大血量永久 -15，倒满 3 次就救不回来了。
倒地的士兵单列一行显示失血秒数 / 倒地次数 / 包扎进度。

装甲车（M10）200 血、装甲只吃 1/4 伤害、6 发主炮，`hold` 时钉在原地、`attack` 才开进；
侦察无人机（M11）是 30 血的脆皮——三发步枪弹就坠毁，但它不吃压制、不能被俘，
墙挡得住地面视线、挡不住俯瞰：260 px 内的敌人哪怕躲在墙后，也被直接写进本队黑板
（HUD 的「情报」行里那条 sighting 就是它喂的），被盯上时它绕着目击位置转六边形的圈。
HUD 的「装甲」「空中」「FPV」三行实时显示载具与机体的状态；它们不占编制、不影响判负，
但对方步兵的子弹照样打得下它们。

每名士兵开局揣一颗手榴弹：敌人躲进掩体枪打不着时才出手；落点 40 px 内"胆子够大"的
敌兵会把雷捡起来扔回投掷者（引信不重置、只翻一次），96 px 内引信快到的雷触发全员
就地扑倒；爆炸把 40 px 内的人掀飞 32 px 并踉跄 0.8 秒——眩晕中扣不动扳机。
双方各有一架 FPV 自杀无人机从角落起飞：锁定最近敌兵/坦克直线俯冲、16 px 拉信管，
两发步枪弹能打下来——**击落是哑弹**，这就是士兵努力瞄准它的理由。
弹药告急的阵地先"省着打"：总量跌到最后一匣，冷却 0.35 秒拉长到 0.875 秒——
长点射变成单发，直到有人补进新弹药。
每队一辆补给卡车停在防线一侧的地图边缘：FOB 落成即自主发车，沿 A\* 开到 96 px 内
给半径里每个己方士兵发一匣备弹，卸完折返、歇 6 秒再发下一班；半路被新工事截断
就趴窝在断点（车顶叹号框、HUD 标「断链」），工事被打掉最多 1 秒重新上路；
60 血薄铁皮，五发步枪弹打断整条补给线——FOB 站桩补弹照旧，两条补给线各管各的。

### 步骤 5 · 静态检查（可选，但建议提交前跑）

```bash
# 方式 A：gdtoolkit（不需要开 Godot）
python3 -m venv .venv && .venv/bin/pip install gdtoolkit==4.5.0
.venv/bin/gdparse scripts/**/*.gd   # 语法
.venv/bin/gdlint  scripts/**/*.gd   # 风格

# 方式 B：引擎自带（需要本地有 Godot）
godot --headless --path . --import                     # 导入全部资源后自动退出
godot --headless --path . --quit-after 2               # 冒烟测试：加载主场景跑 2 帧后退出
godot --headless --path . --check-only --script scripts/core/battle_map.gd
```

> 官方帮助原文：`--import` = "Starts the editor, waits for any resources to be imported,
> and then quits"；`--check-only` = "Only parse for errors and quit (use with --script)"；
> `--quit-after <int>` = "Quit after the given number of iterations"。

---

## 三、导出

### 导出 Web（HTML5）

1. `Editor → Manage Export Templates` 下载 4.7.2.stable 模板
2. `Project → Export → Add… → Web`
3. 关键设置（**保持默认即可**）：
   - `Variant → Thread Support` = **关闭**
     （4.7.2 引擎源码里 `variant/thread_support` 默认就是 `false`）
     → 单线程导出**不需要** COOP/COEP 响应头，itch.io / GitHub Pages / 任意静态托管都能直接跑
   - `Variant → Extensions Support` = 关闭（本工程没有 GDExtension）
4. 导出到 `web_build/index.html`
5. **必须用 HTTP 服务，`file://` 打不开**：

```bash
cd web_build && python3 -m http.server 8080
# 浏览器打开 http://localhost:8080
```

> 只有当你主动打开 `Thread Support` 时，服务器才必须返回这两个头：
> `Cross-Origin-Opener-Policy: same-origin` 和 `Cross-Origin-Embedder-Policy: require-corp`。

### 导出 macOS

1. 同样先装 Export Templates；官方 macOS 模板是 **Universal 2**（arm64 + x86_64 同一个包）
2. `Project → Export → Add… → macOS`
3. 引擎写入的 `Info.plist` 里 `LSMinimumSystemVersion` 为 **10.12**，
   因此 **macOS 26（Tahoe）远高于最低要求**，不存在系统版本不够的问题
4. 本工程渲染方式已固定为 **Compatibility**，不依赖 Metal/Forward+ 后端，在 Apple Silicon
   与 Intel 上行为一致
5. 正式分发需要 `codesign` + 公证（编辑器导出面板里有 CodeSign 相关选项，也可以用
   `codesign` / `notarytool` 命令行）。**这一步需要在真机上验证一次**，沙箱环境无法覆盖

---

## 四、目录结构

```
tacord/
├── project.godot                    # 4.7.x / Compatibility / 1280x720 / autoload Game
├── icon.svg
├── scenes/
│   ├── main.tscn                    # Main + Camera2D + BattleMap 实例 + HUD
│   ├── battle/battle_map.tscn       # Node2D + battle_map.gd
│   ├── units/soldier.tscn           # CharacterBody2D + ColorRect + CollisionShape2D + SoldierAI
│   ├── units/tank.tscn             # M10：装甲车 + Weapon(主炮) + TankAI
│   ├── units/drone.tscn            # M11：无人机 + DroneAI（无武器节点）
│   ├── units/grenade.tscn          # M12：手榴弹（Node2D，一次性投掷物）
│   ├── units/fpv_drone.tscn        # M13：FPV 自杀无人机 + FPVAI
│   └── units/truck.tscn            # M15：补给卡车（状态机内嵌，无 AI 节点）
├── scripts/
│   ├── core/game.gd                 # autoload：引导、命令下发、全局查询
│   ├── core/battle_map.gd           # 网格/地形/AStar2D/视线/掩体评估/占位渲染
│   ├── core/main.gd                 # 场景装配、演示地形与双方占位单位、HUD
│   ├── ai/utility.gd                # 通用 Utility AI（Consideration + 响应曲线）
│   ├── ai/blackboard.gd             # 小队黑板：目击/枪声记忆 + 审讯出的永久工事情报
│   ├── ai/perception.gd             # 感知：把原始读数算成打分要用的 [0,1] 量（纯查询）
│   ├── ai/behavior_tree.gd          # 极简 BT：Action / Condition / Sequence / Selector
│   ├── ai/soldier_ai.gd             # 8 个考虑因素 + 每个行为一棵树（987 行，顶着 1000 上限）
│   ├── ai/tactics.gd                # M8：近战 / 伏地 / 滑铲 3 个考虑因素与对应行为
│   ├── ai/tank_ai.gd                # M10：载具 Utility AI（交战 / 推进 / 待命）
│   ├── ai/drone_ai.gd               # M11：无人机 Utility AI（盯梢 / 巡逻）
│   ├── ai/fpv_ai.gd                 # M13：FPV 锁定→俯冲（引爆判定每帧）
│   ├── units/grenade.gd             # M12：手榴弹（投掷/引信/被扔回/爆炸）
│   ├── units/fpv_drone.gd           # M13：FPV 本体（撞针引爆/被击落是哑弹）
│   ├── units/truck.gd               # M15：补给卡车（往返班次/卸弹/断链趴窝）
│   ├── units/soldier.gd             # 移动 / HP / 命令 / 压制 / 倒地 / 俘虏 / 姿态与翻越
│   ├── units/weapon.gd              # hitscan 武器：散布、冷却、近失压制、弹匣换弹、枪托
│   ├── units/build_site.gd          # 工地：施工计时 / 建成转实体 / 被打掉拆地形
│   ├── units/tank.gd                # M10：装甲车本体（装甲减伤 / A* 机动 / 占位车体）
│   └── units/drone.gd               # M11：侦察无人机本体（直线飞行 / 俯瞰侦察 / 脆皮）
├── tests/
│   ├── smoke_test.tscn              # M0–M7：154 项断言
│   ├── mobility_test.tscn           # M8：40 项断言（独立场景）
│   ├── medic_test.tscn              # M9：26 项断言（独立场景）
│   ├── tank_test.tscn               # M10：40 项断言（独立场景）
│   ├── drone_test.tscn              # M11：37 项断言（独立场景）
│   ├── grenade_test.tscn            # M12：49 项断言（独立场景）
│   ├── fpv_test.tscn                # M13：49 项断言（独立场景）
│   ├── ammo_test.tscn               # M14：20 项断言（独立场景）
│   └── truck_test.tscn              # M15：31 项断言（独立场景）
├── assets/                          # 美术资源占位目录
└── PLAN.md                          # 技术栈决策 + M0~M15 里程碑
```

物理层约定：**1 = 单位，2 = 静态障碍**（视线射线只打第 2 层）。

---

## 五、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 打开工程提示要"升级"配置 | `config/features` 写的是 `4.2`，用更高版本打开属正常，确认即可 |
| 克隆后没有 `.godot/`，第一次打开卡一下 | 正常，是在重新导入 |
| 士兵不动 | 确认 HUD 上命令不是 `hold`；`hold` 时待命分数最高是预期行为 |
| Web 导出白屏 / 报 SharedArrayBuffer | 你打开了 `Thread Support`，改回关闭，或给服务器加 COOP/COEP 头 |
| macOS 提示无法打开 | `xattr -dr com.apple.quarantine <路径>` |
| 编辑器报"脚本编译错误" | 跑一次 `godot --headless --path . --import` 看完整报错 |

---

## 六、CI 与自动部署

仓库里有两个 GitHub Actions workflow，push 到 `main` 或 `arena/**` 分支即触发。

### `.github/workflows/ci.yml`

| Job | 内容 |
| --- | --- |
| `GDScript 静态检查` | pip 装 `gdtoolkit==4.5.0`，对 `scripts/` 与 `tests/` 跑 `gdparse` + `gdlint` |
| `Headless 冒烟测试` | 下载 Godot 4.7.2 Linux 版 → `--headless --import` → **依次**跑 `tests/smoke_test.tscn`、`tests/mobility_test.tscn`、`tests/medic_test.tscn`、`tests/tank_test.tscn`、`tests/drone_test.tscn`、`tests/grenade_test.tscn`、`tests/fpv_test.tscn`、`tests/ammo_test.tscn`、`tests/truck_test.tscn`，九个都必须退出码 0 |

冒烟测试是**引擎原生**的（不依赖 GUT/gdUnit 等第三方插件）。M8 起按里程碑拆成独立场景——
`smoke_test.gd` 已经 911 行、顶着 gdlint 的 1000 行上限，再往里塞后面的里程碑就没有落脚的地方。
每个场景各自把断言总数写死在 `EXPECTED_CHECKS` 里，`_finish()` 比对**实际跑到的**条数，
某个测试段中途崩掉时不会谎报全绿。

- `smoke_test.tscn`（**154 项**）：坐标换算、地形、AStar2D 封死/绕行、UtilityAI 择优/权重/粘性、
  掩体几何、交火掉血、压制数值、倒地与救援、感知与记忆、弹药与后勤、建造与 FOB、俘虏与审讯
- `mobility_test.tscn`（**40 项**）：翻越（跳矮墙 / 绕整墙两条互为反例）、三种姿态的命中轮廓
  与速度、伏地能开枪而滑铲不能、肉搏冷却与敌我判定、三个新打分的触发条件、端到端趴下与起身
- `medic_test.tscn`（**26 项**）：医疗帐篷的落点与建成、建成后挡视线且 A\* 绕行、
  治疗的四个过滤条件各自单列一条、治到 `max_hp` 封顶、施工中不治、
  不碰胜负与编制、呼救气泡的相位在倒地时增长而起立后停跳
- `tank_test.tscn`（**40 项**）：载具的组归属与边界（不进 `soldiers`、不吃压制）、
  装甲减伤三档与溢出击毁、步枪与主炮的双向交火及中弹压制、同图 A\* 机动
  （含"目标 7×7 全封死才规划失败"）、`hold→advance→engage` 三选一依次触发、
  载具不被 `game.soldiers()` / 最近友军 / 医疗帐篷认领
- `drone_test.tscn`（**37 项**）：无人机的身段与边界（vehicles 组、恒 false 双项、
  无 apply_suppression、命令广播）、三发步枪弹坠毁且残骸不掉血、直线穿墙
  （同时钉住"y 没有偏移"以防它其实是绕过去的）、巡航速度实测、
  盯梢/巡逻两选一（目击过期自动回巡逻）、墙后目击写进本队黑板
  （先钉前提"墙确实挡住地面视线"，再测俯瞰照样报）、`best_memory` 链路贯通、
  超半径 / 同队不报、红队一无所知、不被 `game.soldiers()` / 最近友军 / 帐篷认领，
  以及反制——步兵 64 px 处一枪打得下它（散布偏移 < 命中半径，确定性命中）
- `grenade_test.tscn`（**49 项**）：引信计时与总时长、伤害三档（贴脸/边缘/半径外）
  与 0.8 压制、坦克吃雷走装甲、被扔回（确定性场景）与两条克制反例
  （引信剩不足 0.6 s 不捡 / 压制拉满不捡）、掀飞位移与踉跄窗口（try_fire 拦截
  且弹药零消耗可证非冷却）、evade 扑倒触发、投掷决策三反例一正例、不搅局
- `fpv_test.tscn`（**49 项**）：身段与边界、两发坠毁、俯冲直线与速度实测
  （60 px 下界同时排除"其实飞的是侦察机那档 110 px/s"）、撞击引爆
  （目标+溅射同队邻兵）、击落不爆（死后补调无效）、士兵击落链路
  （nearby_enemies 收得到 + 64 px 确定性命中）、`fpv_threat` 距离归一、
  坦克合法目标（装甲系数自动生效）、侦察机行为零扰动回归
- `ammo_test.tscn`（**20 项**）：两档冷却实测帧数对比（21 帧 vs 53 帧，
  两带不重叠互为判别，防"两档都被拉长"或"降级没生效"两种假绿）、
  补弹自动恢复、打光（is_dry）≠ 告急的边界、换弹中读数不闪烁、
  降级不伤命中与弹药账、告急线精确踩线（总量 24 算、25 不算）
- `truck_test.tscn`（**31 项**）：载具身段与不搅局、五发步枪弹击毁断供、
  发车条件（无 FOB 纹丝不动 / 建成即发车且真的在动）、往返卸弹
  （**半径外的兵一枚不加**——防"卡车给全场发弹"的假实现）、第二班循环、
  断链趴窝（半路建实体工事截断 → is_stalled；工事被打掉 1s 重试节拍内恢复）、
  FOB 站桩补弹不受断供影响（两条补给线各管各的）

CI 里 annotation 上限约 10 条且只保留最先发出的，所以**成功的场景一行不发**，
失败的才把诊断摊开；各场景日志另传成 `test-logs` artifact 兜底。

本地跑同样的检查：

```bash
godot --headless --path . tests/smoke_test.tscn    # 退出码 0 = 全通过
godot --headless --path . tests/mobility_test.tscn # M8，同样退出码判定
godot --headless --path . tests/medic_test.tscn    # M9，同样退出码判定
godot --headless --path . tests/tank_test.tscn     # M10，同样退出码判定
godot --headless --path . tests/drone_test.tscn    # M11，同样退出码判定
```

### `.github/workflows/web.yml`

下载 Godot + 导出模板（约 1.3 GB）→ `--export-release "Web"` → 上传 artifact `github-pages`
→ 发布到 GitHub Pages。

**一次性设置（必须手动做一次）**：仓库 `Settings → Pages → Build and deployment → Source`
选择 **GitHub Actions**。没开启时导出仍会成功、artifact 照常上传，只是最后一步发布会报
`Failed to create deployment (status: 404)`。

**三个都真实踩过的坑**，第二个特别阴险：

| 症状 | 原因 | 修法 |
| --- | --- | --- |
| deploy 步骤报 `Failed to create deployment (status: 404)` | Pages 没开启 / Source 不是 GitHub Actions | `Settings → Pages → Source` 选 **GitHub Actions** |
| job 在 **Set up job 阶段 2 秒就失败**，`steps: []`、几乎没有日志，annotation 里是 `Branch "xxx" is not allowed to deploy to github-pages due to environment protection rules` | `Settings → Environments → github-pages` 的 **Deployment branches** 只允许 `main`（把 Source 切成 GitHub Actions 时 GitHub 默认只加 `main`），而本工程在 `arena/**` 分支上开发 | 同一页把 `arena/**` 加进允许列表，或直接改成 **No restriction** |

第二个坑为什么难查：它发生在 job 启动前，Actions 日志文件在 `*.blob.core.windows.net`
（很多网络环境访问不到），`gh run view --log` 又常常是空的。唯一的线索是
`gh api /repos/<owner>/<repo>/check-runs/<id>/annotations`。workflow 里的 `configure-pages` 带了
`enablement: true`，在 `pages: write` 权限下可以自己把它重新打开；
但 `deploy-pages` **故意不加 `continue-on-error`**——以前加了，于是"页面根本没部署出来"
被伪装成绿色 run，骗过了好几个里程碑。

开启后站点地址为 `https://<用户名>.github.io/tacord/`。
也可以下载 artifact 本地预览：

```bash
gh run download <run-id> -n github-pages -D web_preview
cd web_preview && python3 -m http.server 8080
```

### 自定义域名（可选，**当前未启用**）

> 本项目暂不买自定义域名，走默认的 `https://1121427423.github.io/tacord/`。
>
> 期间试填过 `tacord.games`，踩到一个反直觉的副作用：**只要 `Custom domain` 里有值，
> GitHub 就会把默认域名 301 重定向过去**。于是域名还没买、DNS 也不存在时，
> `1121427423.github.io/tacord/` 跟着一起打不开——站点变成"哪儿都够不着"。
> 已把 `Custom domain` 清空，恢复正常访问。
>
> 下面的配置步骤保留，将来要买域名照做即可。按 GitHub 官方文档，**用自定义 Actions workflow 部署时不需要 `CNAME` 文件**：
域名登记在 `Settings → Pages → Custom domain`，仓库里就算塞了 `CNAME` 也会被忽略且不需要。
因此要做的三步，且**顺序不能反**（官方明确要求先在 GitHub 登记域名，再去配 DNS，
否则别人可以占用你某个子域来架站）：

**① 先验证域名所有权**（防域名被抢注；在**个人** `Settings → Pages`，不是仓库设置）
→ `Add a domain` 填 `tacord.games`，按提示到注册商加一条 TXT：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| TXT | `_github-pages-challenge-1121427423.tacord.games` | GitHub 页面当场生成的 token |

生效后（最长 24 小时）回同一页点 **Verify**。这条 TXT 要**长期保留**。

**② 仓库里登记域名**：`Settings → Pages → Custom domain` 填 `tacord.games` → `Save`。

**③ 注册商处配 DNS**（apex 域名必须用 `A`，或 `ALIAS`/`ANAME`）：

| 类型 | 主机 | 值 |
| --- | --- | --- |
| A | `@` | `185.199.108.153` |
| A | `@` | `185.199.109.153` |
| A | `@` | `185.199.110.153` |
| A | `@` | `185.199.111.153` |
| CNAME | `www` | `1121427423.github.io` |

`www` 是官方推荐与 apex 一起配的，配好后两者会自动互相跳转。
DNS 传播最长 24 小时，之后 `Enforce HTTPS` 才可勾选（站点强制 HTTPS 又可能再等一会儿）。

> CI 读日志的坑：Actions 的日志文件存在 `*.blob.core.windows.net`，某些网络环境访问不到。
> 因此两个 workflow 都把关键输出用 `::error::` / `::warning::` 发成 **annotation**，
> 可以直接用 `gh api /repos/<owner>/<repo>/check-runs/<id>/annotations` 取回。
> 注意 annotation 有数量上限且保留**最先发出**的若干条，所以失败项要放在最前面发。

---

## 七、当前验证状态

**已在真实引擎里跑通**：GitHub Actions 上用 Godot 4.7.2 headless 依次执行九个测试场景，
**合计 446 项断言，446/446 全绿**——`smoke_test.tscn` 154 项（掩体几何评估、交火掉血、压制数值、
倒地与救援、感知与记忆、弹药与后勤、建造与 FOB、俘虏与审讯）+ `mobility_test.tscn` 40 项
（翻越、三种姿态、肉搏、三个新打分、端到端趴下与起身）+ `medic_test.tscn` 26 项
（医疗帐篷的治疗四条件、视线与绕行、不碰胜负与编制、呼救气泡的相位）
+ `tank_test.tscn` 40 项（装甲减伤、双向交火与压制、同图 A\* 机动、
Utility 三选一、载具不被步兵逻辑认领）+ `drone_test.tscn` 37 项
（侦察无人机的身段边界、穿墙、盯梢巡逻两选一、墙后目击进黑板、反制命中）
+ M12–M14 三场景 118 项（手雷 49 / FPV 49 / 弹药告急 20——首跑四轮修复出
三个产品真 bug）+ `truck_test.tscn` 31 项（M15 补给卡车——首跑一次通过，
其余八场景零扰动）。总数同样写死在 `EXPECTED_CHECKS` 里。
每个总数本身也是一条断言——
`EXPECTED_CHECKS` 写死在测试里，某个测试段中途崩掉时退出码仍是 0，沙箱又读不到 CI 日志，
所以必须让引擎自己判定数没数够。这套测试工作累计抓到 **16 个真 bug**（M12 首跑
四轮新增三个：`draw_polygon` 参数序写反被引擎拒载而 gdtoolkit 不查引擎签名、
躲雷缺 prone_hold 窗口导致零压制的人一帧内被 M8 起身自动化翻回站立、
THROW_WEIGHT 0.98 输给 flank 满分+粘性 1.15 而雷永远扔不出去——最后这条靠
CI 效用表快照一击定位）：
`cover` 地形曾可走导致 A\* 规划穿墙路径；`find_path` 曾因 `allow_partial_path=true`
在目标不可达时返回半截路径；`die()` 曾不清 `is_downed`（死人被当成可救援的伤员）；
枪声曾只记在开枪者自己队的黑板上（听声转头永远不触发）；`clear_boards()` 曾丢掉整个字典
（活着的士兵握着旧引用，重开后没人读新黑板）；感知拆分后测试还在调已被搬走的 `_ammo_pressure()`，中止了 9 条断言（正是 `EXPECTED_CHECKS` 抓到的）。另有两条押送死锁是写代码时推演出来的，动第一行测试之前就改掉了；第九条最隐蔽——`_process` 按墙钟时间攒思考账、攒够一次就清零，物理帧在慢机器上批量执行时超出的时间被丢掉，不只决策变慢，**FOB 补弹速率也会随机器负载下降**，表现为同一份代码在 CI 上「116 帧过 / 400 帧卡」五五开。M8 又添三条：翻越时腾空状态没有
同步碰撞掩码（人被顶在墙皮上，整条翻越链路是死的）、`try_melee()` 不校验阵营（枪托会打到自己人）、
CI 的 annotation 配额被通过的场景先刷满（真正失败的那段整个被挤掉）。
M9 又添一条：`Soldier.hp` 是整数而帐篷按 6 HP/s 治疗，折到每帧 0.1 被 `int()` 吞掉，
**一滴血都加不上**——`is_medical_point()` 照样返回 true、零报错，
只有"治疗前后血量相等"这一条断言看得出来（改法是在工地上攒 `_heal_bank` 攒够 1 点再发）。
M10 没有新增产品 bug，但暴露了四条**测试写法**的坑（开枪前没等物理帧、
取血量基线的时机、开火方与目标同队、`find_path` 会吸附目标格），见 PLAN.md §6 的 e–h。
完整清单见 PLAN.md §6。

压制（M2）的数值不是拍脑袋写的，是被断言钉住的：满压制时移动速度 `80 → 32`，
30 物理帧后压制 `1.00 → 0.89`（衰减率 0.22/s），弹道旁 20 px 处压制 `0.150`
（= 0.3 × (1 - 20/40)），200 px 外为 0。

倒地与救援（M3）同样被钉住：血量归零进入倒地而非阵亡，`bleed_timer` 从 20 s 开始倒数、
归零即 `die()`；倒地后开不了枪、不吃压制、爬行速度 `80 × 0.35 = 28`；包扎 3 s 救活
（医疗兵 2 倍速），救活后 `hp = 30`、`max_hp` 永久 `-15`；倒满 3 次后再倒才真死；
有战友倒地时推进欲望从 `1.00` 掉到 `0.50`，医疗兵的救援分数因此反超。
最后还有一条端到端断言：打倒士兵后完全不干预，队友自己跑过去拖救，实测 **135 帧（2.25 秒）** 救活。

感知与记忆（M4）去掉了 AI 的透视：士兵只知道**看见过的**（有通视才记）和**听见的**（520 px 内的敌队枪声，
墙挡子弹不挡枪声），记忆 12 秒过期。推进变成三级优先——看得见就压上去，看不见就去查最后已知位置，
什么都不知道就在附近 6 格内搜索，不会原地发呆。HUD 上有一行「情报」显示双方各自记着什么。
实测：看不见敌人时朝向精确转到枪声方向 `facing=(0.00,-1.00)`；毫无情报时 1 秒内走了 73 px。

弹药与后勤（M5）让火力有了尽头：弹匣 24 发、备弹 72 发、换弹 2.2 秒。打空的当场自动换弹，
备弹也空了这把枪就永久安静——唯一的补充途径是走到尸体 26 px 内摸走它的备弹。
没弹的人更想找掩体（换弹要在掩体后换），彻底打光时推进欲望只剩 40%。
HUD 上有「弹药: 蓝方 216 发（0/3 人打光）」这样的汇总行。
实测：两人各 3 发对射，3 秒后双双打光且各正好打了 3 发，再等 1.5 秒枪声数一动不动。

建造与 FOB（M6）把补给从尸体搬到了工事上：按 `5` 在蓝方士兵脚下放一座 FOB，附近的士兵会
自己跑过去施工（6 人·秒一座，边打边建）。施工中的工地不算障碍、也打不坏——那还只是一堆建材；
建成的那一刻才升到障碍层并改写地形（FOB → 不可走，沙袋 → 真掩体），A\* 立刻绕开它。
FOB 建成后部队上限从 6 提到 9，站在它 48 px 内的士兵以 8 发/秒回备弹；打掉一座队里唯一的 FOB
即判负。效用上工地没修完时，`attack` 命令下的推进欲望会被施工压下去（0.65 对 0.89）。
实测：放下工地后不做任何干预，士兵自己走完最后 96 px 并把它建完。

俘虏与审讯（M7）让「抓到活口」变成情报：被压制、看得见两个敌人、且 300 px 内没有还站着的战友时，
士兵会举手投降（三道门槛缺一不可，少一道就是挨两枪就投降）。敌方就近派人抢押送权，把俘虏
押回**自己**的 FOB——押到 64 px 内才问得出话，审完当场释放。审出来的敌方**已建成**工事坐标写进
本队黑板，这类情报**不过期**（基地不会自己长腿跑掉），地图上从此画着那个十字准星：己方审出来的亮黄、
对面审出来的暗红。押送是有风险的：押送者阵亡或倒地，俘虏当场跑掉。
实测：完全不干预，俘虏自己投降、押送者 122 帧内完成认领与押送、审出第 2 条情报并放人。

静态验证：20 个脚本加 `tests/` 下九个测试脚本通过 `gdparse` 与 `gdlint`；M0/M1 期间做过一次引擎
API 逐个比对（脚本里的引擎/项目符号对 Godot **4.7.2** 与 **4.2** 源码自带的类文档，均 0 问题），
M2 新增代码用到的 `is_equal_approx` / `is_zero_approx` 也在 `@GlobalScope.xml` 里确认过；
`project.godot` 的每个设置项与 `.tscn` 的每个属性名都在引擎源码中确认存在。

**Web 已部署并可公开访问**：`Web 导出与部署` 全绿（`部署到 GitHub Pages: success`，
13 个步骤无一失败，且该步骤已去掉 `continue-on-error`，是真绿），
deployment `6737748200` 的状态为 `success`。HTTP 层实测：

| 检查 | 结果 |
| --- | --- |
| `https://1121427423.github.io/tacord/` | 200，`<title>TACORD</title>`，canvas 兜底文案可见 |
| `…/tacord/index.js` | 200，引擎代码为 `godot.web.template_release.wasm32.nothreads`（单线程版，符合设计） |
| `https://1121427423.github.io/index.js`（根路径） | 404 —— 说明资源走**相对路径**，将来换 apex 自定义域名（根路径）同样能加载 |

`index.js` 内部用 `scriptDirectory = new URL(".", _scriptName).href` 解析资源，
正是这套相对路径机制保证了 `/tacord/` 子路径与根路径两种部署都成立。

**仍未验证**：① 浏览器里的实际画面（canvas 真正跑起来、WASM 与 `.pck` 加载成功），
HTTP 层已通但需要人眼确认；
② macOS 签名/公证（需真机）。

技术选型理由、MVP 范围与全部里程碑（M1 交火 → M2 压制 → M3 倒地救援 → M4 感知记忆 →
M5 弹药后勤 → M6 建造与 FOB → M7 俘虏审讯 → M8 机动与近战 → M9 医疗帐篷与呼救气泡
→ M10 装甲车 → M11 侦察无人机）
见 **[PLAN.md](PLAN.md)**。
