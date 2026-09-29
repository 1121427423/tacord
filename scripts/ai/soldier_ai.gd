# 士兵 AI：Utility AI 决定“做什么”（找掩体/推进/包抄/待命），行为树负责“怎么做”。
class_name SoldierAI
extends Node

signal action_changed(previous: StringName, current: StringName)

const ACTION_SEEK_COVER := &"seek_cover"
const ACTION_ADVANCE := &"advance"
const ACTION_FLANK := &"flank"
const ACTION_HOLD := &"hold"

## 命令优先级：宏观命令通过它影响效用打分，士兵仍然自己决定怎么执行。
const ORDER_PRIORITY := {
	"attack": 1.0,
	"flank": 0.8,
	"defend": 0.35,
	"hold": 0.15,
	"retreat": 0.0,
}

const SCAN_RADIUS := 360.0  # 感知半径（像素）
const COVER_SCAN_CELLS := 6  # 找掩体时的搜索半径（格）
const ARRIVAL_EPSILON := 3.0

## AI 思考间隔（秒）。单位数量上去后可调大以省 CPU（Web 导出尤其明显）。
@export var think_interval: float = 0.25

## 行为粘性：传给 UtilityAI，防止分数抖动导致反复横跳。
@export var stickiness: float = 0.15

var soldier: CharacterBody2D = null

# BattleMap（battle_map.gd）。故意不标注类型：GDScript 对静态类型的接收者会拒绝调用
# 自定义方法，这里需要鸭子调用 cell_at / find_cover_cell / has_line_of_sight 等接口。
var map = null

# Weapon 组件（soldier 的子节点），同样不标注类型。
var weapon = null

var utility: UtilityAI = UtilityAI.new()

var _trees: Dictionary = {}  # StringName -> 行为树根节点
var _action: StringName = ACTION_HOLD
var _move_started: bool = false
var _think_accum: float = 0.0
var _rng := RandomNumberGenerator.new()


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
	_rng.seed = hash(soldier.name)
	utility.stickiness = stickiness
	_register_considerations()
	_build_trees()
	# 打散各单位的思考相位，避免所有 AI 挤在同一帧。
	_think_accum = _rng.randf_range(0.0, think_interval)


func _process(delta: float) -> void:
	if soldier == null or soldier.get("is_dead") == true:
		return
	# 交战是"反射"，每帧处理；战术决策按 think_interval 处理。
	_combat_step()
	_think_accum += delta
	if _think_accum < think_interval:
		return
	_think_accum = 0.0
	_think()


## 自动索敌开火：有通视、在射程内的最近敌人即为目标。
## 放在 AI 层而不是 soldier 里，是为了让 M2 的压制能够直接卡住这一步。
func _combat_step() -> void:
	if weapon == null:
		return
	var target = _acquire_target()
	if target == null:
		return
	var target_pos: Vector2 = target.global_position
	soldier.call("aim_at", target_pos)
	soldier.call("try_fire", target_pos)


## 射程内、且有通视的最近敌人；没有则返回 null。
func _acquire_target():
	if soldier == null or map == null:
		return null
	var reach: float = float(soldier.call("weapon_range"))
	if reach <= 0.0:
		return null
	var best = null
	var best_dist: float = reach
	for enemy in _nearby_enemies(reach):
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


func _consider_seek_cover() -> float:
	var danger: float = _danger_pressure()
	var wounded: float = 1.0 - _health_ratio()
	return clampf(danger * 0.75 + wounded * 0.45, 0.0, 1.0)


func _consider_advance() -> float:
	return clampf(_order_priority() * _health_ratio(), 0.0, 1.0)


func _consider_flank() -> float:
	return clampf(_flank_opportunity() * _health_ratio() * 1.15, 0.0, 1.0)


func _consider_hold() -> float:
	# 命令越明确，待命越没有吸引力。
	return clampf(0.6 - 0.4 * _order_priority(), 0.0, 1.0)


# ---------------------------------------------------------------- 感知


func _health_ratio() -> float:
	if soldier == null:
		return 0.0
	var max_hp: float = maxf(1.0, float(soldier.get("max_hp")))
	return clampf(float(soldier.get("hp")) / max_hp, 0.0, 1.0)


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
		if unit.get("is_dead") == true:
			continue
		if soldier.global_position.distance_to(unit.global_position) <= radius:
			out.append(unit)
	return out


func _nearest_enemy(radius: float):
	var best = null
	var best_dist: float = radius
	for unit in _nearby_enemies(radius):
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


func _pick_advance_target(_ctx: Dictionary, _delta: float) -> int:
	if map == null:
		return BehaviorTree.Status.FAILURE
	var enemy = _nearest_enemy(1e9)
	if enemy == null:
		return BehaviorTree.Status.FAILURE
	# 推进落点：贴近敌人但保留 2 格开火距离，并在落点周围挑掩体质量最好的格子。
	var to_enemy: Vector2 = (enemy.global_position - soldier.global_position).normalized()
	var standoff: Vector2 = enemy.global_position - to_enemy * float(map.cell_size) * 2.0
	var cell: Vector2i = _best_cell_around(map.cell_at(standoff), 3)
	if cell.x < 0 or not _start_move(cell):
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
