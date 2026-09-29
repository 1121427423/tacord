# 士兵 AI：Utility AI 决定“做什么”（找掩体/推进/包抄/待命），行为树负责“怎么做”。
class_name SoldierAI
extends Node

signal action_changed(previous: StringName, current: StringName)

const ACTION_SEEK_COVER := &"seek_cover"
const ACTION_ADVANCE := &"advance"
const ACTION_FLANK := &"flank"
const ACTION_HOLD := &"hold"
const ACTION_RESCUE := &"rescue"
const ACTION_BUILD := &"build"
const ACTION_SURRENDER := &"surrender"
const ACTION_ESCORT := &"escort"

## 压制值达到这个阈值时停火（缩在掩体后）。
const PINNED_FIRE_THRESHOLD := 0.75

const SCAN_RADIUS := 360.0  # 感知半径（像素）
const COVER_SCAN_CELLS := 6  # 找掩体时的搜索半径（格）
const ARRIVAL_EPSILON := 3.0

## 愿意为救人跑多远（像素）。
const RESCUE_SCAN_RADIUS := 900.0

## 医疗兵的救援意愿加成（分数乘算，最终仍夹在 1.0）。
const MEDIC_SCORE_BONUS := 1.6

## 有战友倒地时，推进/包抄欲望乘 (1 - 这个值)：救人的优先级要能压过命令。
const DOWNED_ALLY_ORDER_PENALTY := 0.5

## 包扎速度倍率：医疗兵 x2。
const RESCUE_SPEED_NORMAL := 1.0
const RESCUE_SPEED_MEDIC := 2.0

## 离伤员多近才算够得着（开始拖 + 包扎）。
const DRAG_RANGE := 26.0

## 拖动落点的掩体搜索半径（格）。
const DRAG_COVER_CELLS := 3

## 枪声传播半径（像素）。超过这个距离就听不见。
const GUNSHOT_HEAR_RADIUS := 520.0

## 视觉感知半径（像素）。看得多远由通视决定，这里只是搜索上限。
const AWARENESS_RADIUS := 720.0

## 毫无情报时的搜索半径（格）。
const PATROL_RADIUS_CELLS := 6

## 路过尸体多远以内能摸到弹匣（像素）。
const LOOT_RADIUS := 26.0

## 弹药压力对"找掩体"的加成权重（换弹当然要在掩体后换）。
const AMMO_COVER_WEIGHT := 0.35

## 彻底打光时对推进欲望的削弱。
const DRY_ADVANCE_PENALTY := 0.6

## 愿意为施工跑多远（像素）。
const BUILD_SCAN_RADIUS := 900.0

## 离工地多近才算够得着（开始干活）。
const WORK_RANGE := 40.0

## 施工欲望的基础分。
const BUILD_SCORE_BASE := 0.45

## 有工事没修完时，推进/包抄欲望乘 (1 - 这个值)。
## 和 M3 的 DOWNED_ALLY_ORDER_PENALTY 同一个道理：不打折的话
## attack 命令下 advance 恒为 1.0，永远压过施工，没人会去建。
const BUILD_BACKLOG_ORDER_PENALTY := 0.35

## 站在建成的己方 FOB 旁边的补弹半径与速率（发/秒）。
const RESUPPLY_RADIUS := 48.0
const RESUPPLY_PER_SECOND := 8.0

## 投降的三道门槛（M7），必须同时满足：被压制、被包围、无援。
## 少一道就是普通士兵都会犯的错——挨两枪就举手，仗没法打。
const SURRENDER_SUPPRESSION := 0.55
const SURRENDER_ENEMIES_NEEDED := 2
const SURRENDER_SUPPORT_RADIUS := 300.0

## 投降的权重。必须高于 1.0 + stickiness，否则会被带粘性的推进压住（见注册处）。
const SURRENDER_WEIGHT := 1.5

## 单次 _process 里最多补做几次思考。
## 上限是为了防止 Web 导出切走标签页、回来时一次把几秒的欠账全补完。
const MAX_THINKS_PER_FRAME := 8

## 愿意为押送俘虏跑多远（像素）。
const ESCORT_SCAN_RADIUS := 1200.0

## 押送时与俘虏保持的距离（像素）。太近会互相顶，太远他跟不上。
const ESCORT_LEASH := 46.0

## 押送欲望的基础分。
const ESCORT_SCORE_BASE := 0.8

## 有俘虏没人押时，推进/包抄欲望乘 (1 - 这个值)。
## 和 DOWNED_ALLY_ORDER_PENALTY / BUILD_BACKLOG_ORDER_PENALTY 同一个道理：
## 不打折的话 attack 命令下 advance 恒为 1.0，没人会去押人。
const ESCORT_BACKLOG_ORDER_PENALTY := 0.35

## 把俘虏押到离 FOB 多近才开口审。刻意小于 game.gd 的 INTERROGATE_RADIUS(64)，
## 留出余量，免得押到了却因为差几像素而问不出话。
const DELIVER_RANGE := 48.0

