# 武器组件：hitscan 射线命中 + 散布 + 射速冷却。作为士兵子节点 "Weapon" 挂载。
class_name Weapon
extends Node

## 每次开枪都会发出（用于曳光/音效/压制事件复用）。
signal shot_fired(from: Vector2, to: Vector2, hit_target: bool)

## 命中单位时发出。
signal target_hit(target: Node, damage: int)

## 物理层：1 = 单位，2 = 静态障碍。与 battle_map.gd / soldier.gd 保持一致。
const LAYER_UNITS := 1
const LAYER_OBSTACLES := 2

@export var damage: int = 12
@export var fire_interval: float = 0.35
@export var max_range: float = 260.0
@export var spread_degrees: float = 6.0

## 弹道多大范围内算"擦身而过"（像素）。
@export var near_miss_radius: float = 40.0

## 一次贴脸近失带来的压制量（离弹道越近越接近这个值）。
@export var suppression_per_near_miss: float = 0.3

## 所属士兵（父节点）。
var owner_unit: CharacterBody2D = null

var shots_fired: int = 0

var _cooldown: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	owner_unit = get_parent() as CharacterBody2D
	if owner_unit == null:
		push_error("Weapon 必须作为 CharacterBody2D（soldier.gd）的子节点。")
		return
	_rng.seed = hash(str(owner_unit.get_path()))


## 由士兵每帧调用，推进射击冷却。
func tick(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(0.0, _cooldown - delta)


func can_fire() -> bool:
	return _cooldown <= 0.0 and owner_unit != null and owner_unit.get("is_dead") != true


## 朝 target_pos 开一枪。返回是否命中了一个能承伤的单位。
func try_fire(target_pos: Vector2) -> bool:
	if not can_fire():
		return false
	_cooldown = fire_interval
	shots_fired += 1
	var from: Vector2 = owner_unit.global_position
	var direction: Vector2 = (target_pos - from).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var spread: float = deg_to_rad(_rng.randf_range(-spread_degrees, spread_degrees) * 0.5)
	var end: Vector2 = from + direction.rotated(spread) * max_range
	var hit := _cast_ray(from, end)
	var impact: Vector2 = end if hit.is_empty() else hit.get("position", end)
	# 不管有没有打中，弹道附近的敌人都会被压制。
	_apply_near_miss_suppression(from, impact)
	if hit.is_empty():
		shot_fired.emit(from, end, false)
		return false
	var body = hit.get("collider")
	if body != null and body != owner_unit and body.has_method("take_damage"):
		body.call("take_damage", damage)
		target_hit.emit(body, damage)
		shot_fired.emit(from, impact, true)
		return true
	# 打中了墙/障碍：不造成伤害，但这一枪仍然发生了（M2 的压制事件会用到）。
	shot_fired.emit(from, impact, false)
	return false


## 弹道附近的敌方单位获得压制：按"点到弹道线段的最短距离"衰减。
## 真正被命中的单位距离≈0，因此也会拿到接近满额的压制——中弹当然更压人。
func _apply_near_miss_suppression(from: Vector2, to: Vector2) -> void:
	if owner_unit == null or near_miss_radius <= 0.0:
		return
	var my_team: int = int(owner_unit.get("team"))
	var segment: Vector2 = to - from
	var segment_sq: float = segment.length_squared()
	if segment_sq < 0.0001:
		return
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit == owner_unit or int(unit.get("team")) == my_team:
			continue
		if unit.get("is_dead") == true or not unit.has_method("apply_suppression"):
			continue
		var to_unit: Vector2 = unit.global_position - from
		var t: float = clampf(to_unit.dot(segment) / segment_sq, 0.0, 1.0)
		var closest: Vector2 = from + segment * t
		var distance: float = closest.distance_to(unit.global_position)
		if distance >= near_miss_radius:
			continue
		var strength: float = 1.0 - distance / near_miss_radius
		unit.call("apply_suppression", suppression_per_near_miss * strength)


func _cast_ray(from: Vector2, to: Vector2) -> Dictionary:
	var space := owner_unit.get_world_2d().direct_space_state
	var exclude: Array[RID] = [owner_unit.get_rid()]
	var query := PhysicsRayQueryParameters2D.create(
		from, to, LAYER_UNITS | LAYER_OBSTACLES, exclude
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)
