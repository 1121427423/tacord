# 补给卡车（M15）：每队一辆，往返于地图边缘的"车库"与最近的建成 FOB 之间，
# 每趟给 FOB 半径内的己方士兵发一匣弹药。原简介：每建成一座 FOB 都会铺出
# 一条通往防线的道路，补给卡车随即往返运输——卡车可能遭到伏击，一旦被打掉，
# "活水"就断了，断点之后的阵地只能吃存量（FOB 站桩补弹是另一条独立通道）。
#
# 本体与决策合一（不拆 AI 节点）：往返运输是五态固定流程，没有效用打分，
# 拆出 TruckAI 纯属仪式。game.gd 公开方法已 20/20 顶格，"FOB 建成触发首发"
# 不能靠它接线——卡车自己每帧看一眼有没有建成的己方 FOB，语义等价且零接线。
class_name Truck
extends CharacterBody2D

## 载具身段三条（同坦克/侦察机/FPV）：vehicles 组、不进 soldiers、
## 恒 false 双项——perception 的敌人过滤与救援/押送/帐篷/补弹逻辑原样复用。
const GROUP := &"vehicles"

## 卸货半径（像素）：卡车停在 FOB 旁这一段内，就算"到了"。
## 与 build_site 的治疗光环、PLAN 的约定对齐。
const UNLOAD_RADIUS := 96.0

## 每趟每个兵发的备弹数（一匣的量）。
const CARGO_PER_RUN := 24

## 断链自检：连续这么久没挪动（且没到站）就认定路被截断，趴窝等重试。
const STALL_TIMEOUT := 1.5

## 趴窝后的重试间隔（秒）：工事被打掉后 A* 恢复可走，最多隔这么久重新出发。
const RETRY_INTERVAL := 1.0

const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),
	2: Color(1.0, 0.427, 0.345),
}

@export var team: int = 1
@export var max_hp: int = 60

## 车速（像素/秒）。做成导出项：演示局用默认值，测试可以调快省帧预算。
@export var move_speed: float = 45.0

## 回车库后歇多久再发下一班（秒）。同款做成导出项给测试调短。
@export var depart_rest: float = 6.0

## 车库格（地图边缘的出发点/归宿）。由 spawn 方设置。
var home_cell := Vector2i(0, 12)

var hp: int = 60
var is_dead: bool = false

## 载具身段：不会倒地、不能被俘（perception 的过滤对每个候选都读这两项）。
var is_downed: bool = false
var is_captive: bool = false
var facing: Vector2 = Vector2.RIGHT
var current_order: String = "hold"

## 卡车不吃压制：恒 0，且故意不提供 apply_suppression——
## weapon.gd 的近失压制先 has_method 再调用，子弹擦过车厢攒不起来。
var suppression: float = 0.0

## 断链读数（M15 的核心可观测状态）：路被新工事截断时 true，重试成功后归位。
## HUD 与测试直接读——公开变量不占 gdlint 的公开方法额度。
var is_stalled: bool = false

## 当前班次状态：docked（车库待命/歇班）/ outbound（去 FOB）/ unload（卸货）
## / returning（回车库）/ destroyed。HUD 显示用。
var action: StringName = &"docked"

var _map = null
var _path := PackedVector2Array()
var _path_index: int = 0
var _dest_cell := Vector2i(-1, -1)
var _target_site = null
var _delivered: bool = false
var _rest_timer: float = 0.0
var _retry_timer: float = 0.0
var _last_pos := Vector2.ZERO
var _stuck_time: float = 0.0


func _ready() -> void:
	hp = max_hp
	add_to_group(GROUP)
	_map = get_tree().get_first_node_in_group(&"battle_map")
	if _map == null:
		push_warning("Truck: 场景中没有 BattleMap（group: battle_map），无法往返。")
	_last_pos = global_position
	queue_redraw()


## 宏观命令照收但不改行为：补给线是后勤，不归战术命令管。
func set_order(order: String) -> void:
	current_order = order
	queue_redraw()


## 挨打：没有装甲——驾驶室和货舱都是薄铁皮，步枪弹 12 点就是 12 点。
## 五发正好打掉一辆（60 血）。
func take_damage(amount: int) -> void:
	if is_dead:
		return
	hp = maxi(hp - amount, 0)
	queue_redraw()
	if hp <= 0:
		die()


