# 手榴弹（M12）：一次性投掷物。Node2D 而不是物理体——没人朝雷开枪，
# 也不参与任何碰撞；不进 soldiers/vehicles 组（救援、押送、帐篷治疗、
# FOB 补弹都只扫那两组，它不进去就一个都不会被误伤到），只进 grenades
# 组：evade 的打分与「被扔回」的扫描都认这个组。
class_name Grenade
extends Node2D

## 总引信（秒），**含飞行段**：出手即点火，走完 1.8s 必炸。
const FUSE_TOTAL := 1.8

## 飞行耗时（秒）：出手到落点恒定 0.5s，速度 = 距离 / 0.5。
const FLY_TIME := 0.5

## 爆炸半径（px）：伤害从中心 60 线性衰减到边缘 12。
const BLAST_RADIUS := 56.0
const BLAST_DAMAGE_CORE := 60.0
const BLAST_DAMAGE_EDGE := 12.0

## 掀飞半径（px）：只有离爆心这么近的士兵才被冲量掀飞——
## 挨炸（56px）不一定被掀飞（40px），血账与位移是两本账。
const BLAST_PUSH_RADIUS := 40.0

## 爆炸的一次性大额压制：爆炸不分敌我，双方都怕。
const BLAST_SUPPRESSION := 0.8

## 被扔回：距雷这么近的敌兵才够得着捡。
const RETURN_PICK_RADIUS := 40.0

## 引信剩余低于这个值就没人敢碰——捡起来也来不及扔回去了。
const RETURN_MIN_FUSE := 0.6

## 压制到这个值以上的兵没胆子捡雷。
const RETURN_MAX_SUPPRESSION := 0.7

## 是否已被敌兵捡起扔回。公开变量（不占 gdlint 的方法额度），
## 只允许翻一次——扔回去的雷没人再敢碰。
var has_been_returned: bool = false

# 投掷方。鸭子引用：只读 team 与 global_position，不限定类型。
var _thrower: Node = null
var _thrower_team: int = 0

# 引信剩余（秒）。
var _fuse: float = 0.0

# 飞行账目：Node2D 没有物理体，不走 velocity/move_and_slide，
# 直接按已飞时长线性插值推进 position（思路同 drone.gd 的 _fly_step）。
var _fly_from := Vector2.ZERO
var _fly_to := Vector2.ZERO
var _fly_elapsed: float = 0.0
var _flying: bool = false


func _ready() -> void:
	add_to_group(&"grenades")
	queue_redraw()


## 出手：从 from 直线飞 0.5s 到 to，落点后原地待爆（总引信 1.8s 含飞行段）。
## 已经出过手或投掷者缺失时返回 false——一颗雷只有一次出手。
func throw_grenade(from: Vector2, to: Vector2, thrower: Node) -> bool:
	if _fuse > 0.0 or thrower == null:
		return false
	_thrower = thrower
	_thrower_team = int(thrower.get("team"))
	global_position = from
	_fly_from = from
	_fly_to = to
	_fly_elapsed = 0.0
	_flying = true
	_fuse = FUSE_TOTAL
	queue_redraw()
	return true


## 距爆炸还剩几秒。evade 打分与「敢不敢捡」的判断都读它。
func fuse_remaining() -> float:
	return maxf(0.0, _fuse)


func _physics_process(delta: float) -> void:
	if _fuse <= 0.0:
		return
	_fuse -= delta
	if _flying:
		_fly_step(delta)
	# 引信未爆期间每帧扫一遍：投掷方的敌营里有没有胆子够大的敢捡。
	if not has_been_returned:
		_scan_return()
	if _fuse <= 0.0:
		_explode()
		queue_free()
		return
	queue_redraw()


## 直线飞行：按已飞时长线性插值（速度 = 距离 / FLY_TIME），到点即落地。
func _fly_step(delta: float) -> void:
	_fly_elapsed = minf(_fly_elapsed + delta, FLY_TIME)
	global_position = _fly_from.lerp(_fly_to, _fly_elapsed / FLY_TIME)
	if _fly_elapsed >= FLY_TIME:
		_flying = false


