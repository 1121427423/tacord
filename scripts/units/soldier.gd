# 士兵实体（CharacterBody2D）：移动、HP、命令状态与占位外观；AI 由子节点 SoldierAI 驱动。
class_name Soldier
extends CharacterBody2D

signal died(unit: CharacterBody2D)

## hp 归零进入倒地（可救援）时发出。
signal went_down(unit: CharacterBody2D)

## 被队友救活时发出；rescuer 为 null 表示非救援途径。
signal revived(unit: CharacterBody2D, rescuer: CharacterBody2D)

## 投降成为俘虏时发出（M7）；by_team 是俘虏归哪一方押送。
signal surrendered(unit: CharacterBody2D, by_team: int)

## 俘虏被释放（押送者阵亡、自己倒地）时发出。
signal released(unit: CharacterBody2D)
signal health_changed(current: int, maximum: int)
signal order_changed(order: String)

## 物理层：1 = 单位，2 = 静态障碍。与 battle_map.gd 保持一致。
const LAYER_UNITS := 1
const LAYER_OBSTACLES := 2

const ARRIVAL_TOLERANCE := 3.0
const TRACER_DURATION := 0.08
const HIT_FLASH_DURATION := 0.12

## 压制：每秒自然衰减量。
const SUPPRESSION_DECAY := 0.22

## 压制对机动性的最大削弱（满压制时只能跑出 40% 速度）。
const SUPPRESSION_SPEED_PENALTY := 0.6

## 倒地后无人救治、失血致死的秒数。
const BLEED_OUT_TIME := 20.0

## 被救活时的血量。
const REVIVE_HP := 30

## 每倒一次地永久损失的最大血量（“虚弱”）。
const WEAKNESS_PER_DOWN := 15

## 倒地时的爬行速度系数（被拖动时用）。
const CRAWL_SPEED_FACTOR := 0.35

## 倒这么多次之后，再倒一次就真正阵亡。
const MAX_DOWNS := 3

## 标准包扎耗时（秒）。医疗兵按倍数加速。
const RESCUE_TIME := 3.0

## 倒地后再挨打对失血计时的加速：每点伤害提前这么多秒。
const BLEED_PER_DAMAGE := 0.12

## 俘虏被押送时的速度系数：比正常慢一点，押送的人跟得上。
const CAPTIVE_SPEED_FACTOR := 0.9
const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),  # 蓝方
	2: Color(1.0, 0.427, 0.345),  # 红方
}

@export var hp: int = 100
@export var max_hp: int = 100
@export var move_speed: float = 80.0
@export var team: int = 1  # 1 = 蓝方，2 = 红方
@export var current_order: String = "hold"

## 失血致死时间（秒）。做成导出项，测试可以把它调短。
@export var bleed_out_time: float = BLEED_OUT_TIME

var is_dead: bool = false

## 倒地：hp 归零先进这个状态，可被队友救活。
var is_downed: bool = false

## 倒地次数：每次叠加虚弱，超过 MAX_DOWNS 才真正阵亡。
var down_count: int = 0

## 剩余失血时间（秒），归零即阵亡。
var bleed_timer: float = 0.0

## 包扎进度，达到 RESCUE_TIME 即被救活。
var rescue_progress: float = 0.0

## 俘虏（M7）：不再开火、不参与目标选择，由敌方押送。
var is_captive: bool = false

## 俘虏归哪一方押送（0 = 不是俘虏）。
var captor_team: int = 0

## 单位朝向（单位向量）。AI 用它判断谁把侧翼暴露给了谁。
var facing: Vector2 = Vector2.RIGHT

## 压制值 [0, 1]：擦身而过的子弹会累积，随时间衰减。
## 影响三处：seek_cover 的效用输入、推进欲望、实际移动速度。
var suppression: float = 0.0

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
	if is_downed:
		_bleed(delta)
		# 倒地的人仍会被队友拖着爬行（effective_speed 已换成爬行速度）。
		_follow_path()
		return
	if is_captive:
		# 俘虏不举枪，但仍会被押送者拖着走。
		_follow_path()
		return
	if weapon != null:
		weapon.call("tick", delta)
	_follow_path()