## AI 思考间隔（秒）。单位数量上去后可调大以省 CPU（Web 导出尤其明显）。
@export var think_interval: float = 0.25

## 行为粘性：传给 UtilityAI，防止分数抖动导致反复横跳。
@export var stickiness: float = 0.15

## 医疗兵：救援意愿与包扎速度都更高。由 main.gd 在编队时指定。
@export var is_medic: bool = false

var soldier: CharacterBody2D = null

# BattleMap（battle_map.gd）。故意不标注类型：GDScript 对静态类型的接收者会拒绝调用
# 自定义方法，这里需要鸭子调用 cell_at / find_cover_cell / has_line_of_sight 等接口。
var map = null

# Weapon 组件（soldier 的子节点），同样不标注类型。
var weapon = null

var utility: UtilityAI = UtilityAI.new()

# 小队黑板（同队共享敌情）。由 Game 提供；没有 Game 时退化成私有黑板。
var board: Blackboard = null

# 感知（scripts/ai/perception.gd）：所有"看看四周"的纯查询都在这里。
var _perc: Perception = Perception.new()

var _trees: Dictionary = {}  # StringName -> 行为树根节点
var _action: StringName = ACTION_HOLD
var _move_started: bool = false
var _think_accum: float = 0.0
var _rng := RandomNumberGenerator.new()

# 当前正在救援的伤员（未标注类型，避免脚本循环依赖）。
var _rescue_target = null

# 是否已经把这个伤员往掩体拖过了（每个目标只拖一次）。
var _drag_started: bool = false

# 当前正在施工的工地。
var _build_target = null

# 当前正在押送的俘虏（M7）。
var _escort_target = null

# 私有黑板才由自己推进时钟（Game 提供的由 Game 统一推进）。
var _owns_board: bool = false

# 已经响应过的枪声 id，避免对同一声枪响反复转头。
var _heard_shot_id: int = 0


func _ready() -> void:
	soldier = get_parent() as CharacterBody2D
	if soldier == null:
		push_error("SoldierAI 必须作为 CharacterBody2D（soldier.gd）的子节点。")
		set_process(false)
		return
	map = get_tree().get_first_node_in_group(&"battle_map")
	if map == null:
		push_warning("SoldierAI: 场景中没有 BattleMap（group: battle_map），掩体评估将不可用。")
	weapon = soldier.get_node_or_null("Weapon")
	if weapon == null:
		push_warning("SoldierAI: 所属士兵没有 Weapon 子节点，无法开火。")
	else:
		# 自己开的枪也要上报黑板：队友靠这个判断"东边有接触"。
		weapon.connect("shot_fired", _on_own_shot_fired)
	board = _resolve_board()
	_rng.seed = hash(soldier.name)
	_perc.setup(soldier, map, weapon, get_tree())
	utility.stickiness = stickiness
	_register_considerations()
	_build_trees()
	# 打散各单位的思考相位，避免所有 AI 挤在同一帧。
	_think_accum = _rng.randf_range(0.0, think_interval)


func _process(delta: float) -> void:
	# 倒地的人什么都不做（不开火、不决策），只能等队友来拖。
	if soldier == null or soldier.get("is_dead") == true or soldier.get("is_downed") == true:
		return
	# 俘虏既不开火也不决策：枪已经交出去了，路线由押送者给。
	if soldier.get("is_captive") == true:
		return
	if _owns_board and board != null:
		board.advance(delta)
	# 交战是"反射"，每帧处理；战术决策按 think_interval 处理。
	_combat_step()
	# 按**累积时间**把思考账花掉，而不是攒够一次就清零。
	# 原来写的 `_think_accum = 0.0` 会把超出的时间丢掉：delta=0.5s 而 think_interval=0.25s
	# 时本该想 2 次却只想 1 次。后果不只是决策变慢——_try_resupply 按 think_interval 计发，
	# 账丢了 M5 的 FOB 补弹速率也会随负载下降；而押送这条链需要十来次思考，
	# 在 CI 批量执行物理帧时会卡在帧数上限边上（实测同一份代码五五开）。
	# 超过上限还没还完的欠账留在 _think_accum 里，下一帧继续还。
	_think_accum += delta
	var thinks: int = 0
	while _think_accum >= think_interval and thinks < MAX_THINKS_PER_FRAME:
		_think_accum -= think_interval
		thinks += 1
		# 摸弹是"路过顺手"的动作，跟着思考周期做，不必每帧扫全场。
		_try_loot_ammo()
		_try_resupply()
		_think()


## 自动索敌开火：有通视、在射程内的最近敌人即为目标。
## 放在 AI 层而不是 soldier 里，是为了让 M2 的压制能够直接卡住这一步。
func _combat_step() -> void:
	if weapon == null:
		return
	# 被压到抬不起头时就停火——压制衰减后会自己恢复，交火因此呈脉冲式。
	if _perc.suppression() >= PINNED_FIRE_THRESHOLD:
		return
	var target = _acquire_target()
	if target == null:
		# 看不见人，但枪声听得见：转头朝向声源（M4 验收标准的前半句）。
		_listen_for_gunshots()
		return
	var target_pos: Vector2 = target.global_position
	soldier.call("aim_at", target_pos)
	soldier.call("try_fire", target_pos)


