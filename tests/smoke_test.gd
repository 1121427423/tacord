# 引擎原生 headless 冒烟测试（不依赖任何第三方测试插件）。
# 运行：godot --headless --path . tests/smoke_test.tscn
# 退出码：0 = 全部通过，1 = 有失败项。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

const WALL_X := 8

# BattleMap 实例，不标注类型以便鸭子调用其查询接口。
var _map = null

var _checks: int = 0
var _failures: int = 0

# 结果同时写入文件：Godot 自己设置 stdout 缓冲，进程异常退出时管道里的输出会丢，
# 落盘 + flush 才能保证 CI 一定读得到崩溃前的最后一行。
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://smoke_result.log", FileAccess.WRITE)
	_setup()
	_test_coordinates()
	_test_terrain()
	_test_pathfinding()
	_test_utility_ai()
	# 以下测试依赖物理空间（射线查询），必须等物理帧。
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_cover_geometry()
	await _test_combat()
	_finish()


func _setup() -> void:
	_map = MAP_SCENE.instantiate()
	add_child(_map)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		_emit("  PASS  %s" % label)
	else:
		_failures += 1
		_emit("  FAIL  %s" % label)


# ---------------------------------------------------------------- 纯逻辑测试


func _test_coordinates() -> void:
	_emit("[坐标换算]")
	var cell := Vector2i(5, 7)
	var world: Vector2 = _map.world_pos(cell)
	_check(_map.cell_at(world) == cell, "cell_at(world_pos(cell)) 往返一致")
	_check(world == Vector2(176.0, 240.0), "格子中心 = (x+0.5)*cell_size")
	_check(_map.in_bounds(Vector2i(0, 0)), "(0,0) 在界内")
	_check(not _map.in_bounds(Vector2i(-1, 0)), "(-1,0) 越界")
	_check(not _map.in_bounds(Vector2i(int(_map.grid_size.x), 0)), "第 grid_size.x 列越界")
	_check(_map.cell_at(Vector2(-1.0, -1.0)) == Vector2i(-1, -1), "负坐标向下取整")


func _test_terrain() -> void:
	_emit("[地形]")
	_check(_map.is_walkable(Vector2i(1, 1)), "默认 open 地形可走")
	_map.set_terrain(Vector2i(3, 3), &"blocked")
	_check(_map.get_terrain(Vector2i(3, 3)) == "blocked", "set_terrain / get_terrain 一致")
	_check(not _map.is_walkable(Vector2i(3, 3)), "blocked 不可走")
	_check(_map.get_terrain(Vector2i(-5, -5)) == "blocked", "越界格子视为 blocked")
	_map.set_terrain(Vector2i(3, 3), &"open")

	var obstacles: Node = _map.get_node("Obstacles")
	var before: int = obstacles.get_child_count()
	_emit("  -- before add_obstacle")
	_map.add_obstacle(Vector2i(2, 20))
	_emit("  -- after add_obstacle")
	# 回归测试：cover 格必须不可走，否则 A* 会规划出穿墙路径。
	_check(not _map.is_walkable(Vector2i(2, 20)), "add_obstacle 的 cover 格不可走（防穿墙路径）")
	_check(obstacles.get_child_count() == before + 1, "add_obstacle 生成了碰撞体")
	obstacles.get_child(obstacles.get_child_count() - 1).queue_free()
	_map.set_terrain(Vector2i(2, 20), &"open")


func _test_pathfinding() -> void:
	_emit("[AStar2D 寻路]")
	var rows: int = int(_map.grid_size.y)
	for y in range(rows):
		_map.set_terrain(Vector2i(WALL_X, y), &"blocked")
	var sealed: Array = _map.find_path(Vector2i(2, 2), Vector2i(20, 2))
	_check(sealed.is_empty(), "整面墙封死时 find_path 返回空")

	_map.set_terrain(Vector2i(WALL_X, 12), &"open")
	var path: Array = _map.find_path(Vector2i(2, 2), Vector2i(20, 2))
	_check(not path.is_empty(), "留缺口后能找到路径")
	if not path.is_empty():
		_check(path[0] == Vector2i(2, 2), "路径起点 = 请求起点")
		_check(path[path.size() - 1] == Vector2i(20, 2), "路径终点 = 请求终点")
		var through_gap: bool = false
		for step in path:
			if step == Vector2i(WALL_X, 12):
				through_gap = true
		_check(through_gap, "路径确实从缺口绕过墙体")

	for y in range(rows):
		_map.set_terrain(Vector2i(WALL_X, y), &"open")


