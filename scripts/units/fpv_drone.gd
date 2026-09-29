# FPV 自杀无人机（M13）：M11 侦察机的对位——那个是眼睛，这个是刺刀。
# 侦察机飞得快、看得远、不咬人；FPV 只做一件事：锁定最近敌人直线俯冲，
# 贴到 16px 内引爆。hp 20：两发步枪弹就能打下来，而被打下来的 FPV 是
# 哑弹（坠毁不引爆）——这正是士兵努力击落它的全部理由。
class_name FPVDrone
extends CharacterBody2D

## 与坦克/侦察机同一个 vehicles 组：感知与命令广播本来就扫它——士兵看得见、
## 步兵与坦克的子弹都打得着；救援、押送、帐篷治疗、FOB 补弹都只扫 soldiers，
## 它不进去就一个都不会被误伤到。
const GROUP := &"vehicles"

## 俯冲速度：比侦察机（110）更快——冲向目标的窗口越短，士兵越来不及反应。
const FLY_SPEED := 150.0
const ARRIVAL_TOLERANCE := 3.0

## 爆炸半径与衰减区间：中心 25 -> 边缘 10 线性衰减（M12 手雷语义减半）。
## 伤害走 take_damage 链路，坦克的装甲系数在它自己那侧自动生效。
const BLAST_RADIUS := 40.0
const BLAST_DAMAGE_CENTER := 25.0
const BLAST_DAMAGE_EDGE := 10.0

## 爆炸对半径内活着的、有 apply_suppression 接口的单位施加的一次性大额压制。
const BLAST_SUPPRESSION := 0.6

const TEAM_COLORS := {
	1: Color(0.404, 0.635, 1.0),
	2: Color(1.0, 0.427, 0.345),
}

@export var team: int = 1
@export var max_hp: int = 20
@export var current_order: String = "hold"

var hp: int = 20
var is_dead: bool = false

## 载具不会"倒地"，也成不了"俘虏"（同坦克/侦察机：perception.gd 的敌人
## 过滤对每个候选都读这两项，恒 false 就能原样复用）。
var is_downed: bool = false
var is_captive: bool = false
var facing: Vector2 = Vector2.RIGHT

## 机器攒不起恐惧：恒 0，且故意不提供 apply_suppression——
## weapon.gd 的近失压制先 has_method 再调用，子弹擦过机身攒不起来。
var suppression: float = 0.0

## 当前锁定目标。由 FPVAI 在思考节拍里写入，测试与 HUD 直接读——
## 同侦察机 latest_spot 的约定：公开变量不占 gdlint 的方法额度。
## 故意不标注类型：目标可能是士兵也可能是坦克，全部走鸭子调用。
var target = null

## 锁定完成正在俯冲 = true。FPVAI 换目标或悬停时清掉；
## 供后续 evade 推广（M12 扑倒要认出"正在俯冲的 FPV"）与测试读取。
var is_diving: bool = false

## 残骸的两种下场：引爆过的画焦痕，被击落的画小叉（同侦察机）。
var _exploded: bool = false


func _ready() -> void:
	hp = max_hp
	add_to_group(GROUP)
	queue_redraw()


## 宏观命令照收但不改行为：同侦察机——hold 让步兵蹲坑，没道理管天上的刀。
func set_order(order: String) -> void:
	current_order = order
	queue_redraw()


## 挨打：没有装甲系数——撞针式无人机是脆皮，步枪弹 12 点就是 12 点。
## 两发击落；坠毁走 die()（只画残骸），坠毁**不**引爆。
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
	is_diving = false
	velocity = Vector2.ZERO
	queue_redraw()