## 自己开火时上报枪声。声音是给**敌人**听的：让 Game 把它分发到所有敌队黑板。
func _on_own_shot_fired(from: Vector2, _to: Vector2, _hit_target: bool) -> void:
	if soldier == null:
		return
	var my_team: int = int(soldier.get("team"))
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("hear_gunshot"):
		game.call("hear_gunshot", from, my_team)
	elif board != null:
		# 没有 Game 的退化路径（单独实例化做测试）：至少自己这块黑板记得。
		board.report_gunshot(from, my_team)


## 看不见敌人时，朝听得见的最近敌队枪声转头。
## 只对"新的一声"响应：否则士兵会一直僵在同一个朝向上，别的判断全被冻住。
func _listen_for_gunshots() -> void:
	if board == null or soldier == null:
		return
	var shot: Dictionary = board.nearest_enemy_gunshot(
		soldier.global_position, int(soldier.get("team")), GUNSHOT_HEAR_RADIUS
	)
	if shot.is_empty() or int(shot["id"]) == _heard_shot_id:
		return
	_heard_shot_id = int(shot["id"])
	soldier.call("aim_at", shot["pos"])


## 取同队黑板。没有 Game（单独实例化做测试）时退化成私有黑板，自己推进时钟。
func _resolve_board() -> Blackboard:
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("blackboard") and soldier != null:
		return game.blackboard(int(soldier.get("team")))
	_owns_board = true
	push_warning("SoldierAI: 没有 Game 自动加载，改用私有黑板（敌情不与队友共享）。")
	return Blackboard.new()


## 射程内、且有通视的最近敌人；没有则返回 null。顺手把目击报给全队。
func _acquire_target():
	if soldier == null:
		return null
	var reach: float = float(soldier.call("weapon_range"))
	if reach <= 0.0:
		return null
	var best = _perc.visible_enemy(reach)
	# 看见就是看见：报给全队，这样别人看不见也能来搜。
	if best != null and board != null:
		board.report_sighting(best, best.global_position)
	return best


## 当前正在执行的行为名（HUD / 调试用）。
func current_action() -> StringName:
	return _action


## 当前行为的各项效用得分快照，形如 "advance:0.62"。
func scores_text() -> String:
	var parts: Array = []
	for id in utility.considerations():
		parts.append("%s:%.2f" % [String(id), utility.score_of(id)])
	return " ".join(parts)


func _think() -> void:
	var chosen: StringName = utility.evaluate(_action)
	if chosen == &"":
		chosen = ACTION_HOLD
	if chosen != _action:
		var previous: StringName = _action
		_action = chosen
		_reset_trees()
		action_changed.emit(previous, _action)
	var tree = _trees.get(_action)
	if tree != null:
		tree.tick({}, get_process_delta_time())


func _reset_trees() -> void:
	_move_started = false
	_drag_started = false
	_build_target = null
	# 先放押送权再清引用：反过来会让押送权悬在死目标上，没人再接得走。
	_forget_escort()
	for tree in _trees.values():
		BehaviorTree.reset_node(tree)


# ---------------------------------------------------------------- 效用考虑因素


func _register_considerations() -> void:
	# 0) 投降。两道保险都要：
	# ① 注册在**最前面**——evaluate 用严格大于，平分归先注册者；
	# ② 权重 1.5——evaluate 给当前行为加 stickiness(0.15)，
	#    attack 命令下 advance 能到 1.0+0.15=1.15，权重 1.0 的投降会被它压住。
	# 分数只有 0 或 1.5 两档：门槛是二值的，投降不该和别的欲望讨价还价。
	utility.register_consideration(
		ACTION_SURRENDER, _consider_surrender, 0.0, 1.0, SURRENDER_WEIGHT, UtilityAI.CurveType.LINEAR
	)
	# 1) 危险越高（附近敌人多且近、被通视、自己受伤），越想去找掩体。
	utility.register_consideration(
		ACTION_SEEK_COVER, _consider_seek_cover, 0.0, 1.0, 1.05, UtilityAI.CurveType.SMOOTHSTEP
	)
	# 2) 推进欲望 = 命令优先级 x 当前血量比例。
	utility.register_consideration(
		ACTION_ADVANCE, _consider_advance, 0.0, 1.0, 0.9, UtilityAI.CurveType.TANH, 1.4
	)
	# 3) 有敌人把侧翼/背面暴露给我们时，包抄分数陡增。
	utility.register_consideration(
		ACTION_FLANK, _consider_flank, 0.0, 1.0, 1.0, UtilityAI.CurveType.TANH, 2.2
	)
	# 4) 兜底行为：没有明确命令时原地待命并保持观察。
	utility.register_consideration(
		ACTION_HOLD, _consider_hold, 0.0, 1.0, 0.35, UtilityAI.CurveType.LINEAR
	)
	# 5) 有队友倒地时去救。用 LINEAR：分数已经在 _consider_rescue 里算好了。
	utility.register_consideration(
		ACTION_RESCUE, _consider_rescue, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)
	# 6) 有工地没修完就去施工。同样是 LINEAR。
	utility.register_consideration(
		ACTION_BUILD, _consider_build, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)
	# 7) 有俘虏没人押就押回 FOB 审。同样是 LINEAR。
	utility.register_consideration(
		ACTION_ESCORT, _consider_escort, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)


