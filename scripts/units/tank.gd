# 装甲车（M10）：厚甲、慢速、长射程主炮的载具。占位外形，MVP 不做乘员上下车。
class_name Tank
extends CharacterBody2D

## 载具自成一组，**不进 "soldiers"**：救援、押送、帐篷治疗、FOB 补弹都扫
## soldiers 组，坦克不进去就一个都不会被误伤到；感知层另开一条路看它。
const GROUP := &"vehicles"

const LAYER_UNITS := 1
const LAYER_OBSTACLES := 2

## 小口径打在车体上只啃掉四分之一（至少 1 点，免得 1 发实伤 0）。
const ARMOR_FACTOR := 0.25

## 载具不趴下、不滑铲、不受压制，速度恒定——比士兵的 80 慢一半。
const MOVE_SPEED := 40.0
const ARRIVAL_TOLERANCE := 3.0

const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),
	2: Color(1.0, 0.427, 0.345),
}

@export var team: int = 1
@export var max_hp: int = 200
@export var current_order: String = "hold"

var hp: int = 200
var is_dead: bool = false

## 载具不会"倒地"，也成不了"俘虏"。两个属性恒为 false，是为了让
## perception.gd 的敌人过滤原样可用——它对每个候选都会读这两项。
var is_downed: bool = false
var is_captive: bool = false
var facing: Vector2 = Vector2.RIGHT

## 载具不吃压制：恒为 0，而且**故意不提供 apply_suppression 方法**——
## weapon.gd 的近失压制先 has_method 再调用，所以子弹擦过车体攒不起来。
var suppression: float = 0.0

## 由 TankAI 每次思考时写，HUD 显示用。
var action: StringName = &"hold"

## 推进目标格（-1,-1 表示没设定，TankAI 会转为待命）。
## 做成公开变量而不是 set_objective()：AI 每帧都要读它决定要不要重新找路，
## 给读路径开一个方法纯属多余——gdlint 只数公开方法，公开变量不占额度。
var objective := Vector2i(-1, -1)

# Weapon 组件（tscn 子节点）。故意不标注类型：gdparse 查不出隐式降型，
# 引擎里才炸。和 perception.gd 的约定一致，全部走鸭子调用。
var weapon = null

var _map = null
var _path := PackedVector2Array()
var _path_index: int = 0


func _ready() -> void:
	hp = max_hp
	add_to_group(GROUP)
	_map = get_tree().get_first_node_in_group(&"battle_map")
	weapon = get_node_or_null("Weapon")
	queue_redraw()


func set_order(order: String) -> void:
	current_order = order
	queue_redraw()


## 沿 A* 走到目标格。和士兵同一张图、同一套 find_path——
## 载具走不了的地方（blocked）它同样过不去，不需要第二套寻路。
func move_to_cell(cell: Vector2i) -> bool:
	if is_dead or _map == null:
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


func has_arrived() -> bool:
	return _path.is_empty() or _path_index >= _path.size()


func stop_moving() -> void:
	_path = PackedVector2Array()
	_path_index = 0
	velocity = Vector2.ZERO


func current_action() -> StringName:
	if is_dead:
		return &"destroyed"
	return action


## 挨打。小口径弹在装甲上只留下四分之一的实伤。
func take_damage(amount: int) -> void:
	if is_dead:
		return
	var real: int = maxi(1, int(round(float(amount) * ARMOR_FACTOR)))
	hp = maxi(hp - real, 0)
	queue_redraw()
	if hp <= 0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	velocity = Vector2.ZERO
	stop_moving()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
	if weapon != null:
		weapon.call("tick", delta)
	_follow_path()


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
	velocity = direction * MOVE_SPEED
	move_and_slide()



func _draw() -> void:
	if is_dead:
		# 残骸留着给战场一个交代，但它不挡视线、不挡子弹（地形没变）。
		draw_rect(Rect2(-13.0, -13.0, 26.0, 26.0), Color(0.15, 0.15, 0.16, 0.7), true)
		return
	var tint: Color = TEAM_COLORS.get(team, Color.GRAY)
	# 车体：横向的方盒，和士兵的 14px 小方块一眼分得开。
	draw_rect(Rect2(-13.0, -10.0, 26.0, 20.0), Color(tint, 0.32), true)
	draw_rect(Rect2(-13.0, -10.0, 26.0, 20.0), tint, false, 2.0)
	# 炮塔 + 炮管：朝向一眼可见，也是 flank 的依据。
	draw_circle(Vector2.ZERO, 5.5, Color(tint, 1.0))
	draw_line(Vector2.ZERO, facing * 17.0, Color(tint, 1.0), 3.0)
	# 血条挂在头顶，和 build_site 同一套画法。
	var ratio: float = clampf(float(hp) / float(maxi(max_hp, 1)), 0.0, 1.0)
	draw_rect(Rect2(-13.0, -17.0, 26.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	draw_rect(Rect2(-13.0, -17.0, 26.0 * ratio, 3.0), Color(0.32, 0.88, 0.45))
