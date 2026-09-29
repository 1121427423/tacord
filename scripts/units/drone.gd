# 侦察无人机（M11）：飞得快、看得远、三发步枪弹就掉。占位外形，MVP 不带武器、不做续航。
class_name Drone
extends CharacterBody2D

## 与坦克同一个 vehicles 组：感知与命令广播本来就扫它——士兵看得见、
## 步兵与坦克的子弹都打得着；救援、押送、帐篷治疗、FOB 补弹都只扫 soldiers，
## 无人机不进去就一个都不会被误伤到。
const GROUP := &"vehicles"

## 巡航速度：比步兵（80）快、比坦克（40）快得多——它是来去自由的眼睛。
const FLY_SPEED := 110.0
const ARRIVAL_TOLERANCE := 3.0

## 侦察半径：与步枪射程同量级（260），盯梢盘旋半径取它的一半不到。
const SPOT_RADIUS := 260.0

## 侦察节拍（秒）。与 DroneAI 的思考节拍各记各的账。
const SPOT_INTERVAL := 0.4

## 目击保鲜期（秒）：超过它 DroneAI 就不再盯着旧位置转。
const SPOT_STALE := 1.2

const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),
	2: Color(1.0, 0.427, 0.345),
}

@export var team: int = 1
@export var max_hp: int = 30
@export var current_order: String = "hold"

var hp: int = 30
var is_dead: bool = false

## 载具不会"倒地"，也成不了"俘虏"（同坦克：perception.gd 的敌人
## 过滤对每个候选都读这两项，恒 false 就能原样复用）。
var is_downed: bool = false
var is_captive: bool = false
var facing: Vector2 = Vector2.UP

## 无人机不吃压制：恒 0，且故意不提供 apply_suppression——
## weapon.gd 的近失压制先 has_method 再调用，子弹擦过机身攒不起来。
var suppression: float = 0.0

## 由 DroneAI 每次思考时写，HUD 显示用。
var action: StringName = &"patrol"

## 最近一次目击的敌方位置与距今秒数。公开变量：DroneAI 与 HUD 都要读，
## gdlint 只数公开方法，变量不占额度（同坦克的 objective）。
var latest_spot := Vector2.ZERO
var spot_age: float = SPOT_STALE

# 本队黑板：无人机的目击必须全队共享，步兵由此获得"天上来的"最后已知位置。
var _board: Blackboard = null

var _fly_target := Vector2.ZERO
var _flying := false
var _scan_timer: float = 0.0


func _ready() -> void:
	hp = max_hp
	add_to_group(GROUP)
	_wire_board()
	queue_redraw()


## 拿到本队黑板（Game autoload）。拿不到就私有——目击照样记，只是不与队友共享。
func _wire_board() -> void:
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("blackboard"):
		_board = game.call("blackboard", team)
	else:
		push_warning("Drone: 没有 Game 自动加载，目击不与队友共享。")
		_board = Blackboard.new()


## 宏观命令照收但不改行为：hold 让步兵蹲坑，没道理把天上的眼睛也收回来。
func set_order(order: String) -> void:
	current_order = order
	queue_redraw()


## 直线飞往世界坐标，返回是否接受。**不做寻路**——无人机从头顶过，
## 墙挡不住它；这正是它和坦克（同走 A*）最本质的机动差别。
func fly_to(world_pos: Vector2) -> bool:
	if is_dead:
		return false
	_fly_target = world_pos
	_flying = true
	return true


func has_arrived() -> bool:
	return not _flying


func stop_moving() -> void:
	_flying = false
	velocity = Vector2.ZERO


func current_action() -> StringName:
	if is_dead:
		return &"destroyed"
	return action


## 侦察：半径内的敌方单位（士兵 + 载具）写进本队黑板，返回发现几个。
## **不做通视判定**——无人机从上往下看，墙挡得住子弹，挡不住俯瞰；
## 这正是它对步兵（目击必须先过 has_line_of_sight）的全部价值差。
func scan_now() -> int:
	var found: int = 0
	var nearest = null
	var nearest_dist: float = SPOT_RADIUS
	for group_name in [&"soldiers", &"vehicles"]:
		for unit in get_tree().get_nodes_in_group(group_name):
			if unit == self or int(unit.get("team")) == team:
				continue
			if unit.get("is_dead") == true or unit.get("is_downed") == true:
				continue
			if unit.get("is_captive") == true:
				continue
			var distance: float = global_position.distance_to(unit.global_position)
			if distance > SPOT_RADIUS:
				continue
			found += 1
			if _board != null:
				_board.report_sighting(unit, unit.global_position)
			# 每个看见的都报给黑板，但盯梢只追最近的那一个。
			if distance <= nearest_dist:
				nearest_dist = distance
				nearest = unit
	if nearest != null:
		latest_spot = nearest.global_position
		spot_age = 0.0
	return found


## 挨打：没有装甲系数——侦察无人机是脆皮，步枪弹 12 点就是 12 点。
func take_damage(amount: int) -> void:
	if is_dead:
		return
	hp = maxi(hp - amount, 0)
	queue_redraw()
	if hp <= 0:
		die()


func die() -> void:
	if is_dead:
		return
	is_dead = true
	stop_moving()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
	spot_age += delta
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SPOT_INTERVAL
		scan_now()
	_fly_step()


func _fly_step() -> void:
	if not _flying:
		velocity = Vector2.ZERO
		return
	var to_target: Vector2 = _fly_target - global_position
	if to_target.length() <= ARRIVAL_TOLERANCE:
		stop_moving()
		return
	facing = to_target / to_target.length()
	velocity = facing * FLY_SPEED
	move_and_slide()


func _draw() -> void:
	if is_dead:
		# 坠机残迹：一个小叉，提醒这里掉过一架。
		draw_line(Vector2(-5, -5), Vector2(5, 5), Color(0.2, 0.2, 0.2, 0.6), 2.0)
		draw_line(Vector2(-5, 5), Vector2(5, -5), Color(0.2, 0.2, 0.2, 0.6), 2.0)
		return
	var tint: Color = TEAM_COLORS.get(team, Color.GRAY)
	# 悬停投影画在斜下方：一眼读出"这玩意儿在天上"，也解释了它为什么挡不了路。
	draw_circle(Vector2(4.0, 7.0), 4.0, Color(0.0, 0.0, 0.0, 0.25))
	# 机身：小圆 + 十字旋翼，和士兵的方块、坦克的方盒一眼分得开。
	draw_circle(Vector2.ZERO, 5.0, Color(tint, 0.5))
	draw_circle(Vector2.ZERO, 5.0, tint, false, 1.5)
	draw_line(Vector2(-8.0, 0.0), Vector2(8.0, 0.0), tint, 1.0)
	draw_line(Vector2(0.0, -8.0), Vector2(0.0, 8.0), tint, 1.0)
	# 血条挂在头顶，和士兵/坦克同一套画法。
	var ratio: float = clampf(float(hp) / float(maxi(max_hp, 1)), 0.0, 1.0)
	draw_rect(Rect2(-8.0, -14.0, 16.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	draw_rect(Rect2(-8.0, -14.0, 16.0 * ratio, 3.0), Color(0.32, 0.88, 0.45))