func _consider_seek_cover() -> float:
	var danger: float = _perc.danger_pressure(SCAN_RADIUS)
	var wounded: float = 1.0 - _perc.health_ratio()
	var pinned: float = _perc.suppression()
	var ammo: float = _perc.ammo_pressure()
	return clampf(
		danger * 0.6 + wounded * 0.4 + pinned * 0.65 + ammo * AMMO_COVER_WEIGHT, 0.0, 1.0
	)


## 测试入口：弹药压力读数。冒烟测试整个套件都在直呼私有助手
## （_consider_advance、_try_loot_ammo 同样如此），感知搬走后留这一条转发，
## 免得测试改去摸 _perc。私有方法不占 gdlint 的公开方法额度。
func _ammo_pressure() -> float:
	return _perc.ammo_pressure()


## 投降（M7）：被压制 + 被包围 + 无援，三者缺一即返回 0。
## 满足就给满分——这是个终局决定，不该和别的欲望讨价还价。
func _consider_surrender() -> float:
	if soldier == null or soldier.get("is_captive") == true:
		return 0.0
	if _perc.suppression() < SURRENDER_SUPPRESSION:
		return 0.0
	# 被包围：看得见的敌人不止一个（光有枪声不算，得真看见人）。
	var visible: Array = []
	for enemy in _perc.nearby_enemies(SCAN_RADIUS):
		if map != null and map.has_method("has_line_of_sight") and map.has_line_of_sight(
			soldier.global_position, enemy.global_position
		):
			visible.append(enemy)
	if visible.size() < SURRENDER_ENEMIES_NEEDED:
		return 0.0
	# 无援：附近没有还站着能打的战友。有人能来救，就没人会举白旗。
	if _perc.nearest_standing_ally(SURRENDER_SUPPORT_RADIUS) != null:
		return 0.0
	return 1.0


func _consider_advance() -> float:
	# 被压制时推进欲望直接归零：没人会大摇大摆穿过火力杀伤区。
	# 彻底打光时也要打折：端着空枪冲锋只是送死。
	var dry: float = 1.0 - _perc.dry_factor() * DRY_ADVANCE_PENALTY
	var raw: float = _perc.order_priority() * _perc.health_ratio() * _mobility_factor() * dry
	return clampf(raw, 0.0, 1.0)


func _consider_flank() -> float:
	return clampf(
		_perc.flank_opportunity(SCAN_RADIUS * 1.2)
		* _perc.health_ratio()
		* 1.15
		* _mobility_factor(0.8),
		0.0,
		1.0
	)


## 机动类行为的共同折扣：压制削一半上限，战友倒地再打对折。
## suppression_scale 让包抄比推进更怕压制（绕后途中被打侧翼最致命）。
func _mobility_factor(suppression_scale: float = 1.0) -> float:
	return (
		(1.0 - _perc.suppression() * suppression_scale)
		* (1.0 - _downed_ally_factor())
		* (1.0 - _build_backlog_factor())
		* (1.0 - _escort_backlog_factor())
	)


## 有倒地的友军在附近时返回折扣量，否则 0。
func _downed_ally_factor() -> float:
	if _perc.nearest_downed_ally(RESCUE_SCAN_RADIUS) == null:
		return 0.0
	return DOWNED_ALLY_ORDER_PENALTY


## 有没修完的工事时返回折扣量，否则 0。
func _build_backlog_factor() -> float:
	if _nearest_open_site() == null:
		return 0.0
	return BUILD_BACKLOG_ORDER_PENALTY


## 押送俘虏（M7）。没地方审（本队没有建成的 FOB）就不算——那只是白跑一趟。
func _consider_escort() -> float:
	var captive = _nearest_escortable_captive()
	if captive == null:
		return 0.0
	var distance: float = soldier.global_position.distance_to(captive.global_position)
	var proximity: float = 1.0 - clampf(distance / ESCORT_SCAN_RADIUS, 0.0, 1.0)
	# 和救援一样对被压制打折而不是归零：押送可以冒点险，但不该压过求生。
	return clampf(
		(ESCORT_SCORE_BASE + 0.2 * proximity) * (1.0 - _perc.suppression() * 0.5), 0.0, 1.0
	)


func _consider_build() -> float:
	var site = _nearest_open_site()
	if site == null:
		return 0.0
	# 越接近完工越没必要再派人；被压制时先去躲（施工可以随时中断）。
	var ratio: float = float(site.call("build_ratio"))
	var distance: float = soldier.global_position.distance_to(site.global_position)
	var proximity: float = 1.0 - clampf(distance / BUILD_SCAN_RADIUS, 0.0, 1.0)
	var raw: float = BUILD_SCORE_BASE + 0.35 * (1.0 - ratio) + 0.1 * proximity
	return clampf(raw * (1.0 - _perc.suppression()), 0.0, 1.0)


