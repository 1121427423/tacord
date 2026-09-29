# 建筑工地：士兵走过来施工，建成后变成实体掩体 / FOB。子弹能把它打掉。
class_name BuildSite
extends StaticBody2D

signal build_finished(site: BuildSite)
signal destroyed(site: BuildSite)

## 物理层：2 = 静态障碍。与 battle_map.gd / weapon.gd 保持一致，
## 这样建成后 weapon 的射线（mask 含第 2 层）会自动打到它并调用 take_damage。
const LAYER_OBSTACLES := 2

## 建成后占据的地形：沙袋是 cover（挡视线、可当掩体），FOB 与医疗帐篷是 blocked
## ——帐篷是撑起来的帆布包，人进不去、子弹和视线也过不去，和实体工事一个道理。
const KIND_TERRAIN := {
	&"fob": &"blocked",
	&"sandbag": &"cover",
	&"tent": &"blocked",
}

const KIND_LABELS := {&"fob": "FOB", &"sandbag": "沙袋", &"tent": "医疗帐篷"}

## 医疗帐篷（M9）：建成后的治疗光环。只治己方还站着的人——
## 倒地的必须由队友拖救，帐篷不代劳，否则 M3 那条"拖救"链就成了摆设。
const TENT_HEAL_RADIUS := 96.0
const TENT_HEAL_PER_SECOND := 6.0

## 未知种类退化成完全阻挡。
const TERRAIN_FALLBACK := &"blocked"

const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),
	2: Color(1.0, 0.427, 0.345),
}

@export var kind: StringName = &"fob"
@export var team: int = 1

## 建成需要多少"人·秒"工时。多人同时施工会叠加。
@export var build_cost: float = 6.0
@export var max_hp: int = 200

var build_progress: float = 0.0
var is_built: bool = false
var hp: int = 200
var cell := Vector2i(-1, -1)

# BattleMap（battle_map.gd）。不标注类型以便鸭子调用 set_terrain。
var battle_map = null

var _shape: CollisionShape2D = null


func _ready() -> void:
	hp = max_hp
	add_to_group(&"build_sites")
	battle_map = get_tree().get_first_node_in_group(&"battle_map")
	# 施工中不挡路也不挡子弹：士兵得能走到工地上干活。
	collision_layer = 0
	collision_mask = 0
	_shape = CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28.0, 28.0)
	_shape.shape = rect
	add_child(_shape)
	queue_redraw()


## 推进施工进度；返回 true 表示这一次调用刚好建成。
func apply_labor(delta: float, multiplier: float = 1.0) -> bool:
	if is_built:
		return false
	build_progress = minf(build_progress + delta * maxf(0.1, multiplier), build_cost)
	queue_redraw()
	if build_progress < build_cost:
		return false
	_finish_build()
	return true


func _finish_build() -> void:
	is_built = true
	collision_layer = LAYER_OBSTACLES
	# 建成即成为实体障碍：必须同步告诉 A*，否则士兵会规划出穿墙路径
	# （M1 踩过这个坑：cover 地形可走导致士兵卡在墙上）。
	if battle_map != null and battle_map.has_method("set_terrain"):
		battle_map.call("set_terrain", cell, StringName(KIND_TERRAIN.get(kind, TERRAIN_FALLBACK)))
	build_finished.emit(self)
	queue_redraw()


## 挨打。施工中只是一堆建材，打不出效果（MVP 简化）。
func take_damage(amount: int) -> void:
	if not is_built:
		return
	hp = maxi(hp - amount, 0)
	queue_redraw()
	if hp <= 0:
		_demolish()


func _demolish() -> void:
	collision_layer = 0
	if battle_map != null and battle_map.has_method("set_terrain"):
		battle_map.call("set_terrain", cell, &"open")
	destroyed.emit(self)
	queue_free()


## 建成的医疗帐篷是否是治疗点（与 is_supply_point 对仗，供测试与 AI 查询）。
func is_medical_point() -> bool:
	return is_built and kind == &"tent"


func build_ratio() -> float:
	if build_cost <= 0.0:
		return 1.0
	return clampf(build_progress / build_cost, 0.0, 1.0)


## 只有建成的 FOB 才是弹药补给点。
func is_supply_point() -> bool:
	return is_built and kind == &"fob"


func label() -> String:
	return String(KIND_LABELS.get(kind, String(kind)))


## 帐篷的光环是它自己的事：每帧由它去认领附近的伤员，而不是让每个士兵
## 都去扫一遍全图的工地（士兵这边的扫描留给 M5 的 _try_resupply，互不干扰）。
func _physics_process(delta: float) -> void:
	if not is_built or kind != &"tent":
		return
	var my_team: int = team
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) != my_team:
			continue
		if unit.get("is_dead") == true or unit.get("is_downed") == true:
			continue
		if unit.get("is_captive") == true:
			continue
		if unit.global_position.distance_to(global_position) > TENT_HEAL_RADIUS:
			continue
		var hp_now: float = float(unit.get("hp"))
		var hp_max: float = float(unit.get("max_hp"))
		if hp_now >= hp_max:
			continue
		# 直接写 hp：治疗不是伤害，不走 take_damage，也不产生失血账。
		unit.set("hp", int(minf(hp_max, hp_now + TENT_HEAL_PER_SECOND * delta)))


func _draw() -> void:
	var tint: Color = TEAM_COLORS.get(team, Color.GRAY)
	if not is_built:
		# 工地：虚线方框 + 按进度填充的底色。
		draw_rect(Rect2(-14.0, -14.0, 28.0, 28.0), Color(tint, 0.18 + 0.4 * build_ratio()), true)
		draw_rect(Rect2(-14.0, -14.0, 28.0, 28.0), Color(tint, 0.9), false, 1.0)
		draw_rect(Rect2(-14.0, 10.0, 28.0 * build_ratio(), 3.0), Color(0.95, 0.8, 0.3))
		return
	draw_rect(Rect2(-14.0, -14.0, 28.0, 28.0), Color(tint, 0.55), true)
	draw_rect(Rect2(-14.0, -14.0, 28.0, 28.0), Color(tint, 1.0), false, 2.0)
	if kind == &"fob":
		# 旗杆 + 旗面，一眼能认出这是 FOB。
		draw_line(Vector2(0.0, 8.0), Vector2(0.0, -12.0), Color.WHITE, 1.5)
		draw_rect(Rect2(0.0, -12.0, 10.0, 6.0), Color(tint, 1.0))
	elif kind == &"tent":
		# 医疗帐篷：白底红十字 + 圆顶轮廓，和 FOB 的旗子一眼分得开。
		draw_circle(Vector2(0.0, 0.0), 10.0, Color(0.96, 0.96, 0.96, 0.9))
		draw_arc(Vector2(0.0, 0.0), 10.0, 0.0, TAU, 24, Color(tint, 1.0), 2.0)
		draw_rect(Rect2(-5.0, -1.5, 10.0, 3.0), Color(0.9, 0.25, 0.25))
		draw_rect(Rect2(-1.5, -5.0, 3.0, 10.0), Color(0.9, 0.25, 0.25))
	var ratio: float = clampf(float(hp) / maxf(1.0, float(max_hp)), 0.0, 1.0)
	draw_rect(Rect2(-14.0, -20.0, 28.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	draw_rect(Rect2(-14.0, -20.0, 28.0 * ratio, 3.0), Color(0.32, 0.88, 0.45))
