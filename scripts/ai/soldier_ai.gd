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

## 命令优先级：宏观命令通过它影响效用打分，士兵仍然自己决定怎么执行。
const ORDER_PRIORITY := {
	"attack": 1.0,
	"flank": 0.8,
	"defend": 0.35,
	"hold": 0.15,
	"retreat": 0.0,
}

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
	utility.stickiness = stickiness
	_register_considerations()
	_build_trees()
	# 打散各单位的思考相位，避免所有 AI 挤在同一帧。
	_think_accum = _rng.randf_range(0.0, think_interval)


func _process(delta: float) -> void:
	# 倒地的人什么都不做（不开火、不决策），只能等队友来拖。
	if soldier == null or soldier.get("is_dead") == true or soldier.get("is_downed") == true:
		return
	if _owns_board and board != null:
		board.advance(delta)
	# 交战是"反射"，每帧处理；战术决策按 think_interval 处理。
	_combat_step()
	_think_accum += delta
	if _think_accum < think_interval:
		return
	_think_accum = 0.0
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
	if _suppression() >= PINNED_FIRE_THRESHOLD:
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
	var best = _visible_enemy(reach)
	# 看见就是看见：报给全队，这样别人看不见也能来搜。
	if best != null and board != null:
		board.report_sighting(best, best.global_position)
	return best


## 有通视的最近敌人（不限射程，用于决定往哪推进）；没有则 null。
func _visible_enemy(radius: float):
	if soldier == null or map == null:
		return null
	var best = null
	var best_dist: float = radius
	for enemy in _nearby_enemies(radius):
		if not map.has_line_of_sight(soldier.global_position, enemy.global_position):
			continue
		var distance: float = soldier.global_position.distance_to(enemy.global_position)
		if distance <= best_dist:
			best_dist = distance
			best = enemy
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
	for tree in _trees.values():
		BehaviorTree.reset_node(tree)


# ---------------------------------------------------------------- 效用考虑因素


func _register_considerations() -> void:
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


func _consider_seek_cover() -> float:
	var danger: float = _danger_pressure()
	var wounded: float = 1.0 - _health_ratio()
	var pinned: float = _suppression()
	var ammo: float = _ammo_pressure()
	return clampf(
		danger * 0.6 + wounded * 0.4 + pinned * 0.65 + ammo * AMMO_COVER_WEIGHT, 0.0, 1.0
	)


func _consider_advance() -> float:
	# 被压制时推进欲望直接归零：没人会大摇大摆穿过火力杀伤区。
	# 彻底打光时也要打折：端着空枪冲锋只是送死。
	var dry: float = 1.0 - _dry_factor() * DRY_ADVANCE_PENALTY
	var raw: float = _order_priority() * _health_ratio() * _mobility_factor() * dry
	return clampf(raw, 0.0, 1.0)


func _consider_flank() -> float:
	return clampf(
		_flank_opportunity() * _health_ratio() * 1.15 * _mobility_factor(0.8), 0.0, 1.0
	)


## 机动类行为的共同折扣：压制削一半上限，战友倒地再打对折。
## suppression_scale 让包抄比推进更怕压制（绕后途中被打侧翼最致命）。
func _mobility_factor(suppression_scale: float = 1.0) -> float:
	return (
		(1.0 - _suppression() * suppression_scale)
		* (1.0 - _downed_ally_factor())
		* (1.0 - _build_backlog_factor())
	)


## 有倒地的友军在附近时返回折扣量，否则 0。
func _downed_ally_factor() -> float:
	if _nearest_downed_ally(RESCUE_SCAN_RADIUS) == null:
		return 0.0
	return DOWNED_ALLY_ORDER_PENALTY


## 有没修完的工事时返回折扣量，否则 0。
func _build_backlog_factor() -> float:
	if _nearest_open_site() == null:
		return 0.0
	return BUILD_BACKLOG_ORDER_PENALTY


func _consider_build() -> float:
	var site = _nearest_open_site()
	if site == null:
		return 0.0
	# 越接近完工越没必要再派人；被压制时先去躲（施工可以随时中断）。
	var ratio: float = float(site.call("build_ratio"))
	var distance: float = soldier.global_position.distance_to(site.global_position)
	var proximity: float = 1.0 - clampf(distance / BUILD_SCAN_RADIUS, 0.0, 1.0)
	var raw: float = BUILD_SCORE_BASE + 0.35 * (1.0 - ratio) + 0.1 * proximity
	return clampf(raw * (1.0 - _suppression()), 0.0, 1.0)


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


func _consider_hold() -> float:
	# 命令越明确，待命越没有吸引力。
	return clampf(0.6 - 0.4 * _order_priority(), 0.0, 1.0)


