# 无人机的决策层：Utility 两选一（盯梢 / 巡逻）。
# 没有交战项——侦察无人机不带武器，它的全部价值是把敌人位置喂给黑板；
# 宏观命令也不掺和（hold 让步兵蹲坑，没道理把天上的眼睛收回来）。
class_name DroneAI
extends Node

## 思考节拍。与士兵 0.25s、坦克 0.4s 各记各的账。
## 与坦克同理，故意不复用"按累计时间把账花掉"的欠账机制：
## 丢 0.1 秒思考对一架只决定"往哪儿飞"的无人机没有任何后果。
const THINK_INTERVAL := 0.4

## 行为粘性，防分数在门槛附近每 tick 抖一次。
const STICKINESS := 0.15

## 盯梢盘旋半径：不远不近——贴脸暴露，离远了看不清。取 SPOT_RADIUS 的一半不到。
const ORBIT_RADIUS := 120.0

## 目击保鲜期，与 drone.gd 的 SPOT_STALE 保持一致（刻意复制而非跨类引用，
## 与 tank_ai 的 ENGAGE_RANGE 同一条约定）。
const SPOT_STALE := 1.2

## 巡逻航点（世界坐标，由生成方在入树前写入）。空数组 = 原地悬停。
var waypoints: Array[Vector2] = []

var _drone = null
var _utility := UtilityAI.new()
var _think_timer: float = 0.0
var _action: StringName = &"patrol"
## 初始 -1：_act_patrol 先自增再取航点，-1 保证首飞去 waypoints[0] 而不是跳到 [1]。
var _waypoint_index: int = -1
var _orbit_angle: float = 0.0


func _ready() -> void:
	_wire()


func _wire() -> void:
	_drone = get_parent()
	if _drone == null:
		return
	# 注册顺序即平局优先级（UtilityAI 用严格 > 比较）：
	# 盯梢 1.0 > 巡逻 0.4。目击一丢（输入归零），巡逻的保底分就接管。
	_utility.register_consideration(
		&"track", _track_input, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)
	_utility.register_consideration(
		&"patrol", _patrol_input, 0.0, 1.0, 0.4, UtilityAI.CurveType.LINEAR
	)
	_utility.stickiness = STICKINESS


## 有新鲜目击才有资格盯梢；输入按目击新鲜度线性衰减。
func _track_input() -> float:
	if _drone == null:
		return 0.0
	var age: float = float(_drone.get("spot_age"))
	if age >= SPOT_STALE:
		return 0.0
	return 1.0 - age / SPOT_STALE


## 巡逻输入恒为 1：它的权重 0.4 就是"没别的事可做时的保底分"。
func _patrol_input() -> float:
	return 1.0


func _physics_process(delta: float) -> void:
	if _drone == null or _drone.get("is_dead") == true:
		return
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_think()
	_act()


func _think() -> void:
	_action = _utility.evaluate(_action)
	_drone.set("action", _action)


func _act() -> void:
	match _action:
		&"track":
			_act_track()
		_:
			_act_patrol()


## 盯梢：绕最近目击位置转六边形圈——不是飞过去贴脸，是挂着看。
## 每抵达一个角才换下一个（60°），航段 120px 用时约 1.1s，圈是稳的；
## latest_spot 每次侦察都在刷新，敌人挪窝，圈心跟着挪。
func _act_track() -> void:
	var spot: Vector2 = _drone.get("latest_spot")
	if _drone.call("has_arrived"):
		_orbit_angle += TAU / 6.0
		_drone.call("fly_to", spot + Vector2(ORBIT_RADIUS, 0.0).rotated(_orbit_angle))


## 巡逻：沿航点循环，抵达即切下一个。航点没配就地悬停。
func _act_patrol() -> void:
	if waypoints.is_empty():
		_drone.call("stop_moving")
		return
	if _drone.call("has_arrived"):
		_waypoint_index = (_waypoint_index + 1) % waypoints.size()
		_drone.call("fly_to", waypoints[_waypoint_index])


## 最近一次 evaluate 的得分，供测试与调试读取。
func scores() -> Dictionary:
	return _utility.last_scores.duplicate()


func last_action() -> StringName:
	return _utility.last_action
