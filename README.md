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
以及左侧 3 个蓝色士兵、右侧 3 个红色士兵。

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
│   └── units/soldier.tscn           # CharacterBody2D + ColorRect + CollisionShape2D + SoldierAI
├── scripts/
│   ├── core/game.gd                 # autoload：引导、命令下发、全局查询
│   ├── core/battle_map.gd           # 网格/地形/AStar2D/视线/掩体评估/占位渲染
│   ├── core/main.gd                 # 场景装配、演示地形与双方占位单位、HUD
│   ├── ai/utility.gd                # 通用 Utility AI（Consideration + 响应曲线）
│   ├── ai/blackboard.gd             # 小队黑板：目击/枪声记忆 + 审讯出的永久工事情报
│   ├── ai/perception.gd             # 感知：把原始读数算成打分要用的 [0,1] 量（纯查询）
│   ├── ai/behavior_tree.gd          # 极简 BT：Action / Condition / Sequence / Selector
│   ├── ai/soldier_ai.gd             # seek_cover / advance / flank / hold / rescue / build / surrender / escort
│   ├── units/soldier.gd             # 移动 / HP / 命令 / 压制 / 倒地 / 俘虏 / 占位绘制
│   ├── units/weapon.gd              # hitscan 武器：散布、冷却、近失压制、弹匣与换弹
│   └── units/build_site.gd          # 工地：施工计时 / 建成转实体 / 被打掉拆地形
├── assets/                          # 美术资源占位目录
└── PLAN.md                          # 技术栈决策 + M0~M7 里程碑
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
| `Headless 冒烟测试` | 下载 Godot 4.7.2 Linux 版 → `--headless --import` → 跑 `tests/smoke_test.tscn`，用退出码判定 |

冒烟测试是**引擎原生**的（不依赖 GUT/gdUnit 等第三方插件），当前覆盖 **32 项**断言：
坐标换算、地形读写、`add_obstacle` 不可走（穿墙路径回归）、AStar2D 封死/绕行、
UtilityAI 择优/权重/粘性/曲线单调、掩体几何（墙后得分更高、被绕侧翼后失效）、
交火（开枪 + 掉血 + `die()`）。

本地跑同样的检查：

```bash
godot --headless --path . tests/smoke_test.tscn   # 退出码 0 = 全通过
```

### `.github/workflows/web.yml`

下载 Godot + 导出模板（约 1.3 GB）→ `--export-release "Web"` → 上传 artifact `github-pages`
→ 发布到 GitHub Pages。

**一次性设置（必须手动做一次）**：仓库 `Settings → Pages → Build and deployment → Source`
选择 **GitHub Actions**。没开启时导出仍会成功、artifact 照常上传，只是最后一步发布会报
`Failed to create deployment (status: 404)`。

开启后重跑 workflow，站点地址为 `https://<用户名>.github.io/tacord/`。
在开启之前，可以下载 artifact 本地预览：

```bash
gh run download <run-id> -n github-pages -D web_preview
cd web_preview && python3 -m http.server 8080
```

> CI 读日志的坑：Actions 的日志文件存在 `*.blob.core.windows.net`，某些网络环境访问不到。
> 因此两个 workflow 都把关键输出用 `::error::` / `::warning::` 发成 **annotation**，
> 可以直接用 `gh api /repos/<owner>/<repo>/check-runs/<id>/annotations` 取回。
> 注意 annotation 有数量上限且保留**最先发出**的若干条，所以失败项要放在最前面发。

---

## 七、当前验证状态

**已在真实引擎里跑通**：GitHub Actions 上用 Godot 4.7.2 headless 执行 `tests/smoke_test.tscn`，
**154/154 项断言通过**（含掩体几何评估、交火掉血、压制数值、倒地与救援、感知与记忆、弹药与后勤、建造与 FOB、俘虏与审讯）。这个总数本身也是一条断言——`EXPECTED_CHECKS` 写死在测试里，某个测试段中途崩掉时退出码仍是 0，沙箱又读不到 CI 日志，所以必须让引擎自己判定数没数够。这套测试工作累计抓到 8 个真 bug：
`cover` 地形曾可走导致 A\* 规划穿墙路径；`find_path` 曾因 `allow_partial_path=true`
在目标不可达时返回半截路径；`die()` 曾不清 `is_downed`（死人被当成可救援的伤员）；
枪声曾只记在开枪者自己队的黑板上（听声转头永远不触发）；`clear_boards()` 曾丢掉整个字典
（活着的士兵握着旧引用，重开后没人读新黑板）；感知拆分后测试还在调已被搬走的 `_ammo_pressure()`，中止了 9 条断言（正是 `EXPECTED_CHECKS` 抓到的）。另有两条押送死锁是写代码时推演出来的，动第一行测试之前就改掉了。完整清单见 PLAN.md §6。

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

静态验证：11 个脚本加 `tests/smoke_test.gd` 通过 `gdparse` 与 `gdlint`；M0/M1 期间做过一次引擎
API 逐个比对（脚本里的引擎/项目符号对 Godot **4.7.2** 与 **4.2** 源码自带的类文档，均 0 问题），
M2 新增代码用到的 `is_equal_approx` / `is_zero_approx` 也在 `@GlobalScope.xml` 里确认过；
`project.godot` 的每个设置项与 `.tscn` 的每个属性名都在引擎源码中确认存在。

**Web 导出已验证成功**（CI 里产出 10.3 MB 的 `github-pages` artifact）。

**仍未验证**：① 浏览器里的实际画面（需要开启 Pages 或本地预览 artifact）；
② macOS 签名/公证（需真机）。

技术选型理由、MVP 范围与后续里程碑（M1 交火 → M2 压制 → M3 倒地救援 → M4 感知记忆 → M5 弹药后勤 → M6 建造与 FOB → M7 俘虏审讯）
见 **[PLAN.md](PLAN.md)**。