## 被扔回扫描：找一个「胆子够大」的敌兵——未倒地、未死亡、未俘虏、
## 压制 < 0.7、距雷 ≤ 40px、引信剩余 ≥ 0.6s，缺一不捡。
## 找到就把雷捡起来朝投掷者的**当前位置**扔回：引信不重置继续跑，
## 重新飞 0.5s。只允许翻一次 has_been_returned——扔回去的雷没人再敢碰。
func _scan_return() -> void:
	if _thrower == null or not is_instance_valid(_thrower):
		return
	if fuse_remaining() < RETURN_MIN_FUSE:
		return
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) == _thrower_team:
			continue
		if unit.get("is_dead") == true or unit.get("is_downed") == true:
			continue
		if unit.get("is_captive") == true:
			continue
		if float(unit.get("suppression")) >= RETURN_MAX_SUPPRESSION:
			continue
		if global_position.distance_to(unit.global_position) > RETURN_PICK_RADIUS:
			continue
		has_been_returned = true
		_fly_from = global_position
		_fly_to = _thrower.global_position
		_fly_elapsed = 0.0
		_flying = true
		return


## 爆炸：半径内扫 soldiers + vehicles 两组（雷自己不在任何一组里，天然不会被
## 自己波及）。MVP 简化：**不判破片遮挡**——墙后的单位照样吃伤，这是写明的
## 取舍，不是漏掉的判定。顺序是先结伤害账、再掀飞、再压制——被这一炸
## 打倒的人不会被掀飞（apply_blast 自己挡倒地者），倒地者也不吃压制。
func _explode() -> void:
	for group_name in [&"soldiers", &"vehicles"]:
		for unit in get_tree().get_nodes_in_group(group_name):
			var distance: float = global_position.distance_to(unit.global_position)
			if distance > BLAST_RADIUS:
				continue
			# 伤害线性衰减：贴脸 60 → 边缘 12。装甲减伤走各单位自己的
			# take_damage（坦克的 1/4 系数自动生效），这里不做任何特判。
			if unit.has_method("take_damage"):
				unit.call("take_damage", _blast_damage(distance))
	# 掀飞：只对爆心 40px 内、提供 apply_blast 的单位（坦克那种块头气浪推不动；
	# 鸭子认方法，不认类型）。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if global_position.distance_to(unit.global_position) > BLAST_PUSH_RADIUS:
			continue
		if unit.has_method("apply_blast"):
			unit.call("apply_blast", global_position)
	# 压制：半径内所有活着的、认 apply_suppression 的单位——爆炸双方都怕。
	for group_name in [&"soldiers", &"vehicles"]:
		for unit in get_tree().get_nodes_in_group(group_name):
			if global_position.distance_to(unit.global_position) > BLAST_RADIUS:
				continue
			if unit.get("is_dead") == true:
				continue
			if unit.has_method("apply_suppression"):
				unit.call("apply_suppression", BLAST_SUPPRESSION)


## 半径处的伤害：中心 60 → 边缘 12 线性衰减，取整。
func _blast_damage(distance: float) -> int:
	return int(round(lerpf(BLAST_DAMAGE_CORE, BLAST_DAMAGE_EDGE, distance / BLAST_RADIUS)))


func _draw() -> void:
	# 占位外观：深橄榄小圆 + 引信进度环（headless CI 不渲染，仅供肉眼验）。
	var tint := Color(0.35, 0.42, 0.24)
	draw_circle(Vector2.ZERO, 4.5, Color(tint, 0.55))
	draw_circle(Vector2.ZERO, 4.5, tint, false, 1.5)
	if _fuse > 0.0:
		var ratio: float = clampf(_fuse / FUSE_TOTAL, 0.0, 1.0)
		draw_arc(
			Vector2.ZERO,
			6.5,
			-TAU / 4.0,
			-TAU / 4.0 + TAU * ratio,
			16,
			Color(1.0, 0.62, 0.28, 0.9),
			1.5,
		)
	if _flying:
		# 飞行途中画一小段指向落点的线，方向感一眼可读。
		var to_target: Vector2 = _fly_to - global_position
		if to_target.length() > 1.0:
			draw_line(
				Vector2.ZERO,
				to_target.normalized() * 9.0,
				Color(1.0, 0.62, 0.28, 0.5),
				1.0,
			)