## 最近的、还没建成的己方工地；没有则 null。
func _nearest_open_site():
	if soldier == null:
		return null
	var best = null
	var best_dist: float = BUILD_SCAN_RADIUS
	var my_team: int = int(soldier.get("team"))
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != my_team or site.get("is_built") == true:
			continue
		var d: float = soldier.global_position.distance_to(site.global_position)
		if d <= best_dist:
			best_dist = d
			best = site
	return best


## 站在建成的己方 FOB 旁边就能补备弹（M5 的"阵地沉寂"由此可逆）。
func _try_resupply() -> void:
	if weapon == null or soldier == null or not weapon.has_method("add_reserve"):
		return
	var my_team: int = int(soldier.get("team"))
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != my_team:
			continue
		if not site.has_method("is_supply_point") or not bool(site.call("is_supply_point")):
			continue
		if soldier.global_position.distance_to(site.global_position) > RESUPPLY_RADIUS:
			continue
		weapon.call("add_reserve", int(RESUPPLY_PER_SECOND * think_interval))
		return


## 有俘虏没人押时返回折扣量，否则 0。
func _escort_backlog_factor() -> float:
	if _nearest_escortable_captive() == null:
		return 0.0
	return ESCORT_BACKLOG_ORDER_PENALTY


## 最近一个「该我押」的俘虏：属于本队、还没人接手（或接手的人就是我），
## 且本队确实有一座建成的 FOB 能审。条件不满足一律返回 null。
func _nearest_escortable_captive():
	if soldier == null:
		return null
	var game := get_node_or_null("/root/Game")
	if game == null or not game.has_method("captives"):
		return null
	if _nearest_own_fob() == null:
		return null
	var best = null
	var best_dist: float = ESCORT_SCAN_RADIUS
	for captive in game.call("captives", int(soldier.get("team"))):
		var holder = _current_escort(captive)
		if holder != null and holder != soldier:
			continue
		var d: float = soldier.global_position.distance_to(captive.global_position)
		if d <= best_dist:
			best_dist = d
			best = captive
	return best


## 这个俘虏现在归谁押（null = 没人）。
func _current_escort(captive):
	var game := get_node_or_null("/root/Game")
	if game == null or not game.has_method("escort_of"):
		return null
	var holder = game.call("escort_of", captive)
	if holder == null or not is_instance_valid(holder):
		return null
	if holder.get("is_dead") == true or holder.get("is_downed") == true:
		return null
	return holder


## 本队最近的、已建成的 FOB；没有则 null。
func _nearest_own_fob():
	if soldier == null:
		return null
	var best = null
	var best_dist: float = INF
	var my_team: int = int(soldier.get("team"))
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != my_team:
			continue
		if not site.has_method("is_supply_point") or not bool(site.call("is_supply_point")):
			continue
		var d: float = soldier.global_position.distance_to(site.global_position)
		if d < best_dist:
			best_dist = d
			best = site
	return best


func _consider_hold() -> float:
	# 命令越明确，待命越没有吸引力。
	return clampf(0.6 - 0.4 * _perc.order_priority(), 0.0, 1.0)


func _consider_rescue() -> float:
	var casualty = _perc.nearest_downed_ally(RESCUE_SCAN_RADIUS)
	if casualty == null:
		return 0.0
	# 失血越多越急、人越近越该我去。被压制时打对折而不是归零：
	# 冒死救人是有的，但分数要能被真正的致命威胁压过去。
	var urgency: float = 1.0 - float(casualty.call("bleed_ratio"))
	var distance: float = soldier.global_position.distance_to(casualty.global_position)
	var proximity: float = 1.0 - clampf(distance / RESCUE_SCAN_RADIUS, 0.0, 1.0)
	var score: float = 0.45 + 0.4 * urgency + 0.15 * proximity
	if is_medic:
		score *= MEDIC_SCORE_BONUS
	return clampf(score * (1.0 - _perc.suppression() * 0.5), 0.0, 1.0)


## 路过尸体就摸弹匣（M5 唯一的补弹途径）。每个思考周期查一次就够了。
func _try_loot_ammo() -> void:
	if weapon == null or soldier == null:
		return
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit == soldier or unit.get("is_dead") != true:
			continue
		if soldier.global_position.distance_to(unit.global_position) > LOOT_RADIUS:
			continue
		var corpse_weapon = unit.get_node_or_null("Weapon")
		if corpse_weapon != null:
			weapon.call("take_ammo_from", corpse_weapon)


# ---------------------------------------------------------------- 行为树


