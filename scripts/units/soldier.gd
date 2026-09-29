# 士兵实体（CharacterBody2D）：移动、HP、命令状态与占位外观；AI 由子节点 SoldierAI 驱动。
class_name Soldier
extends CharacterBody2D

signal died(unit: CharacterBody2D)
signal health_changed(current: int, maximum: int)
signal order_changed(order: String)

## 物理层：1 = 单位，2 = 静态障碍。与 battle_map.gd 保持一致。
const LAYER_UNITS := 1
const LAYER_OBSTACLES := 2

const ARRIVAL_TOLERANCE := 3.0
const TRACER_DURATION := 0.08
const HIT_FLASH_DURATION := 0.12
const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),  # 蓝方
	2: Color(1.0, 0.427, 0.345),  # 红方
}

@export var hp: int = 100
@export var max_hp: int = 100
@export var move_speed: float = 80.0
@export var team: int = 1  # 1 = 蓝方，2 = 红方
@export var current_order: String = "hold"

var is_dead: bool = false

## 单位朝向（单位向量）。AI 用它判断谁把侧翼暴露给了谁。
var facing: Vector2 = Vector2.RIGHT

# BattleMap（battle_map.gd），不标注类型以便鸭子调用其查询接口。
var battle_map = null

var _path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _target_cell := Vector2i(-1, -1)
var _tracer: Array = []  # [起点, 终点]（世界坐标）
var _tracer_ttl: float = 0.0
var _hit_flash_ttl: float = 0.0

# SoldierAI 子节点。不标注类型，避免与 scripts/ai/soldier_ai.gd 形成脚本循环依赖。
@onready var ai = $SoldierAI

# 占位外观（后续替换为 Kenney 精灵）。
@onready var body_rect: ColorRect = $Body

# Weapon 组件（scripts/units/weapon.gd）。不标注类型以便鸭子调用。
@onready var weapon = $Weapon


func _ready() -> void:
	collision_layer = LAYER_UNITS
	collision_mask = LAYER_OBSTACLES
	# 俯视角：关掉重力相关的 grounded 模式。
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group(&"soldiers")
	battle_map = get_tree().get_first_node_in_group(&"battle_map")
	if battle_map == null:
		push_warning("Soldier: 场景中没有 BattleMap（group: battle_map），无法寻路。")
	_apply_team_color()
	if weapon != null and weapon.has_signal("shot_fired"):
		weapon.connect("shot_fired", _on_shot_fired)
	queue_redraw()


func _physics_process(delta: float) -> void:
	_decay_effects(delta)
	if is_dead:
		return
	if weapon != null:
		weapon.call("tick", delta)
	_follow_path()


## 曳光与受击闪白的衰减。放在 is_dead 判断之前，避免士兵阵亡后特效卡住不消失。
func _decay_effects(delta: float) -> void:
	var dirty: bool = false
	if _tracer_ttl > 0.0:
		_tracer_ttl = maxf(0.0, _tracer_ttl - delta)
		dirty = true
	if _hit_flash_ttl > 0.0:
		_hit_flash_ttl = maxf(0.0, _hit_flash_ttl - delta)
		if body_rect != null and _hit_flash_ttl <= 0.0 and not is_dead:
			body_rect.modulate = Color.WHITE
		dirty = true
	if dirty:
		queue_redraw()


func _on_shot_fired(from: Vector2, to: Vector2, _hit_target: bool) -> void:
	_tracer = [from, to]
	_tracer_ttl = TRACER_DURATION
	queue_redraw()


# ---------------------------------------------------------------- 对外接口


## 寻路到指定格子并开始移动。成功返回 true。
func move_to_cell(cell: Vector2i) -> bool:
	if is_dead or battle_map == null:
		return false
	var cells: Array = battle_map.call(
		"find_path", battle_map.call("cell_at", global_position), cell
	)
	if cells.is_empty():
		return false
	var world_path := PackedVector2Array()
	for path_cell in cells:
		world_path.append(battle_map.call("world_pos", path_cell))
	_path = world_path
	_path_index = 0
	_target_cell = cell
	return true


## 是否已经走完当前路径（没有路径也算已到达）。
func has_arrived() -> bool:
	return _path.is_empty() or _path_index >= _path.size()


