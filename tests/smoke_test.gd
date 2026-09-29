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
	await _test_suppression()
	await _test_downed_and_rescue()
	await _test_perception_and_memory()
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
	_map.add_obstacle(Vector2i(2, 20))
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
	# 关掉受害者的还击：否则它的近失弹会把射手压制住（M2 新增机制），
	# "开火次数" 就变成随机结果了。近失压制在 _test_suppression 里单独验证。
	victim.get_node("Weapon").set("max_range", 0.0)
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

	# M3 起血量归零不再直接阵亡，而是进入可救援的倒地状态。
	victim.call("take_damage", 9999)
	_check(
		victim.get("is_downed") == true and victim.get("is_dead") == false,
		"血量归零进入倒地而不是阵亡"
	)


func _test_suppression() -> void:
	_emit("[压制]")
	var subject = SOLDIER_SCENE.instantiate()
	_map.add_child(subject)
	subject.global_position = _map.world_pos(Vector2i(24, 22))
	_check(float(subject.get("suppression")) == 0.0, "初始压制为 0")

	subject.call("apply_suppression", 0.5)
	_check(is_equal_approx(float(subject.get("suppression")), 0.5), "apply_suppression 累积")
	subject.call("apply_suppression", 5.0)
	_check(float(subject.get("suppression")) == 1.0, "压制被夹在 1.0 上限")

	var base_speed: float = float(subject.get("move_speed"))
	var pinned_speed: float = float(subject.call("effective_speed"))
	_check(is_equal_approx(pinned_speed, base_speed * 0.4), "满压制只剩 40% 速度")

	for _frame in range(30):
		await get_tree().physics_frame
	var decayed: float = float(subject.get("suppression"))
	_check(decayed < 1.0 and decayed > 0.5, "压制随时间衰减（30 帧后 %.2f）" % decayed)

	# 效用：满压制时 seek_cover 必须压过 advance（不能硬穿火力区）
	var ai = subject.get_node("SoldierAI")
	subject.call("set_order", "attack")
	subject.call("apply_suppression", 5.0)
	var cover_pinned: float = float(ai.call("_consider_seek_cover"))
	var advance_pinned: float = float(ai.call("_consider_advance"))
	_check(advance_pinned == 0.0, "满压制时推进欲望归零")
	_check(cover_pinned > advance_pinned, "满压制时 seek_cover 高于 advance")

	subject.set("suppression", 0.0)
	var advance_calm: float = float(ai.call("_consider_advance"))
	_check(advance_calm > advance_pinned, "压制解除后推进欲望恢复")

	# 近失判定：一枪同时验证两件事——弹道旁 20px 的人被压制（打不到 7px 半径的身体，
	# 但落在 40px 近失半径内），200px 外的人不受影响。
	# 关掉散布是为了让几何完全确定：strength = 1 - 20/40 = 0.5，压制 = 0.3 * 0.5。
	# 注意 try_fire 的弹道会一直打到 max_range（260px），不是停在瞄准点上。
	var shooter = SOLDIER_SCENE.instantiate()
	var bystander = SOLDIER_SCENE.instantiate()
	var faraway = SOLDIER_SCENE.instantiate()
	shooter.set("team", 2)
	bystander.set("team", 1)
	faraway.set("team", 1)
	_map.add_child(shooter)
	_map.add_child(bystander)
	_map.add_child(faraway)
	shooter.get_node("Weapon").set("spread_degrees", 0.0)
	var line_y: float = _map.world_pos(Vector2i(18, 18)).y
	var aim := Vector2(_map.world_pos(Vector2i(10, 18)).x, line_y)
	shooter.global_position = Vector2(_map.world_pos(Vector2i(4, 18)).x, line_y)
	bystander.global_position = Vector2(aim.x, line_y + 20.0)
	faraway.global_position = Vector2(aim.x, line_y + 200.0)
	shooter.call("try_fire", aim)
	_check(
		is_equal_approx(float(bystander.get("suppression")), 0.15),
		"擦身而过的子弹按距离产生压制（%.3f）" % float(bystander.get("suppression"))
	)
	_check(float(faraway.get("suppression")) == 0.0, "离弹道 200px 不受压制")