func _build_trees() -> void:
	_trees[ACTION_SEEK_COVER] = BehaviorTree.sequence(
		ACTION_SEEK_COVER,
		[BehaviorTree.action(&"pick_cover", _pick_cover_target), BehaviorTree.action(&"walk", _walk)]
	)
	_trees[ACTION_ADVANCE] = BehaviorTree.sequence(
		ACTION_ADVANCE,
		[BehaviorTree.action(&"pick_advance", _pick_advance_target), BehaviorTree.action(&"walk", _walk)]
	)
	_trees[ACTION_FLANK] = BehaviorTree.sequence(
		ACTION_FLANK,
		[BehaviorTree.action(&"pick_flank", _pick_flank_target), BehaviorTree.action(&"walk", _walk)]
	)
	_trees[ACTION_HOLD] = BehaviorTree.action(ACTION_HOLD, _do_hold)
	# 投降：单动作。举手之后本 AI 就不再决策（见 _process 的俘虏短路）。
	_trees[ACTION_SURRENDER] = BehaviorTree.action(ACTION_SURRENDER, _do_surrender)
	# 救援：接近伤员 -> 走到他身边 -> 拖到掩体并包扎。
	# 掩护火力不需要单独子树：_combat_step 每帧都会对可见敌人还击，
	# 所以医疗兵是一边压着对面一边救人的。
	_trees[ACTION_RESCUE] = BehaviorTree.sequence(
		ACTION_RESCUE,
		[
			BehaviorTree.action(&"pick_casualty", _pick_rescue_target),
			BehaviorTree.action(&"walk", _walk),
			BehaviorTree.action(&"drag_and_bandage", _drag_and_bandage),
		]
	)
	# 施工：走到工地旁 -> 干活。
	# 和救援一样，掩护火力复用每帧的 _combat_step —— 所以是边打边建，战斗不中断。
	# 押送：认领俘虏 -> 走到他身边 -> 押回 FOB 审讯。
	_trees[ACTION_ESCORT] = BehaviorTree.sequence(
		ACTION_ESCORT,
		[
			BehaviorTree.action(&"pick_captive", _pick_escort_target),
			BehaviorTree.action(&"walk", _walk),
			BehaviorTree.action(&"march_and_deliver", _march_and_deliver),
		]
	)
	_trees[ACTION_BUILD] = BehaviorTree.sequence(
		ACTION_BUILD,
		[
			BehaviorTree.action(&"pick_site", _pick_build_target),
			BehaviorTree.action(&"walk", _walk),
			BehaviorTree.action(&"work", _work_on_site),
		]
	)


func _pick_cover_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var threats: Array = []
	for enemy in _perc.nearby_enemies(900.0):
		threats.append(enemy.global_position)
	var cell: Vector2i = map.find_cover_cell(
		map.cell_at(soldier.global_position), threats, COVER_SCAN_CELLS
	)
	if cell.x < 0 or not _start_move(cell):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


## 推进落点三级优先：看得见的人 > 最后已知位置 > 就近搜索。
## 关键点是第二、三级——M4 之前这里用的是 _nearest_enemy(1e9)，
## 等于每个士兵都开着透视直接走向敌人真实坐标；现在看不见就只能靠记忆和搜索。
func _pick_advance_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var enemy = _perc.visible_enemy(AWARENESS_RADIUS)
	if enemy != null:
		# 贴近敌人但保留 2 格开火距离，并在落点周围挑掩体质量最好的格子。
		return _advance_on_position(enemy.global_position, 2)
	var memory: Dictionary = {}
	if board != null:
		memory = board.best_memory(int(soldier.get("team")))
	if not memory.is_empty():
		# 去查最后已知位置本身（不留开火距离：那里可能已经没人了）。
		return _advance_on_position(memory["pos"], 0)
	return _patrol_nearby()


## 朝某个世界坐标推进；standoff_cells > 0 时在目标前留出这么多格的开火距离。
func _advance_on_position(world_pos: Vector2, standoff_cells: int) -> int:
	var to_target: Vector2 = world_pos - soldier.global_position
	var standoff: Vector2 = world_pos
	if standoff_cells > 0 and to_target.length_squared() > 1.0:
		standoff = world_pos - to_target.normalized() * float(map.cell_size) * float(standoff_cells)
	var cell: Vector2i = _best_cell_around(map.cell_at(standoff), 3)
	if cell.x < 0 or not _start_move(cell):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


## 毫无情报时的搜索：在附近随机挑一个可走的格子走过去，而不是原地发呆。
func _patrol_nearby() -> int:
	var options: Array = []
	for cell in map.cells_in_radius(map.cell_at(soldier.global_position), PATROL_RADIUS_CELLS):
		if map.is_walkable(cell):
			options.append(cell)
	if options.is_empty():
		return BehaviorTree.Status.FAILURE
	var pick: Vector2i = options[_rng.randi_range(0, options.size() - 1)]
	if not _start_move(pick):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


func _pick_flank_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var victim = null
	var best_alignment: float = 0.25
	for enemy in _perc.nearby_enemies(SCAN_RADIUS * 1.2):
		var alignment: float = _perc.flank_alignment(enemy)
		if alignment > best_alignment:
			best_alignment = alignment
			victim = enemy
	if victim == null:
		return BehaviorTree.Status.FAILURE
	var cell: Vector2i = _best_cell_around(map.cell_at(_flank_point(victim)), 3)
	if cell.x < 0 or not _start_move(cell):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