## 断供：卡车被打掉，这条"活水"就没了——FOB 站桩补弹照旧，
## 但卡车班次带来的增量从此停止，断点之后的阵地只能吃存量。
func die() -> void:
	if is_dead:
		return
	is_dead = true
	is_stalled = false
	action = &"destroyed"
	stop_moving()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
	_tick_state(delta)
	_follow_path()
	_tick_stuck(delta)


# ---------------------------------------------------------------- 状态机


## 班次循环：docked -> outbound -> unload -> returning -> docked。
## docked 时每帧看一眼有没有建成的己方 FOB——"建成即发车"不用谁来通知，
## 也省掉一整条信号接线（game.gd 的公开方法已经 20/20 顶格，接不进去）。
func _tick_state(delta: float) -> void:
	match action:
		&"docked":
			if _rest_timer > 0.0:
				_rest_timer = maxf(0.0, _rest_timer - delta)
				return
			var site = _nearest_fob()
			if site == null:
				return
			if not _depart_to(site):
				return
			action = &"outbound"
		&"outbound":
			# 途中的 FOB 可能被敌人打掉（queue_free）：目标没了就折返，
			# 摸已释放的 site 会崩协程——先验存活再谈抵达。
			if _target_site == null or not is_instance_valid(_target_site):
				if _head_home():
					action = &"returning"
				else:
					action = &"returning"
					_stall_now()
				return
			if _arrived_at_fob():
				_unload()
				action = &"unload"
		&"unload":
			# 卸货是瞬时的（MVP）：货一落地就折返，不在火线多停一秒。
			if _head_home():
				action = &"returning"
			else:
				# 回程被新工事堵死：与去程同款趴窝（action 保持 returning，
				# _stall_now 只把 docked 翻成 outbound，不影响这里）。
				action = &"returning"
				_stall_now()
		&"returning":
			if _arrived_home():
				action = &"docked"
				_rest_timer = depart_rest
				_delivered = false
				_target_site = null
		_:
			pass


## 发车：挑 FOB 周围能落脚的格子（FOB 本身建成后是 blocked，A* 进不去），
## 沿 A* 铺路。找不到路（或没有可走邻格）返回 false，车库原地再等一轮。
func _depart_to(site) -> bool:
	var dest := _landing_cell(site)
	if dest == Vector2i(-1, -1):
		return false
	if not _move_to_cell(dest):
		# 首发就被堵死：与途中断链同款处理，趴窝等重试。
		_dest_cell = dest
		_target_site = site
		_stall_now()
		return true
	_dest_cell = dest
	_target_site = site
	return true


## FOB 附近两圈内最近的可走落脚格；没有则 (-1,-1)。
func _landing_cell(site) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist: float = INF
	for cell in _map.call("cells_in_radius", site.cell, 2):
		if not bool(_map.call("is_walkable", cell)):
			continue
		var dist: float = (
			_map.call("world_pos", cell).distance_to(global_position)
		)
		if dist < best_dist:
			best_dist = dist
			best = cell
	return best


## 最近的己方建成 FOB；没有则 null（多座时每趟出发现挑——上一趟卸过的
## 工事可能已经没了，选择不缓存）。
func _nearest_fob():
	var best = null
	var best_dist: float = INF
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != team:
			continue
		if not site.has_method("is_supply_point") or not bool(site.call("is_supply_point")):
			continue
		var dist: float = global_position.distance_to(site.global_position)
		if dist < best_dist:
			best_dist = dist
			best = site
	return best


## 卸货：给 FOB 半径内每个还活着的己方士兵的武器补一匣备弹。
## 只补 soldiers 组——坦克/无人机的弹药是另一本账，不归这趟车。
func _unload() -> void:
	if _delivered or _target_site == null or not is_instance_valid(_target_site):
		return
	_delivered = true
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) != team or unit.get("is_dead") == true:
			continue
		if unit.global_position.distance_to(_target_site.global_position) > UNLOAD_RADIUS:
			continue
		var unit_weapon = unit.get("weapon")
		if unit_weapon != null and unit_weapon.has_method("add_reserve"):
			unit_weapon.call("add_reserve", CARGO_PER_RUN)


func _arrived_at_fob() -> bool:
	if _target_site == null:
		return false
	return global_position.distance_to(_target_site.global_position) <= UNLOAD_RADIUS


func _arrived_home() -> bool:
	return global_position.distance_to(_map.call("world_pos", home_cell)) <= 6.0


func _head_home() -> bool:
	return _move_to_cell(home_cell)


# ---------------------------------------------------------------- 寻路与趴窝