func _consider_rescue() -> float:
	var casualty = _nearest_downed_ally(RESCUE_SCAN_RADIUS)
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
	return clampf(score * (1.0 - _suppression() * 0.5), 0.0, 1.0)


# ---------------------------------------------------------------- 感知


func _suppression() -> float:
	if soldier == null:
		return 0.0
	return clampf(float(soldier.get("suppression")), 0.0, 1.0)


func _health_ratio() -> float:
	if soldier == null:
		return 0.0
	var max_hp: float = maxf(1.0, float(soldier.get("max_hp")))
	return clampf(float(soldier.get("hp")) / max_hp, 0.0, 1.0)


## 弹药压力 [0,1]：正在换弹或弹匣已空最急，其余按弹匣余量线性。
func _ammo_pressure() -> float:
	if weapon == null:
		return 0.0
	if weapon.get("is_reloading") == true:
		return 1.0
	var mag: int = int(weapon.get("magazine_size"))
	if mag <= 0:
		return 0.0
	return 1.0 - clampf(float(int(weapon.get("ammo_in_mag"))) / float(mag), 0.0, 1.0)


## 彻底打光（弹匣与备弹都空）时返回 1，否则 0。
func _dry_factor() -> float:
	if weapon == null or not weapon.has_method("is_dry"):
		return 0.0
	return 1.0 if weapon.call("is_dry") else 0.0


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


func _order_priority() -> float:
	if soldier == null:
		return 0.0
	return float(ORDER_PRIORITY.get(String(soldier.get("current_order")), 0.15))


## 半径内的敌方单位（排除自己、友军与已阵亡者）。
func _nearby_enemies(radius: float) -> Array:
	var out: Array = []
	if soldier == null:
		return out
	var my_team: int = int(soldier.get("team"))
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit == soldier or int(unit.get("team")) == my_team:
			continue
		# 倒地的人不算有效目标：不鞭尸，也不为已经趴下的敌人计算危险压力。
		if unit.get("is_dead") == true or unit.get("is_downed") == true:
			continue
		if soldier.global_position.distance_to(unit.global_position) <= radius:
			out.append(unit)
	return out


## 最近的倒地友军；没有则返回 null。
func _nearest_downed_ally(radius: float):
	if soldier == null:
		return null
	var best = null
	var best_dist: float = radius
	var my_team: int = int(soldier.get("team"))
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit == soldier or int(unit.get("team")) != my_team:
			continue
		if unit.get("is_downed") != true or unit.get("is_dead") == true:
			continue
		var d: float = soldier.global_position.distance_to(unit.global_position)
		if d <= best_dist:
			best_dist = d
			best = unit
	return best





## 危险压力 [0,1]：距离越近、越被通视，压力越大。
func _danger_pressure() -> float:
	var enemies := _nearby_enemies(SCAN_RADIUS)
	if enemies.is_empty():
		return 0.0
	var pressure: float = 0.0
	for enemy in enemies:
		var distance: float = soldier.global_position.distance_to(enemy.global_position)
		var proximity: float = 1.0 - clampf(distance / SCAN_RADIUS, 0.0, 1.0)
		var visible: float = 1.0
		if map != null and map.has_method("has_line_of_sight"):
			visible = 1.0 if map.has_line_of_sight(soldier.global_position, enemy.global_position) else 0.0
		pressure += proximity * (0.35 + 0.65 * visible)
	return clampf(pressure / 2.0, 0.0, 1.0)


## 侧翼机会 [0,1]：我们处在敌人朝向的侧后方时接近 1（它的侧面/背面对我们敞开）。
func _flank_opportunity() -> float:
	var best: float = 0.0
	for enemy in _nearby_enemies(SCAN_RADIUS * 1.2):
		best = maxf(best, _flank_alignment(enemy))
	return best


func _flank_alignment(enemy) -> float:
	var facing: Vector2 = enemy.get("facing")
	var to_us: Vector2 = soldier.global_position - enemy.global_position
	if facing.length_squared() < 0.0001 or to_us.length_squared() < 1.0:
		return 0.0
	# dot = 1 表示我们正对它（无机会）；dot = -1 表示我们在它正后方（机会最大）。
	return clampf(-facing.normalized().dot(to_us.normalized()), 0.0, 1.0)


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
	for enemy in _nearby_enemies(900.0):
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
	var enemy = _visible_enemy(AWARENESS_RADIUS)
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
	for enemy in _nearby_enemies(SCAN_RADIUS * 1.2):
		var alignment: float = _flank_alignment(enemy)
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


func _pick_rescue_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var casualty = _nearest_downed_ally(RESCUE_SCAN_RADIUS)
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
	for enemy in _nearby_enemies(900.0):
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
	for enemy in _nearby_enemies(900.0):
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