func _walk(_ctx: Dictionary, _delta: float) -> int:
	if not _move_started or soldier == null:
		return BehaviorTree.Status.FAILURE
	if soldier.get("is_dead") == true:
		return BehaviorTree.Status.FAILURE
	if soldier.call("has_arrived"):
		_move_started = false
		return BehaviorTree.Status.SUCCESS
	return BehaviorTree.Status.RUNNING


func _do_hold(_ctx: Dictionary, _delta: float) -> int:
	_move_started = false
	if soldier != null:
		soldier.call("stop_moving")
	return BehaviorTree.Status.SUCCESS


## 向最近那个看得见的敌人举白旗。看不见人就返回 FAILURE（听声不算被包围）。
func _do_surrender(_ctx: Dictionary, _delta: float) -> int:
	if soldier == null or soldier.get("is_captive") == true:
		return BehaviorTree.Status.SUCCESS
	var enemy = _perc.visible_enemy(SCAN_RADIUS)
	if enemy == null:
		return BehaviorTree.Status.FAILURE
	if not bool(soldier.call("surrender", int(enemy.get("team")))):
		return BehaviorTree.Status.FAILURE
	# 自己都举手了，手上押的人得放掉，否则押送权挂在俘虏身上没人接。
	_forget_escort()
	return BehaviorTree.Status.SUCCESS


func _pick_rescue_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var casualty = _perc.nearest_downed_ally(RESCUE_SCAN_RADIUS)
	if casualty == null:
		_rescue_target = null
		return BehaviorTree.Status.FAILURE
	# 换了一个伤员就重新计一次"是否已经拖过"。
	if _rescue_target != casualty:
		_rescue_target = casualty
		_drag_started = false
	if not _start_move(map.cell_at(casualty.global_position)):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


func _drag_and_bandage(_ctx: Dictionary, _delta: float) -> int:
	var casualty = _rescue_target
	if casualty == null or not is_instance_valid(casualty):
		_rescue_target = null
		return BehaviorTree.Status.FAILURE
	if casualty.get("is_downed") != true:
		# 已经站起来了（可能是别人先救到的）。
		_rescue_target = null
		return BehaviorTree.Status.SUCCESS
	if soldier.global_position.distance_to(casualty.global_position) > DRAG_RANGE:
		# 距离被拉开了：让序列回到开头重新接近。
		return BehaviorTree.Status.FAILURE
	if not _drag_started:
		_drag_started = true
		_drag_casualty_to_cover(casualty)
	# 树每隔 think_interval 才 tick 一次，所以按 think_interval 推进包扎进度，
	# 这样 RESCUE_TIME 秒就是真实的秒数，不受 think_interval 调整影响。
	var done: bool = casualty.call(
		"apply_rescue", think_interval, _rescue_speed(), soldier
	)
	if done:
		_rescue_target = null
		return BehaviorTree.Status.SUCCESS
	return BehaviorTree.Status.RUNNING


## 把伤员往附近掩体质量最好的格子拖（他自己用爬行速度过去）。
func _drag_casualty_to_cover(casualty) -> void:
	if map == null or not map.has_method("find_cover_cell"):
		return
	var threats: Array = []
	for enemy in _perc.nearby_enemies(900.0):
		threats.append(enemy.global_position)
	var cell: Vector2i = map.find_cover_cell(
		map.cell_at(casualty.global_position), threats, DRAG_COVER_CELLS
	)
	if cell.x >= 0:
		casualty.call("move_to_cell", cell)


## 包扎速度倍率：医疗兵 x2。
func _rescue_speed() -> float:
	return RESCUE_SPEED_MEDIC if is_medic else RESCUE_SPEED_NORMAL


func _pick_build_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var site = _nearest_open_site()
	if site == null:
		_build_target = null
		return BehaviorTree.Status.FAILURE
	_build_target = site
	# 站在工地**旁边**干活，不站上去：建成后那一格会变成实体障碍，
	# 站在上面的人会被卡进碰撞体里。
	var spot: Vector2i = _work_spot_around(map.cell_at(site.global_position))
	if spot.x < 0 or not _start_move(spot):
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


func _work_on_site(_ctx: Dictionary, _delta: float) -> int:
	var site = _build_target
	if site == null or not is_instance_valid(site):
		_build_target = null
		return BehaviorTree.Status.FAILURE
	if site.get("is_built") == true:
		_build_target = null
		return BehaviorTree.Status.SUCCESS
	if soldier.global_position.distance_to(site.global_position) > WORK_RANGE:
		return BehaviorTree.Status.FAILURE
	# 和包扎同理：树每隔 think_interval 才 tick 一次，所以按 think_interval 记工时，
	# build_cost 因此是真实的"人·秒"，不受思考频率影响。
	if site.call("apply_labor", think_interval, 1.0):
		_build_target = null
		return BehaviorTree.Status.SUCCESS
	return BehaviorTree.Status.RUNNING