func _test_downed_and_rescue() -> void:
	_emit("[倒地与救援]")
	# 清场：前面几节留下的倒地者会干扰救援判定，先判死（死人不算可救援目标）。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit.get("is_downed") == true:
			unit.call("die")

	# 1) 失血致死：把致死时间调到 0.3s，30 个物理帧（0.5s）后应当真的阵亡。
	#    这一步放在医疗兵登场之前，免得 AI 在半路把人救活。
	var bleeder = SOLDIER_SCENE.instantiate()
	_map.add_child(bleeder)
	bleeder.global_position = _map.world_pos(Vector2i(26, 8))
	bleeder.set("bleed_out_time", 0.3)
	bleeder.call("take_damage", 9999)
	_check(is_equal_approx(float(bleeder.get("bleed_timer")), 0.3), "倒地即开始失血计时")
	for _frame in range(30):
		await get_tree().physics_frame
	_check(bleeder.get("is_dead") == true, "无人救治则失血致死")
	_check(bleeder.get("is_downed") == false, "阵亡后不再是可救援的倒地状态")

	# 2) 没人倒地时，救援欲望为 0，进攻命令下推进满值。
	var medic = SOLDIER_SCENE.instantiate()
	_map.add_child(medic)
	medic.global_position = _map.world_pos(Vector2i(24, 6))
	medic.call("set_order", "attack")
	var medic_ai = medic.get_node("SoldierAI")
	medic_ai.set("is_medic", true)
	_check(float(medic_ai.call("_consider_rescue")) == 0.0, "没有倒地友军时救援欲望为 0")
	_check(
		is_equal_approx(float(medic_ai.call("_consider_advance")), 1.0),
		"没有倒地友军时进攻命令下推进欲望满值"
	)

	# 3) 打倒一个友军。
	var casualty = SOLDIER_SCENE.instantiate()
	_map.add_child(casualty)
	casualty.global_position = _map.world_pos(Vector2i(26, 6))
	casualty.call("take_damage", 9999)
	_check(casualty.get("is_downed") == true, "打空血量 -> 倒地")
	_check(int(casualty.get("down_count")) == 1, "倒地次数累加")

	# 4) 倒地的人开不了枪、不吃压制、只能爬。
	_check(
		casualty.call("try_fire", casualty.global_position + Vector2(50.0, 0.0)) == false,
		"倒地不能开火"
	)
	casualty.call("apply_suppression", 1.0)
	_check(float(casualty.get("suppression")) == 0.0, "倒地的人不再累积压制")
	_check(
		is_equal_approx(
			float(casualty.call("effective_speed")), float(casualty.get("move_speed")) * 0.35
		),
		"倒地后只能以 35% 速度爬行"
	)

	# 5) 效用：医疗兵去救人，推进欲望因战友倒地打对折。
	var rescue_medic: float = float(medic_ai.call("_consider_rescue"))
	var advance_now: float = float(medic_ai.call("_consider_advance"))
	_check(is_equal_approx(advance_now, 0.5), "有战友倒地时推进欲望打对折")
	_check(rescue_medic > advance_now, "医疗兵的救援欲望压过推进（%.2f > %.2f）" % [
		rescue_medic, advance_now
	])

	# 6) 同样位置的普通兵救援意愿低于医疗兵（所以去救人的是医疗兵）。
	var rifleman = SOLDIER_SCENE.instantiate()
	_map.add_child(rifleman)
	rifleman.global_position = medic.global_position
	rifleman.call("set_order", "attack")
	var rifle_ai = rifleman.get_node("SoldierAI")
	_check(
		float(rifle_ai.call("_consider_rescue")) < rescue_medic,
		"医疗兵的救援意愿高于普通兵"
	)

	# 7) 倒地后中弹加速失血。
	var before_bleed: float = float(casualty.get("bleed_timer"))
	casualty.call("take_damage", 10)
	_check(float(casualty.get("bleed_timer")) < before_bleed, "倒地后中弹加速失血")

	# 8) 包扎：1 倍速累积 1/3，2 倍速一次补满 3 秒即救活。
	casualty.call("apply_rescue", 1.0, 1.0)
	_check(
		is_equal_approx(float(casualty.call("rescue_ratio")), 1.0 / 3.0),
		"包扎进度按 1 倍速累积到 1/3"
	)
	var just_revived: bool = casualty.call("apply_rescue", 1.0, 2.0)
	_check(just_revived == true, "医疗兵 2 倍速一次补满并触发救活")
	_check(casualty.get("is_downed") == false, "救活后不再倒地")
	_check(int(casualty.get("hp")) == 30, "救活时血量回到 30")
	_check(int(casualty.get("max_hp")) == 85, "每次倒地留下永久虚弱（100 -> 85）")

	# 9) 倒满 3 次之后，再倒一次才真正阵亡。
	for _i in range(3):
		casualty.call("take_damage", 9999)
		casualty.call("revive")
	_check(int(casualty.get("down_count")) == 4, "连续倒地计数到 4")
	_check(casualty.get("is_dead") == true, "倒满 3 次后再倒即阵亡")

	# 10) 端到端：全程不做任何干预，看队友自己跑过去把伤员拖救活（M3 的验收标准）。
	#     只断言结果不断言"是谁救的"——医疗兵和附近的普通兵都会去，谁先到算谁。
	var doc = SOLDIER_SCENE.instantiate()
	var hurt = SOLDIER_SCENE.instantiate()
	_map.add_child(doc)
	_map.add_child(hurt)
	doc.global_position = _map.world_pos(Vector2i(20, 3))
	hurt.global_position = _map.world_pos(Vector2i(23, 3))
	doc.call("set_order", "attack")
	doc.get_node("SoldierAI").set("is_medic", true)
	hurt.call("take_damage", 9999)
	var frames: int = 0
	while hurt.get("is_downed") == true and frames < 900:
		await get_tree().physics_frame
		frames += 1
	_check(
		hurt.get("is_downed") == false and hurt.get("is_dead") == false,
		"无人干预下队友自主完成拖救并救活伤员"
	)
	_check(frames < 900, "救援在 15 秒模拟时间内完成（用了 %d 帧）" % frames)


