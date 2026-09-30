# M15 补给卡车的独立冒烟场景：身段与边界 / 脆皮断供 / 发车条件 /
# 沿路往返与卸弹结算 / 断链趴窝与恢复 / 伏击断供 / 不搅局。
# 第九个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank 40 /
# drone 37 / grenade 49 / fpv 49 / ammo 20 / truck N）——
# 每个里程碑一个场景是 M8 定下的规矩（smoke_test.gd 顶着 1000 行上限）。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"
# ——例如"卸弹"必须同时断言"半径外的兵没加"，只看加上的那半边，
# 漏掉"卡车在给全场发弹"这种实现照样通过。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const TRUCK_SCENE := preload("res://scenes/units/truck.tscn")
const PERCEPTION_SCRIPT := preload("res://scripts/ai/perception.gd")

# 本场景的断言总数。与其余八个场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 31

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://truck_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_truck()
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
		_emit("TRUCK TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("TRUCK TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


## 造士兵：默认关掉 AI——本场景要的全是静止状态下的结算。
func _spawn_soldier(cell: Vector2i, team: int, hp: int = 100):
	var unit = SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	_map.add_child(unit)
	unit.get_node("SoldierAI").set_process(false)
	unit.global_position = _map.world_pos(cell)
	unit.set("hp", hp)
	return unit


## 造卡车。速度/歇班都是 @export，测试调快省帧预算（演示局用默认 45px/s）。
func _spawn_truck(team: int, home: Vector2i, speed: float = 120.0, rest: float = 1.5):
	var truck = TRUCK_SCENE.instantiate()
	truck.set("team", team)
	truck.set("home_cell", home)
	truck.set("move_speed", speed)
	truck.set("depart_rest", rest)
	_map.add_child(truck)
	truck.global_position = _map.world_pos(home)
	return truck


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


## 建一座立刻建成的 FOB（走 game 的正式链路：place + apply_labor）。
func _build_fob(cell: Vector2i, team: int):
	var game = get_node_or_null("/root/Game")
	if game == null:
		return null
	var site = game.call("place_build_site", &"fob", cell, team)
	if site == null:
		return null
	if not bool(site.call("apply_labor", 999.0)):
		return null
	return site


func _test_truck() -> void:
	_emit("[补给卡车]")
	var game = get_node_or_null("/root/Game")

	# ================================================================
	# 1) 身段与边界：和坦克/无人机同一套载具身段——撞得着、救不了
	# ================================================================
	var probe = _spawn_truck(1, Vector2i(0, 20))
	_check(probe.is_in_group(&"vehicles"), "卡车注册在 vehicles 组（感知与命令广播的既有通道）")
	_check(
		not probe.is_in_group(&"soldiers"),
		"卡车**不在** soldiers 组——救援/押送/帐篷/FOB 站桩补弹都看不见它",
	)
	_check(probe.get("is_downed") == false, "卡车永不倒地（is_downed 恒 false）")
	_check(probe.get("is_captive") == false, "卡车不能被俘（is_captive 恒 false）")
	_check(
		not probe.has_method("apply_suppression"),
		"卡车故意没有 apply_suppression——近失压制先 has_method，攒不起来",
	)
	_check(is_equal_approx(float(probe.get("suppression")), 0.0), "卡车的压制读数恒为 0")
	_map.call("issue_order", &"attack", 1)
	_check(
		String(probe.get("current_order")) == "attack",
		"宏观命令也广播给卡车（battle_map.issue_order 扫 vehicles 组）",
	)
	_map.call("issue_order", &"hold", 1)
	if game != null:
		_check(
			game.call("soldiers", -1).find(probe) == -1,
			"game.soldiers() 不统计卡车（编制与战损都只算步兵）",
		)
	else:
		_check(false, "（Game autoload 不在，占位）")
	# 最近友军查询：只有卡车在身边时返回 null，才证明它没被认领。
	var lonely = _spawn_soldier(Vector2i(24, 20), 1, 100)
	var solo_perc = PERCEPTION_SCRIPT.new()
	solo_perc.setup(lonely, _map, lonely.get("weapon"), get_tree())
	var truck_buddy = _spawn_truck(1, Vector2i(26, 20))
	_check(
		solo_perc.call("nearest_standing_ally", 120.0) == null,
		"身边只有卡车时最近友军查询返回 null——没人会去「救」一辆卡车",
	)
	# 帐篷不治卡车：帐篷扫的是 soldiers 组，而且只在 96px 内。
	var tent_site = null
	if game != null:
		tent_site = game.call("place_build_site", &"tent", Vector2i(2, 22), 1)
	if tent_site != null:
		tent_site.call("apply_labor", 999.0)
		probe.set("hp", 10)
		await _wait(40)
		_check(int(probe.get("hp")) == 10, "医疗帐篷不治卡车（_physics_process 扫的是 soldiers 组）")
	else:
		_check(false, "（帐篷建不出来，占位）")

	# ================================================================
	# 2) 脆皮：没有装甲，五发步枪弹（12×5=60）正好打掉一辆
	# ================================================================
	var glass = _spawn_truck(1, Vector2i(0, 18))
	_check(int(glass.get("hp")) == 60, "初始 60 血")
	for _shot in range(4):
		glass.call("take_damage", 12)
	_check(int(glass.get("hp")) == 12, "四发步枪弹后剩 12 血（全额生效，无装甲）")
	glass.call("take_damage", 12)
	_check(glass.get("is_dead") == true and int(glass.get("hp")) == 0, "第五发击毁——断供成立")
	_check(
		glass.get("action") == &"destroyed",
		"击毁后班次状态 destroyed（HUD「已断供」读数的来源）",
	)
	var hp_after: int = int(glass.get("hp"))
	glass.call("take_damage", 12)
	_check(int(glass.get("hp")) == hp_after, "残骸不再掉血")

	# ================================================================
	# 3) 发车条件：没有建成的 FOB 就待在车库；建成即发车。
	#    车库 (0,20)，FOB (6,20)：单程 192px。
	# ================================================================
	# 场地卫生：S1 的两辆探针车收掉——FOB 一建它们也会发车，
	# 后面的班次断言只考本段自己的考生（M12 的教训：场上的活人会干
	# 你意想不到的事）。
	probe.call("take_damage", 60)
	truck_buddy.call("take_damage", 60)
	var hauler = _spawn_truck(1, Vector2i(0, 20))
	var docked_pos: Vector2 = hauler.global_position
	await _wait(40)
	_check(
		hauler.get("action") == &"docked"
			and hauler.global_position.distance_to(docked_pos) < 1.0,
		"没有建成的 FOB -> 卡车待在车库纹丝不动（docked 且零位移）",
	)
	var fob = _build_fob(Vector2i(6, 20), 1)
	_check(fob != null and bool(fob.call("is_supply_point")), "建成一座己方 FOB（发车的前提）")
	_check(
		await _wait_until(func (): return hauler.get("action") == &"outbound", 30),
		"FOB 建成 -> 卡车发车（docked -> outbound）",
	)
	_check(
		await _wait_until(
			func (): return hauler.global_position.distance_to(docked_pos) > 4.0, 40
		),
		"发车后真的在动（位移 > 4px）",
	)

	# ================================================================
	# 4) 沿路往返与卸弹结算：抵达 FOB 96px 内 -> 半径内的兵 +24 备弹，
	#    半径外的兵不加 -> 折返车库 -> docked 起歇班。
	# ================================================================
	var loader = _spawn_soldier(Vector2i(7, 20), 1, 100)
	loader.get("weapon").set("reserve_ammo", 0)
	var far_guy = _spawn_soldier(Vector2i(14, 4), 1, 100)
	far_guy.get("weapon").set("reserve_ammo", 0)
	# 192px ÷ 120px/s = 1.6s = 96 帧；多给余量到 200 帧。
	_check(
		await _wait_until(
			func (): return loader.get("weapon").get("reserve_ammo") >= 24, 200
		),
		"抵达卸弹：FOB 半径内的兵备弹 +24（0 -> 24）",
	)
	_check(
		int(far_guy.get("weapon").get("reserve_ammo")) == 0,
		"半径外（>96px）的兵一枚不加——卡车不是全场发弹机",
	)
	_check(
		await _wait_until(func (): return hauler.get("action") == &"returning", 30),
		"卸完即折返（unload -> returning，不在火线多停）",
	)
	_check(
		await _wait_until(
			func (): return hauler.get("action") == &"docked", 200
		),
		"回到车库转为 docked（一趟闭环完成）",
	)
	# 第二班：歇班 1.5s（测试已调短）后再发车——「固定间隔发下一班」。
	loader.get("weapon").set("reserve_ammo", 0)
	_check(
		await _wait_until(
			func (): return loader.get("weapon").get("reserve_ammo") >= 24, 350
		),
		"歇班后第二班照发照卸（断供没发生，班次循环活着）",
	)

	# ================================================================
	# 5) 断链趴窝与恢复：去程半路建起一座工地（blocked）截断补给线 ->
	#    卡车趴窝在断点；工事被打掉 -> 最多 RETRY_INTERVAL 后重新出发。
	#    换一条 y=16 的车道做实验：S4 的 FOB 已占 (6,20)（建成后 blocked，
	#    同格再 place 会被 is_walkable 拒绝）。
	# ================================================================
	var runner = _spawn_truck(1, Vector2i(0, 16))
	var fob5 = _build_fob(Vector2i(6, 16), 1)
	_check(
		fob5 != null and await _wait_until(
			func (): return runner.get("action") == &"outbound", 30
		),
		"第二辆卡车也发车（断链实验的前提）",
	)
	# 去程半路 (3,16) 建起医疗帐篷：apply_labor 建成即 set_terrain blocked，
	# 卡车沿旧 A* 路径撞墙 -> 位移自检 1.5s 超时 -> 趴窝。
	var blocker = null
	if game != null:
		blocker = game.call("place_build_site", &"tent", Vector2i(3, 16), 1)
	_check(blocker != null and bool(blocker.call("apply_labor", 999.0)), "半路建起一座实体工事（补给线被截断）")
	_check(
		await _wait_until(func (): return bool(runner.get("is_stalled")), 200),
		"路被截断 -> 卡车趴窝在断点（is_stalled = true）",
	)
	# 工事被打掉：_demolish 会把地形还原 open，A* 恢复可走。
	blocker.call("take_damage", 999)
	_check(
		await _wait_until(
			func (): return not bool(runner.get("is_stalled")), 120
		),
		"工事被打掉 -> 趴窝解除（1s 重试节拍内重新出发）",
	)

	# ================================================================
	# 6) 伏击断供：卡车在班次途中被打掉 -> destroyed，
	#    之后 FOB 旁的兵再等不到下一班。
	#    先收掉前两段的车：hauler 的第三班会去它自己的 FOB (6,20)，
	#    不碰本段的 watcher，但留着是悬念——断供实验要的是"全场无车"。
	# ================================================================
	hauler.call("take_damage", 60)
	runner.call("take_damage", 60)
	var ambushed = _spawn_truck(1, Vector2i(0, 12))
	var fob6 = _build_fob(Vector2i(6, 12), 1)
	ambushed.call("take_damage", 60)
	_check(
		ambushed.get("is_dead") == true and ambushed.get("action") == &"destroyed",
		"整班弹药打在车上（60 伤）-> 卡车击毁断供",
	)
	var watcher = _spawn_soldier(Vector2i(7, 12), 1, 100)
	watcher.get("weapon").set("reserve_ammo", 0)
	await _wait(300)  # 5s：远超一整个歇班+单程（1.5s + 1.6s）
	_check(
		int(watcher.get("weapon").get("reserve_ammo")) == 0,
		"断供之后：再等 5 秒也等不来下一班（班次随车消亡）",
	)
	if game != null and fob6 != null:
		_check(
			int(fob6.get("hp")) == 200,
			"FOB 站桩补弹（M6）不受卡车断供影响——两条补给线各管各的",
		)
	else:
		_check(false, "（Game autoload 不在或 FOB 未建成，占位）")
	if game != null:
		game.call("clear_boards")