func _pick_escort_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var captive = _nearest_escortable_captive()
	if captive == null:
		_forget_escort()
		return BehaviorTree.Status.FAILURE
	var game := get_node_or_null("/root/Game")
	if game == null or not game.has_method("claim_escort"):
		return BehaviorTree.Status.FAILURE
	# 押送权要抢：抢不到说明别人已经在押了，换一个目标。
	if not bool(game.call("claim_escort", captive, soldier)):
		return BehaviorTree.Status.FAILURE
	_escort_target = captive
	if not _start_move(map.cell_at(captive.global_position)):
		_forget_escort()
		return BehaviorTree.Status.FAILURE
	return BehaviorTree.Status.SUCCESS


func _march_and_deliver(_ctx: Dictionary, _delta: float) -> int:
	var captive = _escort_target
	if captive == null or not is_instance_valid(captive):
		_forget_escort()
		return BehaviorTree.Status.FAILURE
	if captive.get("is_captive") != true or captive.get("is_dead") == true:
		# 已经跑掉或被打死了：这一趟白跑，但不是失败。
		_forget_escort()
		return BehaviorTree.Status.SUCCESS
	if soldier.global_position.distance_to(captive.global_position) > ESCORT_LEASH:
		# 距离被拉开了：让序列回到开头重新接近。
		return BehaviorTree.Status.FAILURE
	var fob = _nearest_own_fob()
	if fob == null:
		_forget_escort()
		return BehaviorTree.Status.FAILURE
	_march_captive_to(fob)
	if captive.global_position.distance_to(fob.global_position) > DELIVER_RANGE:
		return BehaviorTree.Status.RUNNING
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("interrogate"):
		game.call("interrogate", captive)
	# 情报到手就放人（MVP 简化：不做长期关押，也不做俘获后编入本队）。
	captive.call("release")
	_forget_escort()
	return BehaviorTree.Status.SUCCESS


## 押着俘虏往 FOB 走：两人去 FOB 旁的同一格。
## 早先写的是「俘虏跟在押送者身后、背向 FOB 那一侧」——推演路径时发现那是死锁：
## 押送者停在 FOB 旁一格（离中心 32px），俘虏停在他身后一格（离中心 64px），
## 64 恰好卡在 DELIVER_RANGE(48) 外面，march_and_deliver 永远返回 RUNNING，交不了人。
## 而且身后那格是否可走还取决于 _work_spot_around 挑中哪个邻居，结果不确定。
## 两人叠在同一格没有物理问题：士兵在第 1 层、只与第 2 层障碍碰撞。
func _march_captive_to(fob) -> void:
	if map == null:
		return
	var spot: Vector2i = _work_spot_around(map.cell_at(fob.global_position))
	if spot.x < 0:
		return
	soldier.call("move_to_cell", spot)
	_escort_target.call("move_to_cell", spot)


## 放下押送权。必须在换行为时也调用——否则押送权一直占着，
## 别的兵 claim 不到，这个俘虏就永远没人管。
func _forget_escort() -> void:
	var captive = _escort_target
	_escort_target = null
	if captive == null or not is_instance_valid(captive):
		return
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("drop_escort"):
		game.call("drop_escort", captive, soldier)


## 工地周边一格内挑一个可走的落脚点（排除工地本身）。
func _work_spot_around(center: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist: float = INF
	for cell in map.cells_in_radius(center, 1):
		if cell == center or not map.is_walkable(cell):
			continue
		var d: float = float((cell - center).length())
		if d < best_dist:
			best_dist = d
			best = cell
	return best


# ---------------------------------------------------------------- 移动辅助


func _start_move(cell: Vector2i) -> bool:
	if soldier == null:
		return false
	_move_started = bool(soldier.call("move_to_cell", cell))
	return _move_started


## 在 center 周边 radius 格内，挑一个可走且掩体得分最高的格子。
func _best_cell_around(center: Vector2i, radius: int) -> Vector2i:
	var threats: Array = []
	for enemy in _perc.nearby_enemies(900.0):
		threats.append(enemy.global_position)
	var best := Vector2i(-1, -1)
	var best_score: float = -INF
	for cell in map.cells_in_radius(center, radius):
		if not map.is_walkable(cell):
			continue
		var score: float = map.cover_score(cell, threats)
		if score > best_score:
			best_score = score
			best = cell
	return best


## 包抄落点：绕到目标侧向 3 格、并向后收 1 格，避免直接贴脸。
func _flank_point(enemy) -> Vector2:
	var to_enemy: Vector2 = enemy.global_position - soldier.global_position
	var side: Vector2 = to_enemy.normalized().orthogonal()
	if _rng.randf() < 0.5:
		side = -side
	var side_offset: Vector2 = side * float(map.cell_size) * 3.0
	var pull_back: Vector2 = to_enemy.normalized() * float(map.cell_size)
	return enemy.global_position + side_offset - pull_back