func stop_moving() -> void:
	_path = PackedVector2Array()
	_path_index = 0
	_target_cell = Vector2i(-1, -1)
	velocity = Vector2.ZERO


func target_cell() -> Vector2i:
	return _target_cell


## 指挥官命令（attack / defend / flank / hold / retreat）。
func set_order(order: String) -> void:
	if current_order == order:
		return
	current_order = order
	order_changed.emit(order)


func take_damage(amount: int) -> void:
	if is_dead:
		return
	hp = maxi(hp - amount, 0)
	health_changed.emit(hp, max_hp)
	_hit_flash_ttl = HIT_FLASH_DURATION
	if body_rect != null:
		# modulate 是乘法，>1 才能"提亮"，实现受击闪白。
		body_rect.modulate = Color(2.2, 2.2, 2.2)
	queue_redraw()
	if hp <= 0:
		die()


func heal(amount: int) -> void:
	if is_dead:
		return
	hp = mini(hp + amount, max_hp)
	health_changed.emit(hp, max_hp)
	queue_redraw()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	velocity = Vector2.ZERO
	stop_moving()
	set_physics_process(false)
	# 尸体不再参与碰撞，也不再挡视线（MVP 简化，后续做“倒地/救援”时改成 Area2D）。
	collision_layer = 0
	collision_mask = 0
	if body_rect != null:
		body_rect.modulate = Color(1.0, 1.0, 1.0, 0.4)
	died.emit(self)
	queue_redraw()


func is_enemy_of(other) -> bool:
	return other != null and other != self and int(other.get("team")) != team


func current_action() -> StringName:
	if ai != null and ai.has_method("current_action"):
		return ai.call("current_action")
	return &"none"


## 转向某个世界坐标（交战时朝向目标，AI 的侧翼判断依赖这个朝向）。
func aim_at(world_target: Vector2) -> void:
	var direction: Vector2 = world_target - global_position
	if direction == Vector2.ZERO:
		return
	facing = direction.normalized()
	queue_redraw()


## 朝某个世界坐标开一枪（冷却由 Weapon 组件内部处理）。
func try_fire(target_pos: Vector2) -> bool:
	if weapon == null:
		return false
	return bool(weapon.call("try_fire", target_pos))


## 当前武器射程；没挂武器时返回 0。
func weapon_range() -> float:
	if weapon == null:
		return 0.0
	return float(weapon.get("max_range"))


# ---------------------------------------------------------------- 内部


func _follow_path() -> void:
	if _path_index >= _path.size():
		velocity = Vector2.ZERO
		return
	var target: Vector2 = _path[_path_index]
	var to_target: Vector2 = target - global_position
	var distance: float = to_target.length()
	if distance <= ARRIVAL_TOLERANCE:
		_path_index += 1
		if _path_index >= _path.size():
			stop_moving()
		return
	var direction: Vector2 = to_target / distance
	facing = direction
	velocity = direction * move_speed
	move_and_slide()


func _apply_team_color() -> void:
	if body_rect == null:
		return
	body_rect.color = TEAM_COLORS.get(team, Color.GRAY)


func _draw() -> void:
	# 曳光：把世界坐标的弹道转成本地坐标画出来。
	if _tracer_ttl > 0.0 and _tracer.size() == 2:
		var alpha: float = _tracer_ttl / TRACER_DURATION
		draw_line(to_local(_tracer[0]), to_local(_tracer[1]), Color(1.0, 0.86, 0.42, alpha), 1.0)
	# 占位渲染：圆形轮廓 + 朝向指示 + 血条。
	draw_circle(Vector2.ZERO, 9.0, Color(1.0, 1.0, 1.0, 0.16))
	draw_line(Vector2.ZERO, facing * 10.0, Color(1.0, 1.0, 1.0, 0.7), 1.5)
	var ratio: float = clampf(float(hp) / maxf(1.0, float(max_hp)), 0.0, 1.0)
	draw_rect(Rect2(-8.0, -14.0, 16.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	var bar_color := Color(0.32, 0.88, 0.45) if ratio > 0.4 else Color(0.93, 0.33, 0.27)
	draw_rect(Rect2(-8.0, -14.0, 16.0 * ratio, 3.0), bar_color)