## 沿 A* 铺路（与士兵/坦克同一张图、同一套 find_path）。失败返回 false。
func _move_to_cell(cell: Vector2i) -> bool:
	if _map == null:
		return false
	var from: Vector2i = _map.call("cell_at", global_position)
	var cells: Array = _map.call("find_path", from, cell)
	if cells.is_empty():
		return false
	var world_path := PackedVector2Array()
	for path_cell in cells:
		world_path.append(_map.call("world_pos", path_cell))
	_path = world_path
	_path_index = 0
	return true


func stop_moving() -> void:
	_path = PackedVector2Array()
	_path_index = 0
	velocity = Vector2.ZERO


## 断链：路被新工事截断（A* 无路，或旧路径上多出一堵实体墙把车顶住）。
## 趴窝在断点，每 RETRY_INTERVAL 秒重试一次——工事被打掉、A* 恢复可走
## 的那一刻，最多隔这么久就重新出发。
func _stall_now() -> void:
	is_stalled = true
	stop_moving()
	_stuck_time = 0.0
	_retry_timer = RETRY_INTERVAL
	if action == &"docked":
		action = &"outbound"


## 位移自检：在路上（outbound/returning）却长时间没挪动 = 被墙顶住了。
## A* 是铺路时一次性的，新盖的工事不会通知旧路径——车自己发现走不动才算断。
func _tick_stuck(delta: float) -> void:
	if is_stalled:
		_retry_timer -= delta
		if _retry_timer > 0.0:
			return
		_retry_timer = RETRY_INTERVAL
		var dest := _dest_cell
		if action == &"returning":
			dest = home_cell
		if _move_to_cell(dest):
			is_stalled = false
			_stuck_time = 0.0
		return
	if action != &"outbound" and action != &"returning":
		_last_pos = global_position
		_stuck_time = 0.0
		return
	if global_position.distance_to(_last_pos) < 2.0:
		_stuck_time += delta
		if _stuck_time >= STALL_TIMEOUT:
			_stall_now()
	else:
		_stuck_time = 0.0
	_last_pos = global_position


func _follow_path() -> void:
	if _path_index >= _path.size():
		velocity = Vector2.ZERO
		return
	var target: Vector2 = _path[_path_index]
	var to_target: Vector2 = target - global_position
	var distance: float = to_target.length()
	if distance <= 3.0:
		_path_index += 1
		if _path_index >= _path.size():
			stop_moving()
		return
	var direction: Vector2 = to_target / distance
	facing = direction
	velocity = direction * move_speed
	move_and_slide()


func _draw() -> void:
	if is_dead:
		# 残骸：翻倒的货厢，给战场一个交代（断供的痕迹）。
		draw_rect(Rect2(-14.0, -9.0, 28.0, 18.0), Color(0.13, 0.12, 0.12, 0.7), true)
		draw_line(Vector2(-8.0, -6.0), Vector2(8.0, 6.0), Color(0.05, 0.05, 0.05, 0.8), 2.0)
		return
	var tint: Color = TEAM_COLORS.get(team, Color.GRAY)
	# 车厢：横向长盒（比坦克更扁长），一眼读出"这是运东西的"。
	draw_rect(Rect2(-14.0, -8.0, 28.0, 16.0), Color(tint, 0.30), true)
	draw_rect(Rect2(-14.0, -8.0, 28.0, 16.0), tint, false, 2.0)
	# 货舱条纹：三条竖线，和炮塔的"武器载具"一眼分开。
	for x in [-8.0, 0.0, 8.0]:
		draw_line(Vector2(x, -6.0), Vector2(x, 6.0), Color(tint, 0.5), 2.0)
	# 趴窝标记：断链时车顶画一个叹号框——HUD 之外战场也能看见。
	if is_stalled:
		draw_rect(Rect2(-3.0, -18.0, 6.0, 6.0), Color(1.0, 0.75, 0.2, 0.9), false, 1.5)
		draw_rect(Rect2(-0.75, -17.0, 1.5, 3.0), Color(1.0, 0.75, 0.2))
		draw_rect(Rect2(-0.75, -13.2, 1.5, 1.5), Color(1.0, 0.75, 0.2))
	# 血条挂在头顶，与士兵/坦克/工地同一套画法。
	var ratio: float = clampf(float(hp) / float(maxi(max_hp, 1)), 0.0, 1.0)
	draw_rect(Rect2(-14.0, -15.0, 28.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	draw_rect(Rect2(-14.0, -15.0, 28.0 * ratio, 3.0), Color(0.32, 0.88, 0.45))