## 撞针引爆：由 FPVAI 在距目标 <= 16px 时调用，测试/脚本也可以直接调。
## 半径内扫 soldiers + vehicles 两组：伤害按距离线性衰减、再施加一次性压制。
## **不认军服**——M12 手雷同款语义，队友挨着自己人的炸一样掉血一样腿软；
## 也不判破片遮挡（MVP 简化，同手雷）。已经坠毁的 FPV 是哑弹：is_dead 守卫
## 让它永远炸不了——这正是士兵努力击落它的全部理由。
func explode() -> void:
	if is_dead:
		return
	is_dead = true
	is_diving = false
	velocity = Vector2.ZERO
	_exploded = true
	var center: Vector2 = global_position
	for group_name in [&"soldiers", &"vehicles"]:
		for unit in get_tree().get_nodes_in_group(group_name):
			if unit == self or not unit.has_method("take_damage"):
				continue
			var distance: float = center.distance_to(unit.global_position)
			if distance > BLAST_RADIUS:
				continue
			# 倒地/阵亡的判定在各 unit 的 take_damage 里自己把关
			# （士兵倒地不再掉血，只加速失血）。
			var ratio: float = distance / BLAST_RADIUS
			var damage: int = int(round(lerpf(BLAST_DAMAGE_CENTER, BLAST_DAMAGE_EDGE, ratio)))
			unit.call("take_damage", damage)
			# 爆炸也吓人：有 apply_suppression 接口的（士兵）吃一次大额压制；
			# 载具没有这个接口，天然免疫——机器攒不起恐惧。
			if unit.has_method("apply_suppression"):
				unit.call("apply_suppression", BLAST_SUPPRESSION)
	# 引爆的机体留焦痕不消失（同坦克残骸给战场一个交代），也不挡路不挡子弹。
	queue_redraw()


func _physics_process(_delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
	_fly_step()


## 直线俯冲锁定目标——**不做寻路**，墙挡不住它（同侦察机从头顶过）。
## 没在俯冲（没锁定/目标没了）就悬停。位移由机体自己完成：
## FPVAI 只负责挑目标与拉信管，分工同 DroneAI 只发 fly_to 指令。
func _fly_step() -> void:
	if not is_diving or target == null or not is_instance_valid(target):
		velocity = Vector2.ZERO
		return
	var to_target: Vector2 = target.global_position - global_position
	if to_target.length() <= ARRIVAL_TOLERANCE:
		velocity = Vector2.ZERO
		return
	facing = to_target / to_target.length()
	velocity = facing * FLY_SPEED
	move_and_slide()


func _draw() -> void:
	if is_dead:
		if _exploded:
			# 爆炸残留：两圈焦痕——它在这里兑现了使命。
			draw_circle(Vector2.ZERO, 7.0, Color(0.09, 0.06, 0.05, 0.55))
			draw_circle(Vector2.ZERO, 11.0, Color(0.09, 0.06, 0.05, 0.25))
		else:
			# 坠机残迹：一个小叉（同侦察机）——这里掉过一架哑弹。
			draw_line(Vector2(-5, -5), Vector2(5, 5), Color(0.2, 0.2, 0.2, 0.6), 2.0)
			draw_line(Vector2(-5, 5), Vector2(5, -5), Color(0.2, 0.2, 0.2, 0.6), 2.0)
		return
	var tint: Color = TEAM_COLORS.get(team, Color.GRAY)
	# 悬停投影画在斜下方：一眼读出"这玩意儿在天上"，也解释了它为什么挡不了路。
	draw_circle(Vector2(4.0, 7.0), 4.0, Color(0.0, 0.0, 0.0, 0.25))
	# 机身：一枚朝 facing 方向的小飞镖——侦察机是圆的，它是尖的（刺刀）。
	var side: Vector2 = facing.orthogonal() * 4.0
	var nose: Vector2 = facing * 9.0
	var tail: Vector2 = -facing * 6.0
	draw_polygon(
		PackedVector2Array([nose, tail + side, tail - side]),
		PackedColorArray([Color(tint, 0.85)])
	)
	# 血条挂在头顶，和士兵/侦察机同一套画法。
	var ratio: float = clampf(float(hp) / float(maxi(max_hp, 1)), 0.0, 1.0)
	draw_rect(Rect2(-8.0, -14.0, 16.0, 3.0), Color(0.0, 0.0, 0.0, 0.65))
	draw_rect(Rect2(-8.0, -14.0, 16.0 * ratio, 3.0), Color(0.32, 0.88, 0.45))
