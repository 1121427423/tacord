# M11 侦察无人机的独立冒烟场景：身段与边界 / 脆皮 / 飞行 / AI 两选一 / 侦察 / 不搅局。
# 第五个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank 40 / drone N）——
# 每个里程碑一个场景是 M8 定下的规矩（smoke_test.gd 顶着 gdlint 的 1000 行上限）。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"
# ——例如"穿墙"必须同时钉住"抵达"与"没绕路"，只看抵达可能只是绕过去了。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const DRONE_SCENE := preload("res://scenes/units/drone.tscn")
const PERCEPTION_SCRIPT := preload("res://scripts/ai/perception.gd")

# 本场景的断言总数。与其余四个场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 37

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://drone_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_drone()
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
		_emit("DRONE TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("DRONE TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
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


## 造无人机。ai_on=false 时关掉 DroneAI 的物理思考——注意是
## set_physics_process：DroneAI 的循环挂在 _physics_process 上
## （与 TankAI 同款；soldier_ai 才是挂在 _process 上的 set_process）。
## 机体的自动侦察与飞行不关——它们是"传感器"，不是决策。
func _spawn_drone(cell: Vector2i, team: int, ai_on: bool = false):
	var drone = DRONE_SCENE.instantiate()
	drone.set("team", team)
	_map.add_child(drone)
	if not ai_on:
		drone.get_node("DroneAI").set_physics_process(false)
	drone.global_position = _map.world_pos(cell)
	return drone


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


func _test_drone() -> void:
	_emit("[侦察无人机]")
	var game = get_node_or_null("/root/Game")

	# ================================================================
	# 1) 身段与边界：和坦克同一套载具身段——看得见、打得着、救不了
	# ================================================================
	var drone = _spawn_drone(Vector2i(6, 6), 1)
	_check(drone.is_in_group(&"vehicles"), "无人机注册在 vehicles 组（感知与命令广播的既有通道）")
	_check(
		not drone.is_in_group(&"soldiers"),
		"无人机**不在** soldiers 组——救援/补给/帐篷治疗都看不见它",
	)
	_check(drone.get("is_downed") == false, "无人机永不倒地（is_downed 恒 false）")
	_check(drone.get("is_captive") == false, "无人机不能被俘（is_captive 恒 false）")
	_check(
		not drone.has_method("apply_suppression"),
		"无人机故意没有 apply_suppression——近失压制先 has_method，攒不起来",
	)
	_check(is_equal_approx(float(drone.get("suppression")), 0.0), "无人机的压制读数恒为 0")
	_map.call("issue_order", &"attack", 1)
	_check(
		String(drone.get("current_order")) == "attack",
		"宏观命令也广播给无人机（battle_map.issue_order 扫 vehicles 组）",
	)
	_map.call("issue_order", &"hold", 1)

	# ================================================================
	# 2) 脆皮：没有装甲系数，步枪弹 12 点就是 12 点
	# ================================================================
	_check(int(drone.get("hp")) == 30, "初始 30 血")
	drone.call("take_damage", 12)
	_check(int(drone.get("hp")) == 18, "12 点步枪弹全额生效（无装甲，30 -> 18）")
	drone.call("take_damage", 12)
	_check(int(drone.get("hp")) == 6, "再挨一枪只剩 6 血（30 血挡不住三发）")
	drone.call("take_damage", 12)
	_check(drone.get("is_dead") == true and int(drone.get("hp")) == 0, "第三枪坠毁")
	var hp_after_death: int = int(drone.get("hp"))
	drone.call("take_damage", 12)
	_check(int(drone.get("hp")) == hp_after_death, "残骸不再掉血（坠毁的也不掉）")

	# ================================================================
	# 3) 飞行：直线过去，A* 不参与——墙挡不住它
	#    drone_fly(4,10) ---(10,10) 一堵墙--- > (16,10)，全程直线 384px。
	# ================================================================
	_map.call("add_obstacle", Vector2i(10, 10))
	var flyer = _spawn_drone(Vector2i(4, 10), 1)
	var row_y: float = flyer.global_position.y
	_check(bool(flyer.call("fly_to", _map.world_pos(Vector2i(16, 10)))), "fly_to 接受目标")
	_check(not flyer.call("has_arrived"), "刚出发还没到")
	_check(
		await _wait_until(flyer.has_arrived, 260),
		"约 3.5 秒后抵达墙另一侧（384px ÷ 110px/s，无路径可绕也得直线过）",
	)
	_check(
		absf(flyer.global_position.y - row_y) < 2.0,
		"全程直线：y 没有偏离——不是绕过墙，是从墙顶上过去的",
	)
	# 速度实测：30 帧（0.5s）应走约 55px，夹在 40~70 容忍 CI 机器抖动。
	var runner = _spawn_drone(Vector2i(4, 18), 1)
	var runner_start: Vector2 = runner.global_position
	runner.call("fly_to", _map.world_pos(Vector2i(20, 18)))
	await _wait(30)
	var flown: float = runner_start.distance_to(runner.global_position)
	_check(flown > 40.0 and flown < 70.0, "巡航速度 110px/s（30 帧实测 %.0fpx）" % flown)
	# 坠毁的机体不再接受飞行指令。
	_check(not bool(drone.call("fly_to", Vector2.ZERO)), "坠毁后 fly_to 被拒绝")

	# ================================================================
	# 4) Utility 两选一：patrol / track。此刻场上还没有任何敌人，
	#    所有同队机体互相都看不见——正好用来测纯巡逻。
	# ================================================================
	var scout = _spawn_drone(Vector2i(4, 4), 1, true)
	scout.get_node("DroneAI").set(
		"waypoints", [_map.world_pos(Vector2i(12, 4)), _map.world_pos(Vector2i(12, 8))]
	)
	# 先等过至少一个思考节拍（0.4s = 24 帧），否则断言的只是初始值。
	await _wait(30)
	_check(
		scout.call("current_action") == &"patrol",
		"没有目击 -> 行为 patrol（0.4 保底分接管）",
	)
	var scout_start: Vector2 = scout.global_position
	_check(
		await _wait_until(
			func (): return scout_start.distance_to(scout.global_position) > 20.0, 120
		),
		"巡逻真的在动（沿航点位移 > 20px）",
	)
	# 放一个看得见的敌人：track 1.0 压过 0.4。
	# 侦察节拍 0.4s + 思考节拍 0.4s，90 帧窗口足够轮到它。
	var spotted = _spawn_soldier(Vector2i(7, 6), 2, 100)
	_check(
		await _wait_until(_action_is(scout, &"track"), 90), "有目击 -> 行为 track"
	)
	await _wait(90)
	var watch_dist: float = scout.global_position.distance_to(spotted.global_position)
	_check(
		watch_dist > 60.0 and watch_dist < 220.0,
		"盯梢是绕着看不是贴脸（盘旋半径 120，实测 %.0fpx）" % watch_dist,
	)
	# 目击丢了（敌人挪出 260px）-> 目击过期 -> 回巡逻。
	spotted.global_position = _map.world_pos(Vector2i(30, 22))
	_check(
		await _wait_until(_action_is(scout, &"patrol"), 200),
		"目击过期（1.2s 无新鲜目击）-> 回到 patrol",
	)

	# ================================================================
	# 5) 侦察：墙后的敌人写进本队黑板——这是无人机的全部价值
	#    drone_eye(6,14) ---(8,14) 一堵墙--- > 红兵(10,14)，同排 128px。
	#    上一节的自动侦察已经把目击写进过黑板，这里必须先清。
	# ================================================================
	if game != null:
		game.call("clear_boards")
	_map.call("add_obstacle", Vector2i(8, 14))
	var eye = _spawn_drone(Vector2i(6, 14), 1)
	var hidden = _spawn_soldier(Vector2i(10, 14), 2, 100)
	_check(
		not _map.call("has_line_of_sight", eye.global_position, hidden.global_position),
		"前提钉住：那堵墙确实挡住了地面视线（无人机不该受这堵墙约束）",
	)
	var found: int = eye.call("scan_now")
	_check(found == 1, "俯瞰发现墙后的敌人（scan_now 返回 1）")
	if game != null:
		var board = game.call("blackboard", 1)
		_check(
			bool(board.call("has_sighting", hidden)),
			"墙后的敌人写进本队黑板（目击不带通视判定）",
		)
		var memory: Dictionary = board.call("memory_of", hidden)
		_check(
			(memory.get("pos", Vector2.ZERO) as Vector2).distance_to(hidden.global_position)
			< 1.0,
			"记忆的位置就是敌人的真实位置",
		)
		var best: Dictionary = board.call("best_memory", 1)
		_check(
			(best.get("pos", Vector2.ZERO) as Vector2).distance_to(hidden.global_position)
			< 1.0,
			"步兵的「最后已知位置」链路贯通——best_memory 查得到天上喂的目击",
		)
		var far_foe = _spawn_soldier(Vector2i(28, 14), 2, 100)
		eye.call("scan_now")
		_check(
			not bool(board.call("has_sighting", far_foe)),
			"超出 260px 侦察半径的敌人不报（28,14 离 6,14 有 704px）",
		)
		var mate = _spawn_soldier(Vector2i(7, 14), 1, 100)
		eye.call("scan_now")
		_check(
			not bool(board.call("has_sighting", mate)),
			"同队单位不报——黑板只记敌人",
		)
		_check(
			game.call("blackboard", 2).call("best_memory", 2).is_empty(),
			"侦察是单向的：这一切红方毫不知情（红队黑板没有任何记忆）",
		)
	else:
		_check(false, "（Game autoload 不在，占位）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")

	# ================================================================
	# 6) 不搅局：不该被步兵逻辑认领；但步兵的子弹打得下它
	# ================================================================
	if game != null:
		var all_soldiers: Array = game.call("soldiers", -1)
		_check(
			all_soldiers.find(drone) == -1 and all_soldiers.find(eye) == -1,
			"game.soldiers() 不统计无人机（编制与战损都只算步兵）",
		)
	else:
		_check(false, "（Game autoload 不在，占位）")
	# 最近友军查询：只放一架同队无人机在身边，返回 null 才说明它没被认领。
	var lonely = _spawn_soldier(Vector2i(24, 20), 1, 100)
	var solo_perc = PERCEPTION_SCRIPT.new()
	solo_perc.setup(lonely, _map, lonely.get("weapon"), get_tree())
	var drone_ally = _spawn_drone(Vector2i(26, 20), 1)
	_check(
		solo_perc.call("nearest_standing_ally", 100.0) == null,
		"100px 内只有无人机时，最近友军查询返回 null——它不会被派去「救」一架飞机",
	)
	# 医疗帐篷不治无人机：帐篷扫的是 soldiers 组，而且只在 96px 内。
	var site = null
	if game != null:
		site = game.call("place_build_site", &"tent", Vector2i(24, 22), 1)
	if site != null:
		var tent_ok: bool = bool(site.call("apply_labor", 999.0))
		_check(
			tent_ok and bool(site.call("is_medical_point")),
			"医疗帐篷建成（离无人机 90px，在 96px 治疗半径内）",
		)
		drone_ally.set("hp", 10)
		await _wait(40)
		_check(
			int(drone_ally.get("hp")) == 10,
			"帐篷不治无人机（_physics_process 扫的是 soldiers 组）",
		)
	else:
		_check(false, "医疗帐篷建不出来")
		_check(false, "（占位：保持断言总数不变）")
	# 反制：步兵的子弹打得下无人机——它是脆皮，不是无敌的观察者。
	# 阵形 (16,4) 蓝兵 --64px--> (18,4) 红无人机：64px × sin(3°) ≈ 3.4px
	# 的最大散布偏移小于 5px 的命中半径，这一枪是确定性的。
	var shooter = _spawn_soldier(Vector2i(16, 4), 1, 100)
	var prey = _spawn_drone(Vector2i(18, 4), 2)
	await _wait(2)
	var hit_drone: bool = bool(shooter.get("weapon").call("try_fire", prey.global_position))
	_check(hit_drone, "步兵的子弹能命中无人机（层 1 挂在弹道射线里）")
	_check(
		int(prey.get("hp")) == 18,
		"命中后全额掉血（30 -> 18，无装甲系数）",
	)
	if game != null:
		game.call("clear_boards")


## 生成一个"无人机当前行为等于 want"的谓词，供 _wait_until 轮询。
func _action_is(drone, want: StringName) -> Callable:
	return func (): return drone.call("current_action") == want
