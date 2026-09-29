# M10 装甲车的独立冒烟场景：身段与边界 / 装甲 / 双向交火 / 机动 / Utility 三选一。
# 第四个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank N）——smoke_test.gd
# 911 行顶着 gdlint 的 1000 行上限，每个里程碑一个场景是 M8 定下的规矩。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"——
# 这一稿推翻了五条，全部记在提交信息里。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const TANK_SCENE := preload("res://scenes/units/tank.tscn")
const PERCEPTION_SCRIPT := preload("res://scripts/ai/perception.gd")

# 本场景的断言总数。与其余三个场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 43

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://tank_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_tank()
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
		_emit("TANK TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("TANK TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
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


## 造坦克。ai_on=false 时关掉 TankAI 的物理思考——注意是
## set_physics_process：TankAI 的循环挂在 _physics_process 上，光
## set_process 冻不住它（soldier_ai 才是挂在 _process 上的，两者不一样）。
func _spawn_tank(cell: Vector2i, team: int, ai_on: bool = false):
	var tank = TANK_SCENE.instantiate()
	tank.set("team", team)
	_map.add_child(tank)
	if not ai_on:
		tank.get_node("TankAI").set_physics_process(false)
	tank.global_position = _map.world_pos(cell)
	return tank


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


func _test_tank() -> void:
	_emit("[装甲车]")
	var game = get_node_or_null("/root/Game")

	# ================================================================
	# 1) 身段与边界：它是个"单位"，但不是"士兵"
	# ================================================================
	var tank = _spawn_tank(Vector2i(6, 6), 1)
	_check(tank.is_in_group(&"vehicles"), "载具注册在 vehicles 组")
	_check(
		not tank.is_in_group(&"soldiers"),
		"载具**不在** soldiers 组——救援/补给/帐篷治疗都看不见它",
	)
	_check(tank.get("is_downed") == false, "载具永不倒地（is_downed 恒 false）")
	_check(tank.get("is_captive") == false, "载具不能被俘（is_captive 恒 false）")
	_check(
		not tank.has_method("apply_suppression"),
		"载具故意没有 apply_suppression——近失压制先 has_method，攒不起来",
	)
	_check(is_equal_approx(float(tank.get("suppression")), 0.0), "载具的压制读数恒为 0")
	_map.call("issue_order", &"attack", 1)
	_check(
		String(tank.get("current_order")) == "attack",
		"宏观命令也广播给载具（battle_map.issue_order 扫 vehicles 组）",
	)
	_map.call("issue_order", &"hold", 1)

	# ================================================================
	# 2) 装甲：小口径只啃掉四分之一
	# ================================================================
	_check(int(tank.get("hp")) == 200, "初始 200 血")
	tank.call("take_damage", 12)
	_check(int(tank.get("hp")) == 197, "12 点步枪弹打上去只掉 3 血（12×0.25）")
	tank.call("take_damage", 35)
	_check(int(tank.get("hp")) == 188, "35 点肉搏掉 9 血（8.75 四舍五入）")
	tank.call("take_damage", 9999)
	_check(tank.get("is_dead") == true and int(tank.get("hp")) == 0, "伤害溢出即击毁")
	var hp_after_death: int = int(tank.get("hp"))
	tank.call("take_damage", 12)
	_check(int(tank.get("hp")) == hp_after_death, "残骸不再掉血（死人也不掉）")

	# ================================================================
	# 3) 士兵看得见它：感知层多扫的那个组起作用了
	#    阵形：friend(14,14) 蓝 —— alive_tank(14,10) 红 —— foe(14,6) 蓝
	#    同列 128px，全部在步枪 260px 与坦克 380px 射程之内。
	# ================================================================
	var foe = _spawn_soldier(Vector2i(14, 6), 2, 100)
	var friend = _spawn_soldier(Vector2i(14, 14), 1, 100)
	var alive_tank = _spawn_tank(Vector2i(14, 10), 2)
	# 一辆**活着的**同队坦克：只有"同队"这一个条件能把它排除掉，
	# 拿被打残的那辆来测会被 is_dead 先行过滤，断言是假的。
	var mate_tank = _spawn_tank(Vector2i(18, 14), 1)
	var perc = PERCEPTION_SCRIPT.new()
	perc.setup(friend, _map, friend.get("weapon"), get_tree())
	var enemies: Array = perc.call("nearby_enemies", 400.0)
	_check(alive_tank in enemies, "nearby_enemies 把敌方坦克算作敌人")
	_check(not (mate_tank in enemies), "同队的坦克不算敌人（活着也一样）")
	var best = perc.call("visible_enemy", 400.0)
	_check(best == alive_tank, "visible_enemy 在通视时返回那辆坦克")
	_check(
		float(perc.call("danger_pressure", 400.0)) > 0.0, "敌方坦克在近处时危险压力不为 0"
	)

	# ================================================================
	# 4) 双向交火
	# ================================================================
	# 蓝方士兵 -> 红方坦克：子弹打在装甲上只留 1/4。
	var tank_hp_before: int = int(alive_tank.get("hp"))
	var did_hit: bool = bool(friend.get("weapon").call("try_fire", alive_tank.global_position))
	_check(did_hit, "士兵的子弹能命中坦克（layer 1 + take_damage 天然打通）")
	_check(int(alive_tank.get("hp")) == tank_hp_before - 3, "命中后坦克只掉 3 血")
	_check(
		is_equal_approx(float(alive_tank.get("suppression")), 0.0), "挨打不会给载具攒压制"
	)

	# 红方坦克 -> 蓝方士兵：40 点主炮 + 命中附带的压制。
	# 反过来说，开火方与目标必须不同队——weapon 的近失压制会跳过同队，
	# 打自己人只会掉血、不会掉压制，那条断言就是假的。
	var soldier_hp_before: int = int(foe.get("hp"))
	var gun = alive_tank.get("weapon")
	gun.call("try_fire", foe.global_position)
	await _wait(2)
	_check(int(foe.get("hp")) < soldier_hp_before, "坦克主炮打中士兵（40 点，士兵没有装甲）")
	_check(
		float(foe.get("suppression")) > 0.2,
		"中弹同时吃到接近满额的压制（命中目标离弹道≈0，强度接近 1）",
	)
	_check(int(gun.get("ammo_in_mag")) == 5, "主炮打掉一发：弹匣 6 -> 5")

	# ================================================================
	# 5) 机动：同一张 AStar2D，没有第二套寻路
	# ================================================================
	var runner = _spawn_tank(Vector2i(4, 4), 1)
	var start_pos: Vector2 = runner.global_position
	_check(runner.call("move_to_cell", Vector2i(6, 4)), "能对可走格规划路径")
	_check(not runner.call("has_arrived"), "刚规划完还没走到")
	_check(
		await _wait_until(runner.has_arrived, 150), "约 1.6 秒后抵达（64px ÷ 40px/s）"
	)
	_check(start_pos.distance_to(runner.global_position) > 30.0, "确实挪了窝")
	# 给地图加一堵墙，再考"绕行"与"打不通"两条。
	_map.call("add_obstacle", Vector2i(9, 4))
	_check(
		not runner.call("move_to_cell", Vector2i(9, 4)),
		"目标格被封死时规划失败（allow_partial_path=false）",
	)
	_check(runner.call("move_to_cell", Vector2i(14, 4)), "绕开障碍仍能规划成功")
	var cells: Array = _map.call("find_path", Vector2i(6, 4), Vector2i(14, 4))
	var through_wall: bool = false
	for step in cells:
		if step == Vector2i(9, 4):
			through_wall = true
	_check(not cells.is_empty() and not through_wall, "路径绕开那堵墙")

	# ================================================================
	# 6) Utility 三选一：hold / advance / engage
	#    地图到这一步只有 (9,4) 一堵墙，y=18 一线全空。
	# ================================================================
	var ai_tank = _spawn_tank(Vector2i(4, 18), 1, true)
	var ai_pos: Vector2 = ai_tank.global_position
	ai_tank.set("objective", Vector2i(14, 18))
	# 先等过至少一个思考节拍（0.4s = 24 帧），否则断言的只是初始值。
	await _wait(30)
	_check(
		ai_tank.call("current_action") == &"hold",
		"无敌人 + 待命命令 -> 行为 hold（0.6×0.15=0.09 输给保底 0.25）",
	)
	_check(ai_pos.distance_to(ai_tank.global_position) < 2.0, "hold 期间不挪窝")
	# 命令 attack：0.6×1.0=0.6 赢过 0.25，开始推进。
	ai_tank.set("current_order", "attack")
	_check(
		await _wait_until(_action_is(ai_tank, &"advance"), 60),
		"进攻命令 -> 行为 advance",
	)
	_check(
		await _wait_until(
			func (): return ai_pos.distance_to(ai_tank.global_position) > 20.0, 120
		),
		"推进真的在动（位移 > 20px）",
	)
	# 放一个看得见的敌人：engage 1.0 压过一切，而且立刻停车开炮。
	# 目标点放在推进路线前方，免得坦克一头撞进 30px 肉搏圈。
	var victim = _spawn_soldier(Vector2i(10, 18), 2, 100)
	_check(
		await _wait_until(_action_is(ai_tank, &"engage"), 60), "有通视敌人 -> 行为 engage"
	)
	var hold_pos: Vector2 = ai_tank.global_position
	var victim_hp: int = int(victim.get("hp"))
	_check(
		await _wait_until(func (): return int(victim.get("hp")) < victim_hp, 90),
		"engage 后坦克自主开炮，士兵掉血",
	)
	_check(
		hold_pos.distance_to(ai_tank.global_position) < 40.0,
		"交战期间停车射击（位移远小于推进段）",
	)

	# ================================================================
	# 7) 不搅局：载具不该被步兵那套逻辑认领
	# ================================================================
	if game != null:
		var all_soldiers: Array = game.call("soldiers", -1)
		_check(
			all_soldiers.find(tank) == -1 and all_soldiers.find(alive_tank) == -1,
			"game.soldiers() 不统计载具（编制与战损都只算步兵）",
		)
	else:
		_check(false, "（Game autoload 不在，占位）")
	# 最近友军查询：只放一个同队坦克在身边，返回 null 才说明它没被认领。
	var lonely = _spawn_soldier(Vector2i(24, 20), 1, 100)
	var solo_perc = PERCEPTION_SCRIPT.new()
	solo_perc.setup(lonely, _map, lonely.get("weapon"), get_tree())
	var tank_ally = _spawn_tank(Vector2i(26, 22), 1)
	_check(
		solo_perc.call("nearest_standing_ally", 100.0) == null,
		"100px 内只有坦克时，最近友军查询返回 null——它不会被派去「救」一辆车",
	)
	# 医疗帐篷不治载具：帐篷扫的是 soldiers 组，而且只在 96px 内。
	# game 是 autoload，正常一定在；但 null 时调用会中止整个协程，
	# 后面的断言一条都不跑——正是 EXPECTED_CHECKS 守卫要抓的那类坑。
	var site = null
	if game != null:
		site = game.call("place_build_site", &"tent", Vector2i(24, 22), 1)
	if site != null:
		tank_ally.set("hp", 50)
		var tent_ok: bool = bool(site.call("apply_labor", 999.0))
		_check(tent_ok and bool(site.call("is_medical_point")), "医疗帐篷建成（64px 外）")
		await _wait(40)
		_check(
			int(tank_ally.get("hp")) == 50,
			"帐篷不治载具（_physics_process 扫的是 soldiers 组）",
		)
	else:
		_check(false, "医疗帐篷建不出来")
		_check(false, "（占位：保持断言总数不变）")
	if game != null:
		game.call("clear_boards")


## 生成一个"坦克当前行为等于 want"的谓词，供 _wait_until 轮询。
func _action_is(tank, want: StringName) -> Callable:
	return func (): return tank.call("current_action") == want
