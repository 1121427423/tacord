# M13 FPV 自杀无人机的独立冒烟场景：身段与边界 / 脆皮 / 锁定俯冲 / 撞击引爆 /
# 击落不爆 / 士兵击落链路 / fpv_threat / 坦克合法目标 / 侦察机零扰动。
# 第六个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank 40 / drone 37 / fpv N）——
# 每个里程碑一个场景是 M8 定下的规矩（smoke_test.gd 顶着 gdlint 的 1000 行上限）。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"
# ——例如"击落不爆"必须同时钉住"邻兵血量不变"与"死后补一发 explode 也无效"，
# 只看 is_dead 会把"炸了但恰好没伤到人"也误判成通过。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const TANK_SCENE := preload("res://scenes/units/tank.tscn")
const DRONE_SCENE := preload("res://scenes/units/drone.tscn")
const FPV_SCENE := preload("res://scenes/units/fpv_drone.tscn")
const PERCEPTION_SCRIPT := preload("res://scripts/ai/perception.gd")

# 本场景的断言总数。与其余五个场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 49

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://fpv_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_fpv()
	_finish()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		_emit("  PASS  %s" % label)
	else:
		_failures += 1
		_emit("  FAIL  %s" % label)


func _emit(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _finish() -> void:
	_emit("")
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		_emit(
			"  FAIL  断言总数应为 %d，实际只跑到 %d（有测试段没执行完）"
			% [EXPECTED_CHECKS, _checks]
		)
	else:
		_emit("  PASS  断言总数 = %d" % _checks)
	if _failures == 0:
		_emit("FPV TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("FPV TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


## 造士兵：默认关掉 AI——本场景要的全是静止状态下发生的事。
func _spawn_soldier(cell: Vector2i, team: int, hp: int = 100):
	var unit = SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	_map.add_child(unit)
	unit.get_node("SoldierAI").set_process(false)
	unit.global_position = _map.world_pos(cell)
	unit.set("hp", hp)
	return unit


## 造坦克。ai_on=false 时关掉 TankAI 的物理思考——注意是 set_physics_process
## （与 DroneAI/FPVAI 同款；soldier_ai 才是挂在 _process 上的 set_process）。
func _spawn_tank(cell: Vector2i, team: int, ai_on: bool = false):
	var tank = TANK_SCENE.instantiate()
	tank.set("team", team)
	_map.add_child(tank)
	if not ai_on:
		tank.get_node("TankAI").set_physics_process(false)
	tank.global_position = _map.world_pos(cell)
	return tank


## 造 M11 侦察机（第 9 段回归用）。ai_on=false 时关掉 DroneAI 的物理思考。
func _spawn_drone(cell: Vector2i, team: int, ai_on: bool = false):
	var drone = DRONE_SCENE.instantiate()
	drone.set("team", team)
	_map.add_child(drone)
	if not ai_on:
		drone.get_node("DroneAI").set_physics_process(false)
	drone.global_position = _map.world_pos(cell)
	return drone


## 造 FPV。ai_on=false 时关掉 FPVAI 的物理思考（同 _spawn_drone 的写法）。
## 机体的自动飞行不关：它由 target/is_diving 驱动，是"执行器"，不是决策。
func _spawn_fpv(cell: Vector2i, team: int, ai_on: bool = false):
	var fpv = FPV_SCENE.instantiate()
	fpv.set("team", team)
	_map.add_child(fpv)
	if not ai_on:
		fpv.get_node("FPVAI").set_physics_process(false)
	fpv.global_position = _map.world_pos(cell)
	return fpv


func _wait(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


## 等到条件成立或帧数用尽；返回最终是否成立。
func _wait_until(condition: Callable, frames: int) -> bool:
	for _i in range(frames):
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _test_fpv() -> void:
	_emit("[FPV 自杀无人机]")

	# ================================================================
	# 1) 身段与边界：和坦克/侦察机同一套载具身段——看得见、打得着、救不了
	# ================================================================
	var fpv = _spawn_fpv(Vector2i(6, 6), 1)
	_check(fpv.is_in_group(&"vehicles"), "FPV 注册在 vehicles 组（感知与命令广播的既有通道）")
	_check(
		not fpv.is_in_group(&"soldiers"),
		"FPV **不在** soldiers 组——救援/补给/帐篷治疗都看不见它",
	)
	_check(fpv.get("is_downed") == false, "FPV 永不倒地（is_downed 恒 false）")
	_check(fpv.get("is_captive") == false, "FPV 不能被俘（is_captive 恒 false）")
	_check(
		not fpv.has_method("apply_suppression"),
		"FPV 故意没有 apply_suppression——近失压制先 has_method，攒不起来",
	)
	_check(is_equal_approx(float(fpv.get("suppression")), 0.0), "FPV 的压制读数恒为 0")
	_map.call("issue_order", &"attack", 1)
	_check(
		String(fpv.get("current_order")) == "attack",
		"宏观命令也广播给 FPV（battle_map.issue_order 扫 vehicles 组）",
	)
	_map.call("issue_order", &"hold", 1)

	# ================================================================
	# 2) 脆皮：20 血，没有装甲系数——两发步枪弹击落
	# ================================================================
	var glass = _spawn_fpv(Vector2i(6, 7), 1)
	_check(int(glass.get("hp")) == 20, "初始 20 血（两发步枪弹的命）")
	glass.call("take_damage", 12)
	_check(int(glass.get("hp")) == 8, "12 点步枪弹全额生效（无装甲，20 -> 8）")
	glass.call("take_damage", 12)
	_check(glass.get("is_dead") == true and int(glass.get("hp")) == 0, "第二枪击落")
	var hp_after_death: int = int(glass.get("hp"))
	glass.call("take_damage", 12)
	_check(int(glass.get("hp")) == hp_after_death, "残骸不再掉血（坠毁的也不掉）")

	# ================================================================
	# 3a) 手动俯冲：直线、150px/s、墙挡不住它
	#     fpv(4,10) ---(10,10) 一堵墙--- > 蓝兵(16,10)，全程直线 384px。
	# ================================================================
	_map.call("add_obstacle", Vector2i(10, 10))
	var diver = _spawn_fpv(Vector2i(4, 10), 2)
	var bait = _spawn_soldier(Vector2i(16, 10), 1, 100)
	var row_y: float = diver.global_position.y
	var dist_before: float = diver.global_position.distance_to(bait.global_position)
	diver.set("target", bait)
	diver.set("is_diving", true)
	_check(diver.get("is_diving") == true, "置 target 后 is_diving 翻 true（俯冲状态可观测）")
	await _wait(30)
	# 速度实测：30 帧（0.5s）应走约 75px，夹在 60~90 容忍 CI 机器抖动；
	# 60 的下界同时把"还是侦察机那档 110px/s"排除在外（那只有 55px）。
	var flown: float = dist_before - diver.global_position.distance_to(bait.global_position)
	_check(flown > 60.0 and flown < 90.0, "俯冲速度 150px/s（30 帧实测 %.0fpx）" % flown)
	_check(
		absf(diver.global_position.y - row_y) < 2.0,
		"全程直线：y 没有偏离——不是绕过墙，是从墙顶上过去的",
	)
	_check(
		diver.global_position.distance_to(bait.global_position) < dist_before,
		"与目标的距离在收敛（冲着它去，不是乱飞）",
	)
	# 收刀悬停：is_diving 翻 false 后机体纹丝不动。
	var hover_pos: Vector2 = diver.global_position
	diver.set("is_diving", false)
	await _wait(10)
	_check(
		hover_pos.distance_to(diver.global_position) < 0.5,
		"解除俯冲后原地悬停（velocity 恒 0）",
	)

	# ================================================================
	# 3b) AI 锁定与换目标：先咬最近的 A；A 倒地后换下一个最近的 B
	# ================================================================
	var hunter = _spawn_fpv(Vector2i(18, 10), 2, true)
	var prey_a = _spawn_soldier(Vector2i(19, 10), 1, 100)
	var prey_b = _spawn_soldier(Vector2i(21, 10), 1, 100)
	_check(
		await _wait_until(func (): return hunter.get("target") == prey_a, 40),
		"AI 锁定最近的敌人（A 在 32px，B 在 96px）",
	)
	_check(hunter.get("is_diving") == true, "锁定即俯冲（is_diving = true）")
	# A 被打倒（M5 的倒地语义）：FPV 不撞倒地的人，换下一个。
	prey_a.call("take_damage", 200)
	_check(
		await _wait_until(func (): return hunter.get("target") == prey_b, 60),
		"目标倒地 -> 换下一个最近敌人 B（不把炸药浪费在倒地的人身上）",
	)
	# 收尾：打倒 B、击落 hunter，别让它们去搅后面的场（后面的段要可控的孤立几何）。
	prey_b.call("take_damage", 200)
	hunter.call("take_damage", 24)

	# ================================================================
	# 4) 撞击引爆：伤害衰减 + 溅射 + 友伤 + 大额压制
	#     焦点在 (8,22)：靶兵 +8px、邻兵 +24px、远处 +48px、队友 -16px。
	# ================================================================
	var bomber = _spawn_fpv(Vector2i(8, 22), 2)
	var center: Vector2 = bomber.global_position
	var victim = _spawn_soldier(Vector2i(8, 22), 1, 100)
	victim.global_position = center + Vector2(8.0, 0.0)
	var splash = _spawn_soldier(Vector2i(8, 22), 1, 100)
	splash.global_position = center + Vector2(24.0, 0.0)
	var bystander = _spawn_soldier(Vector2i(8, 22), 1, 100)
	bystander.global_position = center + Vector2(48.0, 0.0)
	var mate = _spawn_soldier(Vector2i(8, 22), 2, 100)
	mate.global_position = center + Vector2(-16.0, 0.0)
	bomber.call("explode")
	_check(int(victim.get("hp")) == 78, "靶兵吃 22 点（8px：中心 25 线性衰减）")
	_check(int(splash.get("hp")) == 84, "24px 的邻兵吃 16 点溅射")
	_check(int(bystander.get("hp")) == 100, "48px 在爆炸半径（40px）外，毫发无损")
	_check(
		int(mate.get("hp")) == 81,
		"16px 的**同队**士兵也吃 19 点——爆炸不认军服（M12 手雷同款语义）",
	)
	_check(
		is_equal_approx(float(victim.get("suppression")), 0.6),
		"爆炸对靶兵施加一次大额压制（0.6）",
	)
	_check(
		is_equal_approx(float(bystander.get("suppression")), 0.0),
		"半径外的士兵不受压制",
	)
	_check(bomber.get("is_dead") == true, "引爆后机体消耗（is_dead = true）")
	_check(
		is_instance_valid(bomber),
		"引爆的机体留焦痕不消失（同坦克残骸，给战场一个交代）",
	)

	# ================================================================
	# 5) 击落不爆：哑弹的证明——残骸对邻兵零伤害
	# ================================================================
	var dud = _spawn_fpv(Vector2i(12, 22), 2)
	var near_ally = _spawn_soldier(Vector2i(12, 22), 1, 100)
	near_ally.global_position = dud.global_position + Vector2(16.0, 0.0)
	dud.call("take_damage", 12)
	dud.call("take_damage", 12)
	_check(dud.get("is_dead") == true, "两发步枪弹（24 点）击落 FPV")
	_check(
		int(near_ally.get("hp")) == 100,
		"击落不引爆：16px 内的邻兵毫发无损（残骸是哑弹）",
	)
	_check(
		is_equal_approx(float(near_ally.get("suppression")), 0.0),
		"坠毁不产生压制（爆炸才吓人，掉下来不吓人）",
	)
	dud.call("explode")
	_check(
		int(near_ally.get("hp")) == 100,
		"死后补一发 explode 也无效——哑弹守卫挡住了（士兵击落它的全部理由）",
	)

	# ================================================================
	# 6) 士兵击落链路：nearby_enemies 收得到，64px 一枪确定性命中
	#    阵形 (24,4) 蓝兵 --64px--> (26,4) 红 FPV：64px × sin(3°) ≈ 3.4px
	#    的最大散布偏移小于 5px 的命中半径，这一枪是确定性的（同 M11 反制）。
	# ================================================================
	var shooter = _spawn_soldier(Vector2i(24, 4), 1, 100)
	var prey = _spawn_fpv(Vector2i(26, 4), 2)
	var perc = PERCEPTION_SCRIPT.new()
	perc.setup(shooter, _map, shooter.get("weapon"), get_tree())
	_check(
		perc.call("nearby_enemies", 96.0).has(prey),
		"perception.nearby_enemies 收得到 FPV（soldier_ai 目标选择零改动就打它）",
	)
	await _wait(2)
	var hit_fpv: bool = bool(shooter.get("weapon").call("try_fire", prey.global_position))
	_check(hit_fpv, "步兵的子弹能命中 FPV（层 1 挂在弹道射线里）")
	_check(int(prey.get("hp")) == 8, "命中后全额掉血（20 -> 8，无装甲系数）")
	await _wait(24)
	shooter.get("weapon").call("try_fire", prey.global_position)
	_check(prey.get("is_dead") == true, "第二枪把它打下来（20 血两发步枪弹）")
	_check(
		not perc.call("nearby_enemies", 96.0).has(prey),
		"坠毁的 FPV 退出敌人列表（不鞭尸，压制/目标计算都不再算它）",
	)

	# ================================================================
	# 7) fpv_threat：距离归一 [0,1]、最近者胜、同队不计、坠毁不吓人
	#    听众在 (28,20)，威胁半径 128px：32px -> 0.75，96px -> 0.25。
	# ================================================================
	var listener = _spawn_soldier(Vector2i(28, 20), 1, 100)
	var ear = PERCEPTION_SCRIPT.new()
	ear.setup(listener, _map, listener.get("weapon"), get_tree())
	var near_fpv = _spawn_fpv(Vector2i(28, 20), 2)
	near_fpv.global_position = listener.global_position + Vector2(32.0, 0.0)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.75),
		"32px 处的敌 FPV 逼近度 0.75（1 - 32/128，线性归一）",
	)
	var far_fpv = _spawn_fpv(Vector2i(28, 20), 2)
	far_fpv.global_position = listener.global_position + Vector2(-96.0, 0.0)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.75),
		"两架同在（32px 与 96px）读最近的那架（0.75 不被 0.25 稀释）",
	)
	near_fpv.global_position = Vector2(160.0, 64.0)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.25),
		"近的飞走后只剩 96px 的（0.25）",
	)
	far_fpv.global_position = listener.global_position + Vector2(-160.0, 0.0)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.0),
		"威胁半径（128px）外的 FPV 不算（160px -> 0）",
	)
	var mate_fpv = _spawn_fpv(Vector2i(28, 20), 1)
	mate_fpv.global_position = listener.global_position + Vector2(32.0, 0.0)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.0),
		"32px 处的同队 FPV 不计（自己的无人机不吓自己）",
	)
	var wreck_fpv = _spawn_fpv(Vector2i(28, 20), 2)
	wreck_fpv.global_position = listener.global_position + Vector2(32.0, 0.0)
	wreck_fpv.call("take_damage", 24)
	_check(
		is_equal_approx(float(ear.call("fpv_threat", 128.0)), 0.0),
		"被击落的 FPV 残骸不吓人（哑弹没有威胁）",
	)

	# ================================================================
	# 8) 坦克也是合法目标：场上离它最近的敌人是坦克 -> 锁定 -> 装甲照减
	# ================================================================
	var rammer = _spawn_fpv(Vector2i(24, 24), 2, true)
	var armor = _spawn_tank(Vector2i(26, 24), 1)
	_check(
		await _wait_until(func (): return rammer.get("target") == armor, 60),
		"场上最近的敌人是坦克 -> 锁定坦克（vehicles 组全员合法目标）",
	)
	_check(rammer.get("is_diving") == true, "锁定坦克即俯冲")
	_check(
		await _wait_until(func (): return rammer.get("is_dead") == true, 120),
		"贴到 16px 引爆（俯冲 + 撞针）",
	)
	var armor_hp: int = int(armor.get("hp"))
	_check(
		armor_hp >= 193 and armor_hp <= 197,
		"坦克挨炸走装甲：中心 25 衰减到约 19，实伤只有约 5（200 -> %d）" % armor_hp,
	)

	# ================================================================
	# 9) 侦察机零扰动：FPV 在场不改变 M11 侦察机的任何行为
	#    （抽 3 条轻量回归：无目击照常巡逻、巡逻真的在动、有目击照常盯梢）
	# ================================================================
	var scout = _spawn_drone(Vector2i(28, 8), 1, true)
	# 4.7.2 实测：set() 收到无类型数组字面量时，对 Array[Vector2] 脚本属性
	# 静默失败——必须先装进类型化局部变量再传（同 drone_test 的 route 同款）。
	var route: Array[Vector2] = [
		_map.world_pos(Vector2i(30, 8)), _map.world_pos(Vector2i(30, 12))
	]
	scout.get_node("DroneAI").set("waypoints", route)
	await _wait(30)
	_check(
		scout.call("current_action") == &"patrol",
		"满场 FPV 的尸体与残骸不搅局：侦察机无目击照常巡逻",
	)
	var scout_start: Vector2 = scout.global_position
	_check(
		await _wait_until(
			func (): return scout_start.distance_to(scout.global_position) > 20.0, 120
		),
		"巡逻真的在动（沿航点位移 > 20px）",
	)
	var spotting = _spawn_soldier(Vector2i(30, 8), 2, 100)
	_check(
		await _wait_until(_action_is(scout, &"track"), 90),
		"有目击照常盯梢（track 1.0 压过 0.4 保底分）",
	)


## 生成一个"无人机当前行为等于 want"的谓词，供 _wait_until 轮询。
func _action_is(drone, want: StringName) -> Callable:
	return func (): return drone.call("current_action") == want
