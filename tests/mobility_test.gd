# M8 机动与近战的独立冒烟场景：翻越 / 伏地 / 滑铲 / 肉搏的引擎内验证。
# 与 smoke_test 分开是因为那个文件已经 1000 行的上限，而且每个里程碑一个场景，
# 后面的里程碑才有地方落脚。两个场景都必须退出码 0，CI 才算绿。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

# 本场景的断言总数。与 smoke_test 同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 39

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://mobility_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_mobility_and_melee()
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
		_emit("  FAIL  断言总数应为 %d，实际只跑到 %d（有测试段没执行完）"
				% [EXPECTED_CHECKS, _checks])
	else:
		_emit("  PASS  断言总数 = %d" % _checks)
	if _failures == 0:
		_emit("MOBILITY TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("MOBILITY TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


func _test_mobility_and_melee() -> void:
	_emit("[机动与近战]")
	var game = get_node_or_null("/root/Game")
	# 清场：上一节留了俘虏与押送者，这一节要一块干净的场地。
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		unit.call("die")

	# ---- 1) 翻越：直线被一格矮墙挡住时跳过去，而不是绕一大圈 ----
	_map.add_obstacle(Vector2i(4, 10))
	await get_tree().physics_frame
	_check(not _map.is_walkable(Vector2i(4, 10)), "矮墙那一格不可走")
	var vaulter = SOLDIER_SCENE.instantiate()
	_map.add_child(vaulter)
	vaulter.global_position = _map.world_pos(Vector2i(3, 10))
	_check(vaulter.call("move_to_cell", Vector2i(7, 10)), "翻越路线也算一条有效路径")
	var saw_vault: bool = false
	var frames: int = 0
	while not vaulter.call("has_arrived") and frames < 300:
		if vaulter.get("is_vaulting") == true:
			saw_vault = true
		await get_tree().physics_frame
		frames += 1
	_check(saw_vault, "途中确实进入了腾空状态（is_vaulting）")
	_check(
		vaulter.call("has_arrived"), "跳过矮墙后照常到达目的地（用了 %d 帧）" % frames
	)
	_check(
		_map.cell_at(vaulter.global_position) == Vector2i(7, 10),
		"落点是目标格而不是矮墙那一格"
	)

	# 反例：换成 blocked（不可翻的整墙）就只认绕行，绝不腾空。
	var blockers: Node = _map.get_node("Obstacles")
	blockers.get_child(blockers.get_child_count() - 1).queue_free()
	_map.set_terrain(Vector2i(4, 10), &"blocked")
	await get_tree().physics_frame
	vaulter.global_position = _map.world_pos(Vector2i(3, 10))
	vaulter.call("stop_moving")
	_check(vaulter.call("move_to_cell", Vector2i(7, 10)), "整墙也绕得过去")
	saw_vault = false
	frames = 0
	while not vaulter.call("has_arrived") and frames < 300:
		if vaulter.get("is_vaulting") == true:
			saw_vault = true
		await get_tree().physics_frame
		frames += 1
	_check(vaulter.call("has_arrived"), "绕行也能到达")
	_check(not saw_vault, "blocked 是整墙，不该翻越（走的是绕行）")
	_map.set_terrain(Vector2i(4, 10), &"open")

	# ---- 2) 姿态：命中轮廓、速度、开火能力 ----
	var subject = SOLDIER_SCENE.instantiate()
	_map.add_child(subject)
	subject.global_position = _map.world_pos(Vector2i(28, 2))
	var weapon = subject.get_node("Weapon")

	subject.set("posture", Soldier.POSTURE_PRONE)
	_check(
		is_equal_approx(_hit_radius(subject), 3.0), "伏地把命中轮廓从 7 收到 3"
	)
	_check(
		is_equal_approx(float(subject.call("effective_speed")), 24.0),
		"伏地只剩 30% 速度（80 x 0.3 = 24）",
	)
	var shots_before: int = int(weapon.get("shots_fired"))
	subject.call("try_fire", subject.global_position + Vector2(100.0, 0.0))
	_check(
		int(weapon.get("shots_fired")) > shots_before,
		"趴着照样开枪——伏地是射击姿势，不是投降",
	)

	subject.set("posture", Soldier.POSTURE_STAND)
	subject.set("posture", Soldier.POSTURE_SLIDE)
	_check(
		is_equal_approx(_hit_radius(subject), 4.0), "滑铲把命中轮廓从 7 收到 4"
	)
	_check(
		is_equal_approx(float(subject.call("effective_speed")), 136.0),
		"滑铲时冲到 170% 速度（80 x 1.7 = 136）",
	)
	# 先把上一枪的冷却清零，否则这条断言会因为"子弹还没装好"而空转，
	# 滑铲真的开不了枪也证明不了。
	weapon.set("_cooldown", 0.0)
	shots_before = int(weapon.get("shots_fired"))
	var slide_shot: bool = bool(
		subject.call("try_fire", subject.global_position + Vector2(100.0, 0.0))
	)
	_check(
		not slide_shot and int(weapon.get("shots_fired")) == shots_before,
		"滑行途中开不了枪（人是腾空的）",
	)
	_check(float(subject.get("slide_cooldown")) > 0.0, "滑铲记了冷却")
	subject.set("posture", Soldier.POSTURE_STAND)
	subject.set("posture", Soldier.POSTURE_SLIDE)
	_check(
		subject.get("posture") == Soldier.POSTURE_STAND,
		"冷却没过时连着按第二次滑铲无效",
	)

	# 一走就自动站起来：起身不需要 AI 干预。
	subject.set("posture", Soldier.POSTURE_PRONE)
	subject.call("move_to_cell", Vector2i(26, 4))
	for _frame in range(6):
		await get_tree().physics_frame
	_check(
		subject.get("posture") == Soldier.POSTURE_STAND,
		"趴着的人一开始走就自动站直",
	)

	# ---- 3) 肉搏 ----
	var brawler = SOLDIER_SCENE.instantiate()
	var target = SOLDIER_SCENE.instantiate()
	target.set("team", 2)
	_map.add_child(brawler)
	_map.add_child(target)
	brawler.global_position = _map.world_pos(Vector2i(26, 6))
	target.global_position = brawler.global_position + Vector2(20.0, 0.0)
	var brawler_weapon = brawler.get_node("Weapon")
	var ammo_before: int = int(brawler_weapon.call("total_ammo"))
	_check(int(target.get("hp")) == 100, "肉搏目标满血")
	_check(
		bool(brawler_weapon.call("try_melee", target)), "贴身 20px 肉搏打中"
	)
	_check(int(target.get("hp")) == 65, "一记枪托 35 点伤害（100 -> 65）")
	_check(
		int(brawler_weapon.call("total_ammo")) == ammo_before, "肉搏不消耗弹药"
	)
	_check(
		not bool(brawler_weapon.call("try_melee", target)),
		"肉搏有冷却，同一瞬间打不出第二下",
	)
	for _frame in range(40):
		await get_tree().physics_frame
		if bool(brawler_weapon.call("can_melee")):
			break
	_check(bool(brawler_weapon.call("can_melee")), "冷却转好之后又能打")

	# 射程外打不着、打不了倒地的、也打不了自己人。
	target.global_position = brawler.global_position + Vector2(40.0, 0.0)
	_check(
		not bool(brawler_weapon.call("try_melee", target)), "40px 超出肉搏半径，打不着"
	)
	target.global_position = brawler.global_position + Vector2(20.0, 0.0)
	target.call("take_damage", 9999)
	_check(target.get("is_downed") == true, "目标被打成倒地")
	_check(
		not bool(brawler_weapon.call("try_melee", target)),
		"不鞭尸也不补刀：倒地的目标不挨枪托",
	)
	_check(
		not bool(brawler_weapon.call("try_melee", brawler)), "枪托不认军服，API 更得认（不误伤友军）"
	)

	# ---- 4) 打分：三个新考虑因素的触发条件 ----
	# 这是独立场景，smoke_test 里那列掩体并不存在——"旁边有掩体就不趴"那条断言
	# 全靠这里自己搭一列 cover。
	for y in range(8, 14):
		_map.add_obstacle(Vector2i(12, y))
	await get_tree().physics_frame
	# 上一段等冷却的几十帧里 target 可能朝 subject 开过枪，等这一帧走完再清零，
	# 否则"打光之后肉搏分更高"会把压制打折也算进比较里。
	subject.set("suppression", 0.0)
	var ai = subject.get_node("SoldierAI")
	var tactics = ai.get("_tactics")
	_check(tactics != null, "tactics.gd 已挂到 SoldierAI 上")

	# 肉搏
	subject.global_position = _map.world_pos(Vector2i(28, 2))
	var close_foe = SOLDIER_SCENE.instantiate()
	close_foe.set("team", 2)
	_map.add_child(close_foe)
	close_foe.global_position = subject.global_position + Vector2(20.0, 0.0)
	close_foe.call("set_order", "hold")
	subject.call("set_order", "hold")
	var melee_score: float = float(tactics.call("score_melee"))
	_check(melee_score > 0.0, "敌人贴到 20px 内时肉搏分 > 0")
	close_foe.global_position = subject.global_position + Vector2(120.0, 0.0)
	_check(
		is_zero_approx(float(tactics.call("score_melee"))),
		"敌人走远之后肉搏分归零",
	)
	close_foe.global_position = subject.global_position + Vector2(20.0, 0.0)
	var wet_score: float = float(tactics.call("score_melee"))
	brawler_weapon.call("set", "reserve_ammo", 0)
	brawler_weapon.call("set", "ammo_in_mag", 0)
	# 把 subject 的枪也打空，验证"打光之后肉搏分更高"。
	weapon.call("set", "reserve_ammo", 0)
	weapon.call("set", "ammo_in_mag", 0)
	var dry_score: float = float(tactics.call("score_melee"))
	_check(dry_score > wet_score, "打光子弹之后肉搏分更高（%.2f > %.2f）" % [dry_score, wet_score])

	# 扑倒
	_check_prone_scoring(tactics, subject)

	# 滑铲。先把冷却清掉——滑铲冷却是 2.45 秒，而前面几步总共只模拟了不到 1 秒，
	# 不清零的话这条断言测的是"冷却还没过"，不是"待命命令下不滑铲"。
	subject.set("slide_cooldown", 0.0)
	subject.set("suppression", 0.0)
	subject.call("set_order", "hold")
	_check(
		is_zero_approx(float(tactics.call("score_slide"))),
		"待命命令下不滑铲（滑铲是推进的加速，不是默认动作）",
	)
	subject.call("set_order", "attack")
	_check(
		float(tactics.call("score_slide")) > 0.0,
		"进攻命令 + 火力威胁下才滑铲",
	)

	# ---- 5) 端到端：被压制又没地方躲，自己趴下；压制散了自己起来 ----
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		unit.call("die")
	var pinned = SOLDIER_SCENE.instantiate()
	_map.add_child(pinned)
	pinned.global_position = _map.world_pos(Vector2i(28, 2))
	pinned.call("set_order", "hold")
	pinned.call("apply_suppression", 1.0)
	var prone_frames: int = 0
	while pinned.get("posture") != Soldier.POSTURE_PRONE and prone_frames < 120:
		# 压制会以 0.22/s 自然衰减，这里持续补一点，免得这条断言变成
		# "AI 反应够不够快"的赛跑而不是"趴不趴"的验证。
		pinned.call("apply_suppression", 0.3)
		await get_tree().physics_frame
		prone_frames += 1
	_check(
		pinned.get("posture") == Soldier.POSTURE_PRONE,
		"被打得抬不起头、身边又没掩体时自己趴下（%d 帧）" % prone_frames,
	)
	pinned.set("suppression", 0.0)
	var rise_frames: int = 0
	while pinned.get("posture") != Soldier.POSTURE_STAND and rise_frames < 60:
		await get_tree().physics_frame
		rise_frames += 1
	_check(
		pinned.get("posture") == Soldier.POSTURE_STAND,
		"压制散了自己爬起来（%d 帧）" % rise_frames,
	)
	if game != null:
		game.call("clear_boards")


## 命中轮廓 = 碰撞圆半径。用 get() 逐层取，避免静态类型卡在 Shape2D 上。
func _hit_radius(unit) -> float:
	var shape = unit.get_node("CollisionShape2D").get("shape")
	return float(shape.get("radius"))


## 扑倒的三个触发条件分三条验证：没压制不趴、有掩体不趴、又压制又没掩体才趴。
func _check_prone_scoring(tactics, subject) -> void:
	var open_spot := Vector2i(28, 2)  # 附近没有任何 cover 地形
	var cover_spot := Vector2i(14, 10)  # 紧挨着本场景自建的 (12,8..13) 掩体列
	subject.global_position = _map.world_pos(open_spot)
	subject.set("suppression", 0.0)
	_check(
		is_zero_approx(float(tactics.call("score_prone"))), "没有压制就不趴（0 分）"
	)
	subject.call("apply_suppression", 1.0)
	_check(
		float(tactics.call("score_prone")) > 0.0, "被压制且身边没掩体 -> 趴下分 > 0"
	)
	var pinned_score: float = float(tactics.call("score_prone"))
	subject.global_position = _map.world_pos(cover_spot)
	_check(
		is_zero_approx(float(tactics.call("score_prone"))),
		"旁边就有掩体时不趴下——去掩体严格优于趴着挨打",
	)
	subject.global_position = _map.world_pos(open_spot)
	# 投降是更大的决定，扑倒不该抢走它。要按各自权重比：0.85x1.4 = 1.19 < 1.5，
	# 不然压制拉满时士兵宁可趴下也不举白旗，投降链路就永远不会触发。
	subject.set("suppression", 1.0)
	var weighted: float = pinned_score * 1.4
	_check(
		weighted < 1.5,
		"扑倒加权后 %.2f 必须低于投降的 1.5（否则投降永远轮不到）" % weighted,
	)
