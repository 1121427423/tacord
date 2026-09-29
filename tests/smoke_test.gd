# 引擎原生 headless 冒烟测试（不依赖任何第三方测试插件）。
# 运行：godot --headless --path . tests/smoke_test.tscn
# 退出码：0 = 全部通过，1 = 有失败项。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

const WALL_X := 8

# 期望的断言总数。测试函数中途报错时 _finish() 可能少跑几条，
# 光看「0 失败」会误判为全绿，所以把总数本身也做成一条断言。
const EXPECTED_CHECKS := 154

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
	await _test_ammo_and_logistics()
	await _test_building_and_fob()
	await _test_captives_and_intel()
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


func _test_ammo_and_logistics() -> void:
	_emit("[弹药与后勤]")
	var gunner = SOLDIER_SCENE.instantiate()
	_map.add_child(gunner)
	gunner.global_position = _map.world_pos(Vector2i(2, 2))
	# 关掉它自己的 AI：这一段要手动控制每一次开火，
	# 否则换弹一完成 AI 就会自己打出去，"弹匣重新装满"这条断言就废了。
	gunner.get_node("SoldierAI").set_process(false)
	var gun = gunner.get_node("Weapon")
	var mag_size: int = int(gun.get("magazine_size"))
	_check(int(gun.get("ammo_in_mag")) == mag_size, "出生时弹匣是满的")
	_check(
		int(gun.call("total_ammo")) == mag_size + int(gun.get("reserve_ammo")),
		"total_ammo = 弹匣 + 备弹"
	)

	gunner.call("try_fire", gunner.global_position + Vector2(100.0, 0.0))
	_check(int(gun.get("ammo_in_mag")) == mag_size - 1, "开一枪少一发")

	# 打空弹匣 -> 自动开始换弹，换弹期间开不了枪。
	gun.set("ammo_in_mag", 1)
	gun.set("_cooldown", 0.0)
	gunner.call("try_fire", gunner.global_position + Vector2(100.0, 0.0))
	_check(int(gun.get("ammo_in_mag")) == 0, "最后一发打完弹匣归零")
	_check(gun.get("is_reloading") == true, "弹匣打空自动开始换弹")
	_check(gun.call("can_fire") == false, "换弹期间开不了枪")

	# 把换弹时间调到 0.3s，30 个物理帧（0.5s）后应当换完。
	gun.set("is_reloading", false)
	gun.set("reload_time", 0.3)
	gun.set("ammo_in_mag", 0)
	var reserve_before: int = int(gun.get("reserve_ammo"))
	gun.call("start_reload")
	for _frame in range(30):
		await get_tree().physics_frame
	_check(gun.get("is_reloading") == false, "换弹计时结束后换弹完成")
	_check(int(gun.get("ammo_in_mag")) == mag_size, "换弹后弹匣重新装满")
	_check(
		int(gun.get("reserve_ammo")) == reserve_before - mag_size,
		"换弹消耗等量备弹（%d -> %d）" % [reserve_before, int(gun.get("reserve_ammo"))]
	)

	# 彻底打光：换不了弹，也开不了枪。
	gun.set("ammo_in_mag", 0)
	gun.set("reserve_ammo", 0)
	_check(gun.call("is_dry") == true, "弹匣与备弹都空 = 彻底打光")
	_check(gun.call("start_reload") == false, "没有备弹就换不了弹")
	_check(
		gunner.call("try_fire", gunner.global_position + Vector2(100.0, 0.0)) == false,
		"打光之后开不了枪"
	)

	# 效用：没弹的人更想找掩体，也更不想推进。
	gunner.call("set_order", "attack")
	var gun_ai = gunner.get_node("SoldierAI")
	gun.set("ammo_in_mag", mag_size)
	gun.set("reserve_ammo", 72)
	var cover_full: float = float(gun_ai.call("_consider_seek_cover"))
	var advance_full: float = float(gun_ai.call("_consider_advance"))
	gun.set("ammo_in_mag", 0)
	gun.set("reserve_ammo", 0)
	_check(
		float(gun_ai.call("_consider_seek_cover")) > cover_full,
		"打光之后更想找掩体（换弹要在掩体后换）"
	)
	_check(
		is_equal_approx(float(gun_ai.call("_consider_advance")), advance_full * 0.4),
		"彻底打光时推进欲望降到 40%"
	)
	gun.set("is_reloading", true)
	_check(
		is_equal_approx(float(gun_ai.call("_ammo_pressure")), 1.0), "正在换弹时弹药压力拉满"
	)
	gun.set("is_reloading", false)

	# 补弹：路过尸体把它的备弹摸走，摸过的尸体摸不出第二遍。
	var corpse = SOLDIER_SCENE.instantiate()
	var looter = SOLDIER_SCENE.instantiate()
	_map.add_child(corpse)
	_map.add_child(looter)
	corpse.global_position = _map.world_pos(Vector2i(6, 2))
	looter.global_position = corpse.global_position + Vector2(20.0, 0.0)
	corpse.call("die")
	var corpse_reserve: int = int(corpse.get_node("Weapon").get("reserve_ammo"))
	var looter_reserve: int = int(looter.get_node("Weapon").get("reserve_ammo"))
	looter.get_node("SoldierAI").call("_try_loot_ammo")
	_check(
		int(looter.get_node("Weapon").get("reserve_ammo")) > looter_reserve,
		"路过尸体能摸到备弹（%d -> %d）"
		% [looter_reserve, int(looter.get_node("Weapon").get("reserve_ammo"))]
	)
	_check(int(corpse.get_node("Weapon").get("reserve_ammo")) == 0, "尸体的备弹被摸空")
	_check(corpse_reserve > 0, "尸体身上原本带着备弹")
	var after_first_loot: int = int(looter.get_node("Weapon").get("reserve_ammo"))
	looter.get_node("SoldierAI").call("_try_loot_ammo")
	_check(
		int(looter.get_node("Weapon").get("reserve_ammo")) == after_first_loot,
		"摸空的尸体摸不出第二遍"
	)

	# 端到端：一场持续交火之后，阵地真的会沉寂下来。
	# 关掉近失压制以隔离弹药机制（否则互相压制会先让双方停火，看不出是打光了）。
	var alpha = SOLDIER_SCENE.instantiate()
	var beta = SOLDIER_SCENE.instantiate()
	_map.add_child(alpha)
	_map.add_child(beta)
	# 清场：前面几节留下的士兵还在游走，随便谁朝这两位开一枪就会把他们压制住，
	# "各自正好打光一个弹匣"就不成立了。这一段只留他们两个。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if unit != alpha and unit != beta:
			unit.call("die")
	alpha.global_position = _map.world_pos(Vector2i(20, 12))
	beta.global_position = _map.world_pos(Vector2i(23, 12))
	alpha.set("team", 2)
	for shooter in [alpha, beta]:
		var w = shooter.get_node("Weapon")
		w.set("magazine_size", 3)
		w.set("ammo_in_mag", 3)
		w.set("reserve_ammo", 0)
		w.set("suppression_per_near_miss", 0.0)
		shooter.call("set_order", "hold")
	for _frame in range(180):
		await get_tree().physics_frame
	var alpha_shots: int = int(alpha.get_node("Weapon").get("shots_fired"))
	var beta_shots: int = int(beta.get_node("Weapon").get("shots_fired"))
	_check(alpha.get_node("Weapon").call("is_dry") == true, "持续交火后甲方打光")
	_check(beta.get_node("Weapon").call("is_dry") == true, "持续交火后乙方打光")
	_check(alpha_shots == 3 and beta_shots == 3, "各自正好打光一个弹匣（%d / %d 发）" % [
		alpha_shots, beta_shots
	])
	for _frame in range(90):
		await get_tree().physics_frame
	_check(
		int(alpha.get_node("Weapon").get("shots_fired")) == alpha_shots
		and int(beta.get_node("Weapon").get("shots_fired")) == beta_shots,
		"打光之后再没有枪声（阵地沉寂）"
	)


