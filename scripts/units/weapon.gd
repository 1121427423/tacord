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
	if hit.is_empty():
		shot_fired.emit(from, end, false)
		return false
	var body = hit.get("collider")
	var hit_point: Vector2 = hit.get("position", end)
	if body != null and body != owner_unit and body.has_method("take_damage"):
		body.call("take_damage", damage)
		target_hit.emit(body, damage)
		shot_fired.emit(from, hit_point, true)
		return true
	# 打中了墙/障碍：不造成伤害，但这一枪仍然发生了（M2 的压制事件会用到）。
	shot_fired.emit(from, hit_point, false)
	return false


func _cast_ray(from: Vector2, to: Vector2) -> Dictionary:
	var space := owner_unit.get_world_2d().direct_space_state
	var exclude: Array[RID] = [owner_unit.get_rid()]
	var query := PhysicsRayQueryParameters2D.create(
		from, to, LAYER_UNITS | LAYER_OBSTACLES, exclude
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)
