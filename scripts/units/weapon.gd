# 武器组件：hitscan 射线命中 + 散布 + 射速冷却。作为士兵子节点 "Weapon" 挂载。
class_name Weapon
extends Node

## 每次开枪都会发出（用于曳光/音效/压制事件复用）。
signal shot_fired(from: Vector2, to: Vector2, hit_target: bool)

## 命中单位时发出。
signal target_hit(target: Node, damage: int)

## 弹药数量变化时发出（开火 / 换弹完成 / 摸尸体补弹）。HUD 用它刷新。
signal ammo_changed(in_magazine: int, in_reserve: int)

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

## 一个弹匣的容量。
@export var magazine_size: int = 24

## 开局携带的备弹（不含弹匣里那一匣）。
@export var reserve_ammo: int = 72

## 备弹上限：从尸体上摸弹也不会超过这个数。
@export var max_reserve_ammo: int = 144

## 换弹耗时（秒）。
@export var reload_time: float = 2.2

## 所属士兵（父节点）。
var owner_unit: CharacterBody2D = null

var shots_fired: int = 0

## 弹匣里的余弹。_ready 时填满。
var ammo_in_mag: int = 0

## 正在换弹。这段时间开不了枪。
var is_reloading: bool = false

var _reload_timer: float = 0.0
var _cooldown: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	owner_unit = get_parent() as CharacterBody2D
	if owner_unit == null:
		push_error("Weapon 必须作为 CharacterBody2D（soldier.gd）的子节点。")
		return
	_rng.seed = hash(str(owner_unit.get_path()))
	ammo_in_mag = magazine_size


## 由士兵每帧调用，推进射击冷却与换弹计时。
func tick(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(0.0, _cooldown - delta)
	if not is_reloading:
		return
	_reload_timer = maxf(0.0, _reload_timer - delta)
	if _reload_timer <= 0.0:
		_finish_reload()


func can_fire() -> bool:
	if _cooldown > 0.0 or is_reloading or owner_unit == null:
		return false
	if owner_unit.get("is_dead") == true:
		return false
	# 弹匣空了就得先换弹；备弹也空了就永远开不了枪了。
	return ammo_in_mag > 0


## 弹匣 + 备弹，一共还剩多少发。
func total_ammo() -> int:
	return ammo_in_mag + reserve_ammo


## 彻底打光（弹匣空且没有备弹可换）。
func is_dry() -> bool:
	return total_ammo() <= 0


## 开始换弹。没有备弹就换不了——这正是"阵地渐渐沉寂"的起点。
func start_reload() -> bool:
	if is_reloading or reserve_ammo <= 0 or ammo_in_mag >= magazine_size:
		return false
	is_reloading = true
	_reload_timer = reload_time
	return true


func _finish_reload() -> void:
	is_reloading = false
	_reload_timer = 0.0
	var take: int = mini(magazine_size - ammo_in_mag, reserve_ammo)
	ammo_in_mag += take
	reserve_ammo -= take
	ammo_changed.emit(ammo_in_mag, reserve_ammo)


## 从另一把武器（通常是尸体上那把）拿备弹。返回实际拿到的数量。
func take_ammo_from(other) -> int:
	if other == null or other == self or not other.has_method("total_ammo"):
		return 0
	var available: int = int(other.get("reserve_ammo"))
	var take: int = mini(available, maxi(max_reserve_ammo - reserve_ammo, 0))
	if take <= 0:
		return 0
	reserve_ammo += take
	other.set("reserve_ammo", available - take)
	ammo_changed.emit(ammo_in_mag, reserve_ammo)
	return take


## 直接补备弹（FOB 补给用），按 max_reserve_ammo 封顶。返回实际补进去的数量。
func add_reserve(amount: int) -> int:
	var take: int = mini(amount, maxi(max_reserve_ammo - reserve_ammo, 0))
	if take <= 0:
		return 0
	reserve_ammo += take
	ammo_changed.emit(ammo_in_mag, reserve_ammo)
	return take


## 朝 target_pos 开一枪。返回是否命中了一个能承伤的单位。
func try_fire(target_pos: Vector2) -> bool:
	if not can_fire():
		return false
	_cooldown = fire_interval
	ammo_in_mag = maxi(ammo_in_mag - 1, 0)
	shots_fired += 1
	ammo_changed.emit(ammo_in_mag, reserve_ammo)
	# 打空当场就开始换弹（没有备弹则换不了，这把枪就此沉寂）。
	if ammo_in_mag <= 0:
		start_reload()
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