func _test_perception_and_memory() -> void:
	_emit("[感知与记忆]")
	var game = get_node_or_null("/root/Game")
	_check(game != null and game.has_method("blackboard"), "Game 自动加载提供小队黑板")
	# 清掉前几节留下的枪声记忆：否则"最近的一声"可能是别的测试打的，断言就不确定了。
	game.call("clear_boards")
	# 前几节的红方士兵在 M4 之后会靠记忆/巡逻四处游走，位置不可预测。
	# 本节要验证的是"看不见敌人"，所以先把他们清掉；noisemaker 是本节新建的，不受影响。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) == 2:
			unit.call("die")

	# ---- 黑板本体：不依赖场景 ----
	var board := Blackboard.new()
	var dummy = SOLDIER_SCENE.instantiate()
	_map.add_child(dummy)
	board.report_sighting(dummy, Vector2(300.0, 400.0))
	_check(board.has_sighting(dummy), "上报目击后黑板记得这个敌人")
	var memory: Dictionary = board.memory_of(dummy)
	_check(
		memory.get("pos") == Vector2(300.0, 400.0) and memory.get("kind") == &"sighting",
		"记忆带回最后已知位置与来源"
	)
	board.advance(Blackboard.MEMORY_TTL + 1.0)
	_check(not board.has_sighting(dummy), "超过保鲜期的记忆被遗忘")

	var shot_id: int = board.report_gunshot(Vector2(500.0, 500.0), 2)
	_check(
		int(board.nearest_enemy_gunshot(Vector2(400.0, 500.0), 1, 520.0).get("id", -1)) == shot_id,
		"听得见半径内的敌队枪声"
	)
	_check(
		board.nearest_enemy_gunshot(Vector2(400.0, 500.0), 2, 520.0).is_empty(),
		"自己队的枪声不算威胁"
	)
	_check(
		board.nearest_enemy_gunshot(Vector2.ZERO, 1, 100.0).is_empty(),
		"超出听力半径的枪声听不见"
	)
	board.report_sighting(dummy, Vector2(300.0, 400.0))
	_check(board.best_memory(1).get("kind") == &"sighting", "best_memory 优先返回目击而不是枪声")

	# ---- 端到端 1：看不见敌人时朝枪声转头 ----
	# 放在地图角落，保证 260px 射程内没有敌人（否则它会开火而不是听）。
	var listener = SOLDIER_SCENE.instantiate()
	_map.add_child(listener)
	listener.global_position = _map.world_pos(Vector2i(30, 22))
	# hold 命令：效用上 hold(0.54) 压过 advance(0.15)，它不会走开，
	# 于是多等几帧也不会让 _follow_path 把朝向覆盖掉。
	listener.call("set_order", "hold")
	var shot_pos: Vector2 = listener.global_position + Vector2(0.0, -100.0)
	game.call("hear_gunshot", shot_pos, 2)
	# 等两个 process 帧：节点是在本次迭代里 add_child 的，第一帧未必轮到它 _process。
	await get_tree().process_frame
	await get_tree().process_frame
	var facing: Vector2 = listener.get("facing")
	_check(
		facing.dot(Vector2(0.0, -1.0)) > 0.9,
		"看不见敌人时朝枪声转头（facing=%.2f,%.2f）" % [facing.x, facing.y]
	)

	# ---- 端到端 2：真的开一枪，敌队的人听得见（验证枪声分发路由）----
	# 两人相距 320px：在 520px 听力内，但在 260px 射程外，所以听者只能听不能打。
	var noisemaker = SOLDIER_SCENE.instantiate()
	var hearer = SOLDIER_SCENE.instantiate()
	noisemaker.set("team", 2)
	_map.add_child(noisemaker)
	_map.add_child(hearer)
	noisemaker.global_position = _map.world_pos(Vector2i(4, 20))
	hearer.global_position = _map.world_pos(Vector2i(14, 20))
	noisemaker.call("try_fire", noisemaker.global_position + Vector2(0.0, -200.0))
	await get_tree().process_frame
	await get_tree().process_frame
	var to_shooter: Vector2 = (noisemaker.global_position - hearer.global_position).normalized()
	_check(
		(hearer.get("facing") as Vector2).dot(to_shooter) > 0.9,
		"敌队开火后，看不见他的人也会转向声源"
	)

	# ---- 端到端 3：毫无情报也要搜索，不能原地发呆 ----
	var searcher = SOLDIER_SCENE.instantiate()
	_map.add_child(searcher)
	searcher.global_position = _map.world_pos(Vector2i(28, 20))
	searcher.call("set_order", "attack")
	var start_pos: Vector2 = searcher.global_position
	for _frame in range(60):
		await get_tree().physics_frame
	var walked: float = searcher.global_position.distance_to(start_pos)
	_check(walked > 8.0, "进攻命令下会朝情报/巡逻点移动而不是发呆（走了 %.0f px）" % walked)


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