## 失血计时。归零就是真正的阵亡。
func _bleed(delta: float) -> void:
	if bleed_timer <= 0.0:
		return
	var shown_before: int = int(bleed_timer)
	bleed_timer = maxf(0.0, bleed_timer - delta)
	if bleed_timer <= 0.0:
		die()
	elif int(bleed_timer) != shown_before:
		queue_redraw()


## 曳光与受击闪白的衰减。放在 is_dead 判断之前，避免士兵阵亡后特效卡住不消失。
func _decay_effects(delta: float) -> void:
	var dirty: bool = false
	if suppression > 0.0:
		suppression = maxf(0.0, suppression - SUPPRESSION_DECAY * delta)
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


## 指挥官命令（attack / defend / flank / hold / retreat）。
func set_order(order: String) -> void:
	if current_order == order:
		return
	current_order = order
	order_changed.emit(order)


func take_damage(amount: int) -> void:
	if is_dead:
		return
	_hit_flash_ttl = HIT_FLASH_DURATION
	if body_rect != null:
		# modulate 是乘法，>1 才能"提亮"，实现受击闪白。
		body_rect.modulate = Color(2.2, 2.2, 2.2)
	if is_downed:
		# 已经倒地了：不会再倒一次，但每发子弹都在加速失血。
		bleed_timer = maxf(0.0, bleed_timer - float(amount) * BLEED_PER_DAMAGE)
		queue_redraw()
		return
	hp = maxi(hp - amount, 0)
	health_changed.emit(hp, max_hp)
	queue_redraw()
	if hp <= 0:
		go_down()


## hp 归零：先倒地（可救），不直接阵亡。倒够 MAX_DOWNS 次之后才真的死。
func go_down() -> void:
	if is_dead or is_downed:
		return
	# 倒地的人押不动了：俘虏身份随之解除，医疗兵才认得出这是个待救的伤员。
	release()
	down_count += 1
	if down_count > MAX_DOWNS:
		die()
		return
	is_downed = true
	bleed_timer = bleed_out_time
	rescue_progress = 0.0
	# 倒地的人不会继续被压制（他已经趴下了）。
	suppression = 0.0
	velocity = Vector2.ZERO
	stop_moving()
	if body_rect != null:
		body_rect.modulate = Color(1.0, 1.0, 1.0, 0.75)
	went_down.emit(self)
	queue_redraw()


## 推进包扎进度；返回 true 表示这一次调用刚好把人救活。
## speed_multiplier 让医疗兵比普通兵快（见 soldier_ai.gd 的 is_medic）。
func apply_rescue(
	delta: float, speed_multiplier: float = 1.0, rescuer: CharacterBody2D = null
) -> bool:
	if is_dead or not is_downed:
		return false
	rescue_progress = minf(rescue_progress + delta * maxf(0.1, speed_multiplier), RESCUE_TIME)
	if rescue_progress < RESCUE_TIME:
		return false
	revive(rescuer)
	return true


## 被救活：站起来，但每次倒地都留下永久虚弱。
func revive(rescuer: CharacterBody2D = null) -> void:
	if is_dead or not is_downed:
		return
	is_downed = false
	bleed_timer = 0.0
	rescue_progress = 0.0
	hp = mini(REVIVE_HP, max_hp)
	max_hp = maxi(max_hp - WEAKNESS_PER_DOWN, REVIVE_HP + 1)
	health_changed.emit(hp, max_hp)
	if body_rect != null:
		body_rect.modulate = Color.WHITE
	revived.emit(self, rescuer)
	queue_redraw()


## 投降成为俘虏（M7）。AI 在「被包围 + 被压制 + 无援」时调用。
## 已经倒地/阵亡/是俘虏，或者对方是自己人，都返回 false。
func surrender(by_team: int) -> bool:
	if is_dead or is_downed or is_captive or by_team == team:
		return false
	is_captive = true
	captor_team = by_team
	# 举手的人不再挨压制，也不自己乱跑——路线交给押送者。
	suppression = 0.0
	velocity = Vector2.ZERO
	stop_moving()
	surrendered.emit(self, by_team)
	queue_redraw()
	return true


