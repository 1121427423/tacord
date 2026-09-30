# M9 医疗帐篷与呼救气泡的独立冒烟场景。
# 沿用 M8 定下的规矩：每个里程碑一个测试场景——smoke_test.gd 911 行、
# mobility_test.gd 351 行都还活着，但三个里程碑就顶到 gdlint 的 1000 行上限了。
# 三个场景都必须退出码 0，CI 才算绿。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

# 本场景的断言总数。与另外两个场景同样的理由：只看"0 失败"会漏掉中途 abort。
# M16（倒地自救 + 爬行中还击）扩到 34：救援主题的延伸归这个场景管。
const EXPECTED_CHECKS := 34

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://medic_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_medic_tent()
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
		_emit("MEDIC TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("MEDIC TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


## 造一个士兵。默认关掉 AI：本场景要的全部是"静止状态下发生的事"
## （帐篷治谁、气泡跳不跳），AI 会把人挪走、把断言变成竞速。
func _spawn(cell: Vector2i, team: int, hp: int = 100):
	var unit = SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	_map.add_child(unit)
	unit.get_node("SoldierAI").set_process(false)
	unit.global_position = _map.world_pos(cell)
	unit.set("hp", hp)
	return unit


func _test_medic_tent() -> void:
	_emit("[医疗帐篷与呼救气泡]")
	var game = get_node_or_null("/root/Game")
	var tent_cell := Vector2i(20, 12)

	# ---- 1) 落点与建成 ----
	var site = game.call("place_build_site", &"tent", tent_cell, 1)
	_check(site != null, "医疗帐篷可以落点")
	_check(
		not bool(site.call("is_medical_point")), "施工中还不算治疗点"
	)

	# 伤员就站在旁边（隔一格，帐篷那格建成后不可走）。
	var wounded = _spawn(Vector2i(21, 12), 1, 50)
	_check(int(wounded.get("hp")) == 50, "伤员初始 50 血")
	var hp_before_build: int = int(wounded.get("hp"))
	for _frame in range(30):
		await get_tree().physics_frame
	_check(
		int(wounded.get("hp")) == hp_before_build,
		"施工中的帐篷不治人（它还不是治疗点）",
	)

	# 施工中的工地只是一堆建材（_ready 里 collision_layer = 0），不挡视线。
	_check(
		_map.has_line_of_sight(_map.world_pos(Vector2i(18, 12)), _map.world_pos(Vector2i(22, 12))),
		"施工中的工地不挡视线——两点通视",
	)
	_check(
		bool(site.call("apply_labor", 999.0)), "工时给足，一次调用即建成"
	)
	_check(bool(site.call("is_medical_point")), "建成后是治疗点")
	_check(
		_map.get_terrain(tent_cell) == "blocked",
		"建成占 blocked 地形（帆布包人进不去、也挡视线）",
	)
	_check(site.call("label") == "医疗帐篷", "标签显示医疗帐篷")
	_check(
		not bool(site.call("is_supply_point")), "帐篷不是弹药补给点（那是 FOB 的事）"
	)

	# ---- 2) 视线与寻路：建成后它和 FOB 一样是实体工事 ----
	_check(
		not _map.has_line_of_sight(
			_map.world_pos(Vector2i(18, 12)), _map.world_pos(Vector2i(22, 12))
		),
		"建成帐篷后隔一个格子就不通视了",
	)
	var path: Array = _map.find_path(Vector2i(18, 12), Vector2i(22, 12))
	var through_tent: bool = false
	for step in path:
		if step == tent_cell:
			through_tent = true
	_check(
		not path.is_empty() and not through_tent, "A* 绕开帐篷那一格，不会规划穿墙路径"
	)

	# ---- 3) 治疗光环：只治"己方 + 站着 + 半径内 + 没满血" ----
	var healed: int = wounded.get("hp")
	for _frame in range(40):
		await get_tree().physics_frame
	healed = int(wounded.get("hp"))
	_check(
		healed > hp_before_build,
		"建成后旁边己方伤员开始回血（%d -> %d）" % [hp_before_build, healed],
	)

	# 超出 96px 半径不治（6 格 = 192px）。
	var far = _spawn(Vector2i(26, 12), 1, 50)
	var enemy = _spawn(Vector2i(22, 12), 2, 50)
	var capt = _spawn(Vector2i(20, 11), 1, 50)
	_check(bool(capt.call("surrender", 2)), "这个兵举手成了俘虏")
	var downed = _spawn(Vector2i(20, 13), 1, 100)
	downed.call("take_damage", 9999)
	_check(downed.get("is_downed") == true, "这个兵被打成倒地")

	for _frame in range(40):
		await get_tree().physics_frame
	_check(int(far.get("hp")) == 50, "超出半径的伤员不治")
	_check(int(enemy.get("hp")) == 50, "敌方伤员不治")
	_check(int(capt.get("hp")) == 50, "俘虏不治")
	_check(
		int(downed.get("hp")) <= 0 and downed.get("is_downed") == true,
		"倒地的不治——帐篷不代劳，拖救还得靠队友",
	)

	# 治到满血就停，不会越过 max_hp。
	wounded.set("hp", 98)
	for _frame in range(90):
		await get_tree().physics_frame
	_check(int(wounded.get("hp")) == 100, "回血封顶在 max_hp，不会治超")

	# ---- 4) 不碰胜负与编制：帐篷不是 FOB ----
	_check(game.call("fob_count", 1) == 0, "帐篷不算 FOB，fob_count 仍是 0")
	_check(game.call("unit_cap", 1) == 6, "帐篷不加部队上限（仍 6 人）")
	site.call("take_damage", 9999)
	_check(
		game.call("is_team_defeated", 1) == false,
		"打掉帐篷不会判负——判负只认「曾经有过的 FOB 全没了」",
	)

	# ---- 5) 呼救气泡：只在倒地时跳 ----
	_check(
		is_equal_approx(float(wounded.get("_bubble_phase")), 0.0),
		"还站着的人气泡相位恒为 0（根本不画）",
	)
	var caller = _spawn(Vector2i(24, 16), 1, 100)
	caller.call("take_damage", 9999)
	var phase_before: float = float(caller.get("_bubble_phase"))
	for _frame in range(30):
		await get_tree().physics_frame
	_check(
		float(caller.get("_bubble_phase")) > phase_before,
		"倒地后气泡相位在走——那个感叹号是活的",
	)
	caller.call("revive")
	var phase_at_stand: float = float(caller.get("_bubble_phase"))
	for _frame in range(30):
		await get_tree().physics_frame
	_check(
		is_equal_approx(float(caller.get("_bubble_phase")), phase_at_stand),
		"站起来后气泡停跳",
	)

	# ---- 6) 倒地自救（M16）：还爬得动就爬向掩体，爬行中用手枪还击 ----
	# 伤员 A(10,4) AI 开、倒地；左边一格木箱 (7,4) 是唯一的掩体，
	# 威胁 (4,4) 的红兵把它逼向箱子背后——爬行方向必须是向左。
	# 这个兵必须 AI 开（反射挂在 SoldierAI._process 上）。
	var crawler = _spawn(Vector2i(10, 4), 1, 100)
	crawler.get_node("SoldierAI").set_process(true)
	crawler.call("take_damage", 9999)
	_check(crawler.get("is_downed") == true, "自救段前提：伤员 A 倒地了")
	_map.call("add_obstacle", Vector2i(7, 4))
	var threat = _spawn(Vector2i(4, 4), 2, 100)
	var crawl_start: Vector2 = crawler.global_position
	for _frame in range(240):
		await get_tree().physics_frame
	_check(
		crawler.global_position.distance_to(crawl_start) < 2.0,
		"倒地后前 5s 一动不动（先喊救兵，给 M3 救援链让路）",
	)
	var crawl_moved: bool = false
	for _frame in range(600):
		if crawler.global_position.distance_to(crawl_start) > 20.0:
			crawl_moved = true
			break
		await get_tree().physics_frame
	_check(crawl_moved, "满 5s 没人来救 -> 拖着身子开始爬（位移 > 20px）")
	_check(
		crawler.global_position.x < crawl_start.x,
		"爬向掩体：向木箱背后挪（x 在减小），不是乱爬",
	)
	# 爬行中的还击：伤员 B 倒地但装上了爬行路径（模拟"在爬"，无论自救
	# 还是被队友拖），对 64px 内有通视的敌人开枪——这条走廊的散布偏移
	# 64×sin3°≈3.4px < 命中半径 7px，命中是确定性的（drone_test 同款算术）。
	# AI 关掉：这里直测 try_fire 的放宽条件，别让反射抢戏。
	var drifter = _spawn(Vector2i(16, 10), 1, 100)
	drifter.call("take_damage", 9999)
	_check(drifter.get("is_downed") == true, "自救段前提：伤员 B 倒地了")
	_check(
		not bool(drifter.call("try_fire", _map.world_pos(Vector2i(14, 10)))),
		"静止倒地的照旧开不了枪（M3 的断言原地复钉）",
	)
	var foe = _spawn(Vector2i(14, 10), 2, 100)
	drifter.call("move_to_cell", Vector2i(16, 12))
	var foe_hp_before: int = int(foe.get("hp"))
	var hit: bool = bool(drifter.call("try_fire", foe.global_position))
	_check(
		hit and int(foe.get("hp")) == foe_hp_before - 12,
		"爬行中（无论自救还是被拖）用手枪还击——命中且全额伤害（64px 确定性走廊）",
	)
	# 倒地爬着爬着失血阵亡的人，从阵亡那刻起彻底停住——
	# soldier 的 die() 会 stop_moving，AI 的 is_dead 早退也在反射之前。
	var stop_pos: Vector2 = crawler.global_position
	crawler.set("bleed_timer", 0.05)
	for _frame in range(30):
		await get_tree().physics_frame
	_check(
		crawler.get("is_dead") == true
			and crawler.global_position.distance_to(stop_pos) < 2.0,
		"失血阵亡后不再挪动——尸体不会自己爬（容差 2px 盖住 die 前的尾帧）",
	)
	if game != null:
		game.call("clear_boards")