func _test_utility_ai() -> void:
	_emit("[Utility AI]")
	var ai := UtilityAI.new()
	var low = func() -> float:
		return 0.2
	var high = func() -> float:
		return 0.9
	ai.register_consideration(&"low", low, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR)
	ai.register_consideration(&"high", high, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR)
	_check(ai.evaluate() == &"high", "evaluate 选出得分最高的行为")
	_check(is_equal_approx(ai.score_of(&"high"), 0.9), "score_of 返回归一化得分")

	ai.set_weight(&"high", 0.0)
	_check(ai.evaluate() == &"low", "权重归零后改选另一个行为")

	ai.set_weight(&"high", 1.0)
	ai.stickiness = 0.8
	_check(ai.evaluate(&"low") == &"low", "行为粘性能压住微小的分数差")
	ai.stickiness = 0.0
	_check(ai.evaluate(&"low") == &"high", "取消粘性后回到最优行为")

	var monotonic: bool = true
	var previous: float = -1.0
	for i in range(11):
		var value: float = ai._apply_curve(float(i) / 10.0, UtilityAI.CurveType.TANH, 1.5)
		if value < previous:
			monotonic = false
		previous = value
	_check(monotonic, "tanh 响应曲线单调不减")


# ---------------------------------------------------------------- 依赖物理的测试


func _test_cover_geometry() -> void:
	_emit("[掩体几何评估]")
	for y in range(8, 14):
		_map.add_obstacle(Vector2i(12, y))
	await get_tree().physics_frame
	await get_tree().physics_frame

	var threats := [_map.world_pos(Vector2i(4, 10))]
	var behind: float = _map.cover_score(Vector2i(13, 10), threats)
	var exposed: float = _map.cover_score(Vector2i(9, 10), threats)
	_check(_map.has_line_of_sight(_map.world_pos(Vector2i(9, 10)), threats[0]), "空旷处与威胁通视")
	_check(
		not _map.has_line_of_sight(_map.world_pos(Vector2i(13, 10)), threats[0]),
		"墙体后方不通视"
	)
	_check(behind > exposed, "墙后掩体得分高于空旷处（%.2f > %.2f）" % [behind, exposed])

	# 核心机制：敌人绕到另一侧后，同一处掩体立刻失效。
	var flanked := [_map.world_pos(Vector2i(20, 10))]
	var after_flank: float = _map.cover_score(Vector2i(13, 10), flanked)
	_check(after_flank < behind, "被绕侧翼后同一掩体得分下降（%.2f < %.2f）" % [after_flank, behind])

	var best: Vector2i = _map.find_cover_cell(Vector2i(16, 10), threats, 6)
	_check(best != Vector2i(-1, -1), "find_cover_cell 找得到掩体")
	_check(_map.is_walkable(best), "找到的掩体格必须可走")


func _test_combat() -> void:
	_emit("[交火]")
	var shooter = SOLDIER_SCENE.instantiate()
	var victim = SOLDIER_SCENE.instantiate()
	shooter.set("team", 2)
	victim.set("team", 1)
	_map.add_child(shooter)
	_map.add_child(victim)
	shooter.global_position = _map.world_pos(Vector2i(4, 4))
	victim.global_position = _map.world_pos(Vector2i(10, 4))
	shooter.call("set_order", "hold")
	victim.call("set_order", "hold")

	var hp_before: int = int(victim.get("hp"))
	for _frame in range(180):
		await get_tree().physics_frame
		if int(victim.get("hp")) < hp_before:
			break

	var shots: int = int(shooter.get_node("Weapon").get("shots_fired"))
	var hp_after: int = int(victim.get("hp"))
	_check(shots > 0, "Weapon 开过枪（shots_fired=%d）" % shots)
	_check(hp_after < hp_before, "无遮挡面对面时命中掉血（%d -> %d）" % [hp_before, hp_after])

	victim.call("take_damage", 9999)
	_check(victim.get("is_dead") == true, "血量归零触发 die()")


func _finish() -> void:
	_emit("")
	if _failures == 0:
		_emit("SMOKE TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("SMOKE TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _emit(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null
