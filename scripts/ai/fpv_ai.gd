# FPV 自杀无人机的决策层：锁定 -> 俯冲两步（M13）。
# DroneAI 是"往哪儿飞"的 Utility 选择；FPV 没得选——锁定最近敌人直线俯冲，
# 贴到 16px 内拉信管。它的全部智能是"挑最值得撞的那个"，
# 以及目标没了别把炸药浪费在尸体上。
class_name FPVAI
extends Node

## 锁定节拍（秒），比 DroneAI 的 0.4 快一倍：俯冲窗口本来就短，
## "目标死了换下一个"最多迟 0.2 秒——刺刀等不起。
const THINK_INTERVAL := 0.2

## 撞针引爆距离（像素）：贴到这么近就拉信管——爆炸半径 40 足够罩住目标。
const DETONATE_RADIUS := 16.0

var _drone = null
var _think_timer: float = 0.0


func _ready() -> void:
	_wire()


func _wire() -> void:
	_drone = get_parent()


func _physics_process(delta: float) -> void:
	if _drone == null or _drone.get("is_dead") == true:
		return
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_think()
	_act()


## 锁定：目标还活着就继续撞；目标没了（阵亡/倒地/被俘/被挪走）才重新扫描。
## 扫描**不过滤距离**——FPV 操作员的屏幕就是它的眼睛，全场最近者即目标
## （侦察机的 260px 侦察半径管不到它：它本来就是来贴脸的）。
## 没有敌人就悬停：target 置空、is_diving 翻 false，机体的 _fly_step 自然停转。
func _think() -> void:
	if _target_alive(_drone.get("target")):
		return
	var next = _nearest_enemy()
	_drone.set("target", next)
	_drone.set("is_diving", next != null)


## 俯冲的位移由机体自己的 _fly_step 完成（同侦察机的分工：AI 只发指令）。
## 这里每帧只做一件事——贴到 DETONATE_RADIUS 就引爆：
## 距离读数只在贴脸的那一帧有意义，这一步不能等思考节拍。
func _act() -> void:
	var target = _drone.get("target")
	if not _target_alive(target):
		# 目标没了：别把炸药浪费在尸体上，等下一个思考节拍换下一个最近敌人。
		return
	var to_target: Vector2 = target.global_position - _drone.global_position
	if to_target.length() <= DETONATE_RADIUS:
		_drone.call("explode")


## 目标是否还撞得：活着（没阵亡）、站着（没倒地）、还在战斗（没被俘）。
## 过滤写法与 drone.scan_now 同款——侦察机的眼睛和 FPV 的准星认同一套敌人；
## FPV 自己队的侦察机/坦克是队友不是猎物（同队过滤）。
func _target_alive(target) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target.get("is_dead") == true or target.get("is_downed") == true:
		return false
	return target.get("is_captive") != true


## 最近的敌方士兵/坦克（soldiers + vehicles 两组）。距离不设上限，
## 也不做通视判定——它从头顶过，墙挡得住子弹挡不住俯冲。
func _nearest_enemy():
	var best = null
	var best_dist: float = INF
	var my_team: int = int(_drone.get("team"))
	for group_name in [&"soldiers", &"vehicles"]:
		for unit in get_tree().get_nodes_in_group(group_name):
			if unit == _drone or int(unit.get("team")) == my_team:
				continue
			if not _target_alive(unit):
				continue
			# 侦察机不撞：它飞得快、撞不着，还是双方的眼睛——
			# has_method("scan_now") 是它的鸭子标记（士兵/坦克/FPV 都没有）。
			if unit.has_method("scan_now"):
				continue
			var distance: float = _drone.global_position.distance_to(unit.global_position)
			if distance < best_dist:
				best_dist = distance
				best = unit
	return best