func _test_building_and_fob() -> void:
	_emit("[建造与 FOB]")
	var game = get_node_or_null("/root/Game")
	# 清场：上一节只留了 alpha/beta，这一节要一块干净的场地。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		unit.call("die")

	# 1) 落点：可走的格子能放，不可走的拒绝。
	var site = game.call("place_build_site", &"fob", Vector2i(10, 4), 1)
	_check(site != null, "可走的格子上能放下工地")
	_check(site.get("is_built") == false, "刚放下时还没建成")
	_check(is_zero_approx(float(site.call("build_ratio"))), "施工进度从 0 开始")
	_map.add_obstacle(Vector2i(11, 4))
	_check(
		game.call("place_build_site", &"fob", Vector2i(11, 4), 1) == null, "不可走的格子拒绝落点"
	)

	# 2) 施工中只是一堆建材，打不出效果。
	site.call("take_damage", 9999)
	_check(int(site.get("hp")) == int(site.get("max_hp")), "施工中的工地打不出效果")

	# 3) 工时累积与建成：6 人·秒。
	site.call("apply_labor", 3.0, 1.0)
	_check(is_equal_approx(float(site.call("build_ratio")), 0.5), "3 人·秒后进度过半")
	var just_built: bool = site.call("apply_labor", 3.0, 1.0)
	_check(just_built == true, "满 6 人·秒即建成")
	_check(site.get("is_built") == true, "建成后 is_built 为真")
	_check(int(site.get("collision_layer")) == 2, "建成后进入障碍层（能挡子弹）")
	_check(_map.get_terrain(Vector2i(10, 4)) == "blocked", "建成后 A* 会绕开这一格")
	_check(not _map.is_walkable(Vector2i(10, 4)), "建成的一格不可走")
	_check(bool(site.call("is_supply_point")), "建成的 FOB 是弹药补给点")

	# 4) FOB 提高部队上限。
	_check(game.call("fob_count", 1) == 1, "蓝方有 1 座 FOB")
	_check(int(game.call("unit_cap", 1)) == 9, "1 座 FOB 把部队上限从 6 提到 9")

	# 5) 沙袋建成是 cover（真掩体），但不是补给点。
	var bags = game.call("place_build_site", &"sandbag", Vector2i(14, 4), 1)
	bags.call("apply_labor", 99.0, 1.0)
	_check(_map.get_terrain(Vector2i(14, 4)) == "cover", "沙袋建成变成 cover 地形（真掩体）")
	_check(not bool(bags.call("is_supply_point")), "沙袋不是补给点")

	# 6) 补弹：站在建成 FOB 旁边、备弹为空的士兵会慢慢补上。
	var resupplied = SOLDIER_SCENE.instantiate()
	_map.add_child(resupplied)
	resupplied.global_position = _map.world_pos(Vector2i(10, 4)) + Vector2(20.0, 0.0)
	resupplied.get_node("Weapon").set("reserve_ammo", 0)
	for _frame in range(40):
		await get_tree().physics_frame
	_check(
		int(resupplied.get_node("Weapon").get("reserve_ammo")) > 0,
		"站在 FOB 旁边能补到备弹（%d 发）"
		% int(resupplied.get_node("Weapon").get("reserve_ammo"))
	)

	# 7) 打掉这座 FOB：曾经有过、现在全没了 -> 判负。
	site.call("take_damage", 9999)
	_check(int(site.get("hp")) == 0, "建筑血量归零")
	for _frame in range(4):
		await get_tree().process_frame
	_check(game.call("is_team_defeated", 1) == true, "失去最后一座 FOB 即判负")
	_check(_map.get_terrain(Vector2i(10, 4)) == "open", "拆掉后地形恢复可走")
	_check(game.call("fob_count", 1) == 0, "FOB 计数归零")

	# 8) 效用：有工地没修完时施工压过进攻，修完后推进欲望回到满值。
	var builder = SOLDIER_SCENE.instantiate()
	_map.add_child(builder)
	builder.global_position = _map.world_pos(Vector2i(20, 18))
	builder.call("set_order", "attack")
	var builder_ai = builder.get_node("SoldierAI")
	var site2 = game.call("place_build_site", &"sandbag", Vector2i(22, 18), 1)
	var build_want: float = float(builder_ai.call("_consider_build"))
	_check(build_want > 0.0, "有工地没修完时施工欲望大于 0")
	_check(
		build_want > float(builder_ai.call("_consider_advance")),
		"施工欲望压过进攻命令下的推进（%.2f > %.2f）"
		% [build_want, float(builder_ai.call("_consider_advance"))]
	)
	site2.call("apply_labor", 99.0, 1.0)
	_check(
		is_equal_approx(float(builder_ai.call("_consider_advance")), 1.0),
		"工事修完、积压折扣消失后推进欲望回到满值"
	)

	# 9) 端到端：放下工地，士兵自己跑过去把它建起来（M6 的验收标准）。
	var site3 = game.call("place_build_site", &"sandbag", Vector2i(23, 18), 1)
	site3.set("build_cost", 2.0)
	var frames: int = 0
	while site3.get("is_built") == false and frames < 300:
		await get_tree().physics_frame
		frames += 1
	_check(site3.get("is_built") == true, "无人干预下士兵自己跑过去把工地建起来")
	_check(frames < 300, "施工在 5 秒模拟时间内完成（用了 %d 帧）" % frames)


