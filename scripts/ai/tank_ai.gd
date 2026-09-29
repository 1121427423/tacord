# 装甲车的决策层：Utility AI 三选一（交战 / 推进 / 待命），执行只有两行。
# 不用行为树——士兵要编排"接近→瞄准→开火→换弹"的多步序列才需要 BT，
# 坦克是"看见就停炮、看不见就开过去"，Utility 选完直接执行就是全部逻辑。
class_name TankAI
extends Node

## 思考节拍。与士兵的 0.25s 错开，各记各的账。
## 这里**故意不复用** soldier_ai 那笔"按累计时间把账花掉"的欠账机制：
## 坦克的思考只决定"停还是走"，丢 0.1 秒没有任何后果。
const THINK_INTERVAL := 0.4

## 行为粘性，防分数在门槛附近每 tick 抖一次。
const STICKINESS := 0.15

## 交战判定半径。与 tank.tscn 里 Weapon 的 max_range 保持一致（380），
## 坦克不会对着射程外的目标白转炮塔。
const ENGAGE_RANGE := 380.0

## 宏观命令 -> 推进意愿。口径与 perception.gd 的 ORDER_PRIORITY 一致，
## 这样"防守"在士兵那边是半推半就，在坦克这边就干脆不挪窝。
const ORDER_PRIORITY := {
	"attack": 1.0,
	"flank": 0.8,
	"defend": 0.35,
	"hold": 0.15,
	"retreat": 0.0,
}
const DEFAULT_ORDER_PRIORITY := 0.15

var _tank = null
var _perc = null
var _utility := UtilityAI.new()
var _think_timer: float = 0.0
var _action: StringName = &"hold"
var _wired: bool = false


func _ready() -> void:
	# 子节点的 _ready 先于父节点跑，此刻坦克的 weapon 还没接线——
	# 推迟一帧再装配，装配失败会在下一帧重试（避免依赖 _ready 顺序）。
	call_deferred("_wire")


func _wire() -> void:
	_tank = get_parent()
	if _tank == null:
		return
	# 载具的 weapon 由 Tank._ready 赋值，deferred 之后一定就位了。
	var weapon = _tank.get("weapon")
	if weapon == null:
		return
	_perc = Perception.new()
	_perc.setup(
		_tank, _tank.get_tree().get_first_node_in_group(&"battle_map"), weapon, _tank.get_tree()
	)
	# 注册顺序即平局优先级（UtilityAI 用严格 > 比较）：
	# 交战 1.0 > 推进 0.6×命令 > 待命 0.25。
	_utility.register_consideration(
		&"engage", _engage_input, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)
	_utility.register_consideration(
		&"advance", _advance_input, 0.0, 1.0, 0.6, UtilityAI.CurveType.LINEAR
	)
	_utility.register_consideration(
		&"hold", _hold_input, 0.0, 1.0, 0.25, UtilityAI.CurveType.LINEAR
	)
	_utility.stickiness = STICKINESS
	_wired = true


func _physics_process(delta: float) -> void:
	if _tank == null or _tank.get("is_dead") == true:
		return
	if not _wired:
		return
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_think()
	_act()


## 有通视且在射程内的敌人才算"能交战"。visible_enemy 内部已经做了
## LOS 与半径双重过滤，这里不再重复判断一遍距离。
func _engage_input() -> float:
	return 1.0 if _nearest_visible() != null else 0.0


func _advance_input() -> float:
	if _tank == null:
		return 0.0
	var order: String = String(_tank.get("current_order"))
	return float(ORDER_PRIORITY.get(order, DEFAULT_ORDER_PRIORITY))


## 待命输入恒为 1：它的权重 0.25 就是"没别的事可做时的保底分"。
## 命令是防守/待命时 0.6×0.35=0.21 < 0.25，坦克就钉在原地。
func _hold_input() -> float:
	return 1.0


func _nearest_visible():
	if _perc == null:
		return null
	return _perc.visible_enemy(ENGAGE_RANGE)


func _think() -> void:
	_action = _utility.evaluate(_action)
	_tank.set("action", _action)


func _act() -> void:
	match _action:
		&"engage":
			# 停车射击：炮手要的是稳定平台，边走边打是步兵的事。
			_tank.call("stop_moving")
			var target = _nearest_visible()
			var weapon = _tank.get("weapon")
			if target != null and weapon != null:
				# 射速、换弹、冷却全在 weapon 里，这里每帧推一下就行。
				weapon.call("try_fire", target.global_position)
		&"advance":
			_act_advance()
		_:
			_tank.call("stop_moving")


## 推进：目标没设定就地待命；走到头就重新领一段路。
## 走到一半不重新 find_path——那是 move_to_cell 自己的事（A* 只在起点算一次）。
func _act_advance() -> void:
	var objective: Vector2i = _tank.get("objective")
	if objective.x < 0 or objective.y < 0:
		_tank.call("stop_moving")
		return
	if _tank.call("has_arrived"):
		_tank.call("move_to_cell", objective)


## 最近一次 evaluate 的得分，供测试与调试读取。
func scores() -> Dictionary:
	return _utility.last_scores.duplicate()


func last_action() -> StringName:
	return _utility.last_action