## 解除俘虏状态。返回 false 表示本来就不是俘虏（含已阵亡）。
func release() -> bool:
	if is_dead or not is_captive:
		return false
	is_captive = false
	captor_team = 0
	released.emit(self)
	queue_redraw()
	return true


## 失血剩余比例 [0, 1]，用于 HUD 与占位渲染。
func bleed_ratio() -> float:
	if bleed_out_time <= 0.0:
		return 0.0
	return clampf(bleed_timer / bleed_out_time, 0.0, 1.0)


## 包扎完成度 [0, 1]，用于 HUD 与占位渲染。
func rescue_ratio() -> float:
	return clampf(rescue_progress / RESCUE_TIME, 0.0, 1.0)


## 被压制（近失子弹）。累积到 [0, 1] 上限。
func apply_suppression(amount: float) -> void:
	if is_dead or is_downed or amount <= 0.0:
		return
	suppression = clampf(suppression + amount, 0.0, 1.0)


## 压制会压慢脚步（满压制只剩 40%）；倒地的人只能爬。
func effective_speed() -> float:
	if is_downed:
		return move_speed * CRAWL_SPEED_FACTOR
	if is_captive:
		return move_speed * CAPTIVE_SPEED_FACTOR
	return move_speed * (1.0 - SUPPRESSION_SPEED_PENALTY * suppression)


func die() -> void:
	if is_dead:
		return
	is_dead = true
	# 死人不是"可救援的倒地状态"，救援判定与 HUD 都依赖这个区分。
	is_downed = false
	# 同理：死人不是俘虏，押送与审讯都得跳过它。
	is_captive = false
	captor_team = 0
	bleed_timer = 0.0
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


## 朝某个世界坐标开一枪（冷却由 Weapon 组件内部处理）。倒地的人开不了枪。
func try_fire(target_pos: Vector2) -> bool:
	# 俘虏当然不开枪：他手上那把枪已经是别人的战利品了。
	if weapon == null or is_downed or is_captive:
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
	velocity = direction * effective_speed()
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
	if is_downed:
		# 倒地：红十字 + 失血条（剩余时间），包扎进度画在下方。
		draw_line(Vector2(-4.0, 0.0), Vector2(4.0, 0.0), Color(0.95, 0.25, 0.25, 0.95), 2.0)
		draw_line(Vector2(0.0, -4.0), Vector2(0.0, 4.0), Color(0.95, 0.25, 0.25, 0.95), 2.0)
		draw_rect(Rect2(-8.0, -14.0, 16.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
		draw_rect(Rect2(-8.0, -14.0, 16.0 * bleed_ratio(), 3.0), Color(0.93, 0.33, 0.27))
		if rescue_progress > 0.0:
			draw_rect(Rect2(-8.0, 11.0, 16.0 * rescue_ratio(), 2.0), Color(0.45, 0.95, 0.6))
		return
	if is_captive:
		# 俘虏：头顶一个白色投降标记 + 空心环，和还在打的人区分开。
		draw_arc(Vector2.ZERO, 11.0, 0.0, TAU, 24, Color(1.0, 1.0, 1.0, 0.75), 1.5)
		draw_line(Vector2(-5.0, -13.0), Vector2(5.0, -13.0), Color.WHITE, 2.0)
		draw_line(Vector2(-5.0, -16.0), Vector2(-5.0, -13.0), Color.WHITE, 1.5)
		draw_line(Vector2(5.0, -16.0), Vector2(5.0, -13.0), Color.WHITE, 1.5)
		return
	var ratio: float = clampf(float(hp) / maxf(1.0, float(max_hp)), 0.0, 1.0)
	draw_rect(Rect2(-8.0, -14.0, 16.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	var bar_color := Color(0.32, 0.88, 0.45) if ratio > 0.4 else Color(0.93, 0.33, 0.27)
	draw_rect(Rect2(-8.0, -14.0, 16.0 * ratio, 3.0), bar_color)