func _test_captives_and_intel() -> void:
	_emit("[俘虏与审讯]")
	var game = get_node_or_null("/root/Game")
	# 清场：上一节留了建成/拆掉的工地和几个士兵，这一节要一块干净的场地。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		unit.call("die")
	game.call("clear_boards")

	# 1) 俘虏状态机。
	var prisoner = SOLDIER_SCENE.instantiate()
	prisoner.set("team", 2)
	_map.add_child(prisoner)
	prisoner.global_position = _map.world_pos(Vector2i(8, 20))
	_check(prisoner.call("surrender", 2) == false, "不能向自己人投降")
	_check(prisoner.call("surrender", 1) == true, "surrender 成功")
	_check(prisoner.get("is_captive") == true, "投降后 is_captive 为真")
	_check(int(prisoner.get("captor_team")) == 1, "俘虏记下了押送方")
	_check(
		prisoner.call("try_fire", prisoner.global_position + Vector2(50.0, 0.0)) == false,
		"俘虏不开枪",
	)
	_check(is_zero_approx(float(prisoner.get("suppression"))), "举手的人不再被压制")
	_check(
		is_equal_approx(float(prisoner.call("effective_speed")), 72.0),
		"俘虏以 0.9 倍速被押着走（80 x 0.9 = 72）",
	)
	_check(prisoner.call("surrender", 1) == false, "已经是俘虏就不能再投一次")

	# 2) 投降的三道门槛：被压制 + 被包围 + 无援，缺一即 0。
	var lonely = SOLDIER_SCENE.instantiate()
	lonely.set("team", 1)
	_map.add_child(lonely)
	lonely.global_position = _map.world_pos(Vector2i(6, 20))
	lonely.call("set_order", "hold")
	var lonely_ai = lonely.get_node("SoldierAI")
	_check(
		is_zero_approx(float(lonely_ai.call("_consider_surrender"))),
		"没人围、没被压制时不想投降",
	)
	var foe_a = SOLDIER_SCENE.instantiate()
	foe_a.set("team", 2)
	_map.add_child(foe_a)
	foe_a.global_position = _map.world_pos(Vector2i(9, 20))
	var foe_b = SOLDIER_SCENE.instantiate()
	foe_b.set("team", 2)
	_map.add_child(foe_b)
	foe_b.global_position = _map.world_pos(Vector2i(6, 22))
	lonely.set("suppression", 0.8)
	_check(
		_map.has_line_of_sight(lonely.global_position, foe_a.global_position)
		and _map.has_line_of_sight(lonely.global_position, foe_b.global_position),
		"两个敌人都与 lonely 通视（「被包围」的前提）",
	)
	_check(
		is_equal_approx(float(lonely_ai.call("_consider_surrender")), 1.0),
		"被包围 + 被压制 + 无援 -> 投降欲望拉满 1.00（prisoner 是俘虏，不算援军）",
	)
	var helper = SOLDIER_SCENE.instantiate()
	helper.set("team", 1)
	_map.add_child(helper)
	helper.global_position = _map.world_pos(Vector2i(5, 20))
	_check(
		is_zero_approx(float(lonely_ai.call("_consider_surrender"))),
		"300px 内有站着的战友就不投降",
	)
	helper.call("die")
	_check(
		is_equal_approx(float(lonely_ai.call("_consider_surrender")), 1.0),
		"援军一死，投降欲望立刻回来",
	)

	# 3) 押送权唯一。
	var guard_a = SOLDIER_SCENE.instantiate()
	_map.add_child(guard_a)
	guard_a.global_position = _map.world_pos(Vector2i(7, 20))
	var guard_b = SOLDIER_SCENE.instantiate()
	_map.add_child(guard_b)
	guard_b.global_position = _map.world_pos(Vector2i(7, 21))
	_check(game.call("claim_escort", prisoner, guard_a) == true, "第一个来的人拿到押送权")
	_check(game.call("escort_of", prisoner) == guard_a, "escort_of 返回押送者本人")
	_check(game.call("claim_escort", prisoner, guard_b) == false, "押送权唯一：第二个人抢不到")
	_check(
		game.call("claim_escort", prisoner, guard_a) == true,
		"同一个人可以续押（leash 断开后的恢复路径）",
	)
	game.call("drop_escort", prisoner, guard_b)
	_check(game.call("escort_of", prisoner) == guard_a, "押送者不匹配时 drop_escort 不动权限")
	game.call("drop_escort", prisoner, guard_a)
	_check(game.call("escort_of", prisoner) == null, "押送者本人放手后权限清空")

	# 4) 审讯的位置约束：必须押到本队建成的 FOB 旁边才问得出话。
	_check(int(game.call("interrogate", prisoner).size()) == 0, "本队还没有 FOB 时审不出情报")
	var blue_fob = game.call("place_build_site", &"fob", Vector2i(4, 20), 1)
	blue_fob.call("apply_labor", 99.0, 1.0)
	var red_fob = game.call("place_build_site", &"fob", Vector2i(26, 20), 2)
	red_fob.call("apply_labor", 99.0, 1.0)
	_check(
		int(game.call("interrogate", prisoner).size()) == 0, "俘虏还离 FOB 很远，审不出情报"
	)
	prisoner.global_position = blue_fob.global_position + Vector2(30.0, 0.0)
	var revealed: Array = game.call("interrogate", prisoner)
	_check(revealed.size() == 1, "押到 FOB 旁边审出 1 处敌方工事")
	_check(
		int(game.call("blackboard", 1).call("structure_count")) == 1, "情报写进了蓝方黑板"
	)
	var known: Dictionary = game.call("blackboard", 1).call(
		"nearest_structure", prisoner.global_position
	)
	_check(
		(known["pos"] as Vector2).distance_to(red_fob.global_position) < 1.0,
		"审出来的正是红方那座 FOB",
	)
	_check(
		int(game.call("blackboard", 2).call("structure_count")) == 0, "红方黑板不受影响"
	)
	_check(
		int(game.call("interrogate", prisoner).size()) == 0, "同一个俘虏审不出第二次"
	)

	# 5) 端到端：俘虏投降 -> 押送者自己跑过去 -> 押回 FOB -> 审出新情报 -> 放人。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		unit.call("die")
	var red_bags = game.call("place_build_site", &"sandbag", Vector2i(24, 22), 2)
	red_bags.call("apply_labor", 99.0, 1.0)
	var victim = SOLDIER_SCENE.instantiate()
	victim.set("team", 2)
	_map.add_child(victim)
	victim.global_position = _map.world_pos(Vector2i(8, 20))
	victim.call("surrender", 1)
	var escort = SOLDIER_SCENE.instantiate()
	escort.set("team", 1)
	_map.add_child(escort)
	escort.global_position = _map.world_pos(Vector2i(7, 20))
	# 循环里每 60 帧留一条现场快照：这条轨迹会原样出现在 CI 的失败信息里，
	# 沙箱读不到 CI 日志，只能靠它定位「超时」到底卡在哪一步。
	var frames: int = 0
	var trace := PackedStringArray()
	while int(game.call("blackboard", 1).call("structure_count")) < 2 and frames < 400:
		await get_tree().physics_frame
		frames += 1
		if frames % 60 == 0:
			var holder = game.call("escort_of", victim)
			trace.append(
				"%d帧 押送者@(%.0f,%.0f) 行为=%s 俘虏@(%.0f,%.0f) 距FOB=%.0f 权限=%s"
				% [
					frames,
					escort.global_position.x,
					escort.global_position.y,
					String(escort.call("current_action")),
					victim.global_position.x,
					victim.global_position.y,
					victim.global_position.distance_to(blue_fob.global_position),
					"无" if holder == null else String(holder.name),
				]
			)
	var scenario_ok: bool = int(game.call("blackboard", 1).call("structure_count")) == 2
	var summary: String = "（%d 帧，现场：%s）" % [frames, " | ".join(trace)]
	_check(scenario_ok, "无人干预下押送 + 审讯跑通：情报从 1 条变成 2 条" + summary)
	_check(frames < 400, "整趟押送在 %.1f 秒模拟时间内完成" % (frames / 60.0) + summary)
	_check(victim.get("is_captive") == false, "情报到手就放人" + summary)


func _finish() -> void:
	_emit("")
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		_emit("  FAIL  断言总数应为 %d，实际只跑到 %d（有测试段没执行完）"
				% [EXPECTED_CHECKS, _checks])
	else:
		_emit("  PASS  断言总数 = %d" % _checks)
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
