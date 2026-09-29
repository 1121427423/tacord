# M12 手榴弹的独立冒烟场景：引信与飞行 / 伤害三档与压制 / 坦克装甲 /
# 被扔回与它的两个克制反例 / 掀飞与踉跄 / evade 扑倒 / 投掷决策。
# 第六个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank 40 / drone 37
# 之后）——每个里程碑一个场景是 M8 定下的规矩（smoke_test.gd 顶着 gdlint 的
# 1000 行上限）。日志写 res://grenade_result.log，CI 的 tag 就是 grenade。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"
# ——例如"被扔回"必须同时钉住 has_been_returned 与"雷在投掷者脚下炸"，
# 只看前者可能只是雷自己炸了。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const TANK_SCENE := preload("res://scenes/units/tank.tscn")
const GRENADE_SCENE := preload("res://scenes/units/grenade.tscn")

# 本场景的断言总数。与其余场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 49

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://grenade_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_grenade()
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
		_emit("GRENADE TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("GRENADE TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


## 造士兵：默认关掉 AI——本场景要的大多是静止状态下发生的事；
## ai_on=true 时留着 AI（evade 与投掷决策那几段需要会思考的兵）。
func _spawn_soldier(cell: Vector2i, team: int, hp: int = 100, ai_on: bool = false):
	var unit = SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	_map.add_child(unit)
	if not ai_on:
		unit.get_node("SoldierAI").set_process(false)
	unit.global_position = _map.world_pos(cell)
	unit.set("hp", hp)
	return unit


## 造坦克：TankAI 挂在 _physics_process 上，关它用 set_physics_process
## （与 soldier_ai 的 set_process 不是一回事，tank_test 里踩过这个坑）。
func _spawn_tank(cell: Vector2i, team: int):
	var tank = TANK_SCENE.instantiate()
	tank.set("team", team)
	_map.add_child(tank)
	tank.get_node("TankAI").set_physics_process(false)
	tank.global_position = _map.world_pos(cell)
	return tank


## 造雷并出手（挂到 _map 下，与士兵同层）。出手是否被接受由第 1 段
## 专门断言过，后面各段不再重复检查。
func _throw_grenade(from: Vector2, to: Vector2, thrower):
	var grenade = GRENADE_SCENE.instantiate()
	_map.add_child(grenade)
	grenade.call("throw_grenade", from, to, thrower)
	return grenade


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


## 生成一个"士兵姿态等于 want"的谓词，供 _wait_until 轮询。
func _posture_is(unit, want: StringName) -> Callable:
	return func (): return unit.get("posture") == want


## 等 N 帧，期间士兵姿态一旦变成 want 立刻返回 true；全程没变过返回 false。
func _posture_ever(unit, want: StringName, frames: int) -> bool:
	for _i in range(frames):
		if unit.get("posture") == want:
			return true
		await get_tree().physics_frame
	return false


## 等一颗雷炸完（从树上消失），期间盯着 has_been_returned 有没有翻过。
## 雷炸掉之后就再也读不到这个标志了，得在它还活着的时候把账记下来。
func _wait_blast(grenade, frames: int) -> bool:
	var seen_return: bool = false
	for _i in range(frames):
		if not is_instance_valid(grenade):
			return seen_return
		if grenade.get("has_been_returned"):
			seen_return = true
		await get_tree().physics_frame
	return seen_return


## 等 N 帧，期间 grenades 组必须一直空着；返回是否始终为空。
func _grenades_stay_empty(frames: int) -> bool:
	for _i in range(frames):
		if not get_tree().get_nodes_in_group(&"grenades").is_empty():
			return false
		await get_tree().physics_frame
	return true


func _test_grenade() -> void:
	_emit("[手榴弹]")
	var game = get_node_or_null("/root/Game")

	# ================================================================
	# 1) 身段与引信飞行：雷只进 grenades 组；1.8s 总引信含 0.5s 飞行段
	# ================================================================
	var thrower1 = _spawn_soldier(Vector2i(4, 4), 1)
	var g1 = GRENADE_SCENE.instantiate()
	_map.add_child(g1)
	_check(g1.is_in_group(&"grenades"), "雷注册在 grenades 组（evade 打分与扔回扫描的通道）")
	_check(not g1.is_in_group(&"soldiers"), "雷**不在** soldiers 组——救援/押送/帐篷/补弹都看不见它")
	_check(not g1.is_in_group(&"vehicles"), "雷**不在** vehicles 组——载具身段不认它")
	var start1: Vector2 = thrower1.global_position
	var target1: Vector2 = _map.world_pos(Vector2i(10, 4))
	_check(bool(g1.call("throw_grenade", start1, target1, thrower1)), "throw_grenade 接受出手")
	_check(
		not bool(g1.call("throw_grenade", start1, target1, thrower1)),
		"二次出手被拒绝——一颗雷只有一次出手",
	)
	_check(float(g1.call("fuse_remaining")) > 1.75, "出手瞬间引信是满的 1.8s（> 1.75）")
	await _wait(15)
	var flown1: float = start1.distance_to(g1.global_position)
	_check(
		flown1 > 70.0 and flown1 < 120.0,
		"飞行按 距离/0.5s 的速度直线推进（15 帧实测 %.0fpx ≈ 96px）" % flown1,
	)
	_check(
		await _wait_until(func (): return g1.global_position.distance_to(target1) < 2.0, 45),
		"约 30 帧（0.5s）后抵达落点",
	)
	_check(
		absf(float(g1.call("fuse_remaining")) - 1.3) < 0.1,
		"抵达时引信还剩 ≈ 1.3s——飞行段是总引信的一部分",
	)
	await _wait(69)  # 连同前面的等待累计约 100 帧
	var fuse1: float = float(g1.call("fuse_remaining"))
	_check(fuse1 > 0.0 and fuse1 < 0.25, "100 帧后引信还在走（剩 %.2fs）" % fuse1)
	_check(
		await _wait_until(func (): return not is_instance_valid(g1), 40),
		"总引信 1.8s ≈ 108 帧后自毁（雷从树上消失）",
	)

	# ================================================================
	# 2) 伤害三档与一次性压制：中心 60 -> 边缘 12 线性衰减
	#    blast(6,9) 为圆心；贴脸 +8px、边缘 +50px、半径外 +80px。
	#    三个靶子都造蓝方：投掷方也是蓝的，同队不触发"被扔回"扫描。
	# ================================================================
	var thrower2 = _spawn_soldier(Vector2i(2, 9), 1)
	var blast2: Vector2 = _map.world_pos(Vector2i(6, 9))
	var close2 = _spawn_soldier(Vector2i(6, 9), 1)
	close2.global_position = blast2 + Vector2(8, 0)
	var rim2 = _spawn_soldier(Vector2i(6, 9), 1)
	rim2.global_position = blast2 + Vector2(50, 0)
	var outside2 = _spawn_soldier(Vector2i(6, 9), 1)
	outside2.global_position = blast2 + Vector2(80, 0)
	var g2 = _throw_grenade(thrower2.global_position, blast2, thrower2)
	await _wait_until(func (): return not is_instance_valid(g2), 150)
	_check(
		int(close2.get("hp")) <= 50,
		"贴脸（8px）掉 ≥ 50（60 线性衰减，实测剩 %d）" % int(close2.get("hp")),
	)
	_check(int(rim2.get("hp")) >= 80, "边缘（50px）掉 < 20（实测剩 %d）" % int(rim2.get("hp")))
	_check(int(outside2.get("hp")) == 100, "半径外（80px > 56px）一点不掉")
	_check(float(close2.get("suppression")) > 0.7, "贴脸兵吃到 0.8 的一次性压制")
	_check(float(rim2.get("suppression")) > 0.7, "边缘兵同样吃到压制（半径内不分敌我）")
	_check(float(outside2.get("suppression")) == 0.0, "半径外不吃压制")

	# ================================================================
	# 3) 坦克照吃爆炸，但走装甲：60×0.25=15
	# ================================================================
	var thrower3 = _spawn_soldier(Vector2i(2, 12), 1)
	var tank3 = _spawn_tank(Vector2i(6, 12), 1)
	var g3 = _throw_grenade(thrower3.global_position, tank3.global_position, thrower3)
	await _wait_until(func (): return not is_instance_valid(g3), 150)
	_check(int(tank3.get("hp")) == 185, "爆炸 60 伤打在装甲上只掉 15（200 -> 185）")

	# ================================================================
	# 4) 被扔回：落点旁站着一个没被压制的敌兵，雷会被捡起扔回投掷者
	#    A(4,16) 蓝 --192px--> (10,16) 红兵 B 就站在落点上
	# ================================================================
	var thrower4 = _spawn_soldier(Vector2i(4, 16), 1)
	var foe4 = _spawn_soldier(Vector2i(10, 16), 2)
	var g4 = _throw_grenade(thrower4.global_position, _map.world_pos(Vector2i(10, 16)), thrower4)
	_check(
		await _wait_until(func (): return g4.get("has_been_returned") == true, 60),
		"落点旁压制为 0 的敌兵把雷捡起扔回（has_been_returned 翻 true）",
	)
	_check(await _wait_until(func (): return not is_instance_valid(g4), 150), "扔回的雷最终炸完自毁")
	_check(int(thrower4.get("hp")) == 40, "雷回到投掷者脚下炸（100 - 60 = 40）")
	_check(int(foe4.get("hp")) == 100, "扔回的人自己没挨炸（雷已经飞走了）")

	# ================================================================
	# 5a) 扔回克制·其一：引信剩不到 0.6s 时，贴脸敌兵也不敢捡
	# ================================================================
	var thrower5 = _spawn_soldier(Vector2i(2, 20), 1)
	var g5 = _throw_grenade(thrower5.global_position, _map.world_pos(Vector2i(6, 20)), thrower5)
	# 等引信跌破 0.55s（比 0.6 的敢捡窗口再低一截，杜绝临界抖动）；
	# 这之前场上没有任何红方士兵贴着雷。
	_check(
		await _wait_until(func (): return float(g5.call("fuse_remaining")) < 0.55, 110),
		"引信走到 < 0.55s（前提钉住：雷还活着、还没被扔回）",
	)
	var late5 = _spawn_soldier(Vector2i(6, 20), 2)
	late5.global_position = g5.global_position  # 直接站到雷上
	var returned5: bool = await _wait_blast(g5, 60)
	_check(not returned5, "引信 < 0.6s：贴脸敌兵不捡（has_been_returned 保持 false）")
	_check(int(late5.get("hp")) == 40, "雷在贴脸兵脚下原地炸（100 - 60 = 40）")
	_check(int(thrower5.get("hp")) == 100, "投掷者安然无恙——雷没有被扔回他脚下")

	# ================================================================
	# 5b) 扔回克制·其二：压制 ≥ 0.7 的兵没胆子捡，雷照样原地炸
	#     5b(18,20) 蓝 --128px--> (22,20) 红兵 B2 压制拉满站在落点。
	#     引信 ≥ 0.6 的可捡窗口最长 1.2s，压制从 1.0 衰减到 1.2s 末还有
	#     0.74 > 0.7——整个窗口里他都没胆子。
	# ================================================================
	var thrower6 = _spawn_soldier(Vector2i(18, 20), 1)
	var foe6 = _spawn_soldier(Vector2i(22, 20), 2)
	foe6.set("suppression", 1.0)
	var g6 = _throw_grenade(thrower6.global_position, _map.world_pos(Vector2i(22, 20)), thrower6)
	var returned6: bool = await _wait_blast(g6, 150)
	_check(not returned6, "压制 ≥ 0.7 的兵不捡雷（has_been_returned 保持 false）")
	_check(int(foe6.get("hp")) == 40, "没被扔回的雷在落点原地炸（贴脸兵 100 - 60 = 40）")
	_check(int(thrower6.get("hp")) == 100, "投掷者同样安然无恙")

	# ================================================================
	# 6) 掀飞：爆心 30px 处的兵被推开 ≈ 32px，眩晕 0.8s 内开不了枪
	#    blast(26,6) 为圆心，kicked 站 +30px；靶子蓝兵站在 +128px 供恢复后试枪。
	#    靶子必须是**同队**：投掷方是蓝的，红靶会触发"被扔回"，故事就串了。
	# ================================================================
	var thrower7 = _spawn_soldier(Vector2i(22, 6), 1)
	var blast7: Vector2 = _map.world_pos(Vector2i(26, 6))
	var victim7 = _spawn_soldier(Vector2i(30, 6), 1)
	var kicked7 = _spawn_soldier(Vector2i(26, 6), 1)
	kicked7.global_position = blast7 + Vector2(30, 0)
	var pos_before: Vector2 = kicked7.global_position
	var g7 = _throw_grenade(thrower7.global_position, blast7, thrower7)
	_check(await _wait_until(func (): return not is_instance_valid(g7), 150), "雷按时炸掉（掀飞的前提）")
	_check(kicked7.get("staggered") == true, "爆炸后立刻进入踉跄（staggered = true）")
	_check(
		not bool(kicked7.call("try_fire", victim7.global_position)),
		"眩晕中 try_fire 返回 false——扣不动扳机",
	)
	_check(
		int(kicked7.get("weapon").get("ammo_in_mag"))
			== int(kicked7.get("weapon").get("magazine_size")),
		"而且弹匣一发未动——false 来自眩晕拦截，不是冷却或换弹",
	)
	await _wait(60)  # 1.0s > 0.8s 的踉跄窗口
	_check(kicked7.get("staggered") == false, "约 0.8s 后踉跄解除（staggered = false）")
	var push_dx: float = kicked7.global_position.x - pos_before.x
	_check(
		push_dx > 24.0 and push_dx < 40.0,
		"人被沿 origin->士兵 方向掀飞 ≈ 32px（实测 %.1fpx）" % push_dx,
	)
	_check(
		bool(kicked7.call("try_fire", victim7.global_position)),
		"踉跄过后照常开火——66px 外的靶子被这一枪真实命中（散布 < 命中半径）",
	)

	# ================================================================
	# 7) evade 扑倒：96px 内引信 ≤ 1.0s 的雷让 AI 兵就地趴下
	#    watcher8(16,10) AI 开；雷落在 (14,10)，距它 64px：
	#    够躲（≤ 96px）、不够炸（> 56px）、也掀不着（> 40px）。
	# ================================================================
	var watcher8 = _spawn_soldier(Vector2i(16, 10), 1, 100, true)
	var thrower8 = _spawn_soldier(Vector2i(11, 10), 1)
	var g8 = _throw_grenade(thrower8.global_position, _map.world_pos(Vector2i(14, 10)), thrower8)
	# evade 的正例连续两轮 CI 不触发而反例全过，静态推演无懈可击——
	# 只剩引擎里的实际分数能一击定位。轮询中每 15 帧（一个思考节拍）
	# 抓一份效用表快照（_emit 不占断言数），失败时摊开看谁赢了。
	var evade_seen: bool = false
	var evade_snapshots: Array = []
	for i in range(150):
		if watcher8.get("posture") == Soldier.POSTURE_PRONE:
			evade_seen = true
			break
		# 雷寿命 108 帧 < 轮询 150 帧：雷炸掉后快照再去摸它的 global_position
		# 会崩协程（上轮 CI 实测）。雷没了，窗口也就关了，直接收摊。
		if not is_instance_valid(g8):
			break
		if i % 15 == 0:
			# 快照把雷的现场也摊开：evade 分数恒 0 而雷明明在窗口内，
			# 组/距离/引信哪个环节断了，下一轮日志一眼定位。
			var g8_pos: Vector2 = g8.global_position
			var g8_fuse: float = float(g8.call("fuse_remaining"))
			var g8_dist: float = watcher8.global_position.distance_to(g8_pos)
			evade_snapshots.append(
				"[第%d帧] 雷=(%.0f,%.0f) fuse=%.2f 距=%.0f 组数=%d | %s"
				% [
					i,
					g8_pos.x,
					g8_pos.y,
					g8_fuse,
					g8_dist,
					get_tree().get_nodes_in_group(&"grenades").size(),
					watcher8.get_node("SoldierAI").call("scores_text"),
				]
			)
		await get_tree().physics_frame
	_check(evade_seen, "AI 兵在 96px 内出现快炸的雷时扑倒（posture = prone）")
	for line in evade_snapshots:
		_emit("  [观测] %s" % line)
	_check(
		await _wait_until(_posture_is(watcher8, Soldier.POSTURE_STAND), 90),
		"雷炸完后起身恢复——prone 不会粘住不放（M8 的起身自动化接管）",
	)
	# 反例：同一颗雷挪到 128px（> 96px）外落，evade 不该触发。
	var watcher9 = _spawn_soldier(Vector2i(20, 6), 1, 100, true)
	var thrower9 = _spawn_soldier(Vector2i(12, 6), 1)
	var g9 = _throw_grenade(thrower9.global_position, _map.world_pos(Vector2i(16, 6)), thrower9)
	_check(
		await _wait_until(func (): return float(g9.call("fuse_remaining")) < 0.95, 90),
		"反例的雷也走进了引信 ≤ 1.0s 的窗口（前提钉住：它确实够『快炸』）",
	)
	var ever_prone: bool = await _posture_ever(watcher9, Soldier.POSTURE_PRONE, 30)
	_check(
		not ever_prone,
		"雷在 128px（> 96px）时不会扑倒——evade 只看半径内的雷",
	)
	# 场地卫生：等反例的雷自己炸掉，别让它搅下一段的"组里出现新雷"。
	await _wait_until(func (): return not is_instance_valid(g9), 90)

	# ================================================================
	# 8) 投掷决策：有雷 + 目标 60~200px + 无通视 + 黑板有记忆，缺一不投
	#    H(26,4) AI 开 --128px-- 墙(28,4) --128px-- R1(30,4) 红兵
	# ================================================================
	if game != null:
		game.call("clear_boards")
	_map.call("add_obstacle", Vector2i(28, 4))
	var thrower10 = _spawn_soldier(Vector2i(26, 4), 1, 100, true)
	var hidden10 = _spawn_soldier(Vector2i(30, 4), 2)
	_check(
		not _map.call("has_line_of_sight", thrower10.global_position, hidden10.global_position),
		"前提钉住：墙确实挡住了视线（无通视是投掷的先决条件）",
	)
	var throw_dist: float = thrower10.global_position.distance_to(hidden10.global_position)
	_check(
		throw_dist >= 60.0 and throw_dist <= 200.0,
		"前提钉住：目标在 60~200px 的投掷窗口内（%.0fpx）" % throw_dist,
	)
	if game != null:
		# 靶子压制先拉满：投出的雷落在记忆位置——就是他脚下。压制为 0 的活敌兵
		# 满足"被扔回"的全部条件（距雷 ~0px、引信 1.8 ≥ 0.6），雷刚落地就会被
		# 他捡起扔回投掷者，把"投出"与后续反例搅成一锅。先钉死他的胆子。
		# 1.0 衰减 1.2s（可捡窗口）后仍有 0.74 > 0.7，整个窗口他都没胆子。
		hidden10.set("suppression", 1.0)
		game.call("blackboard", 1).call("report_sighting", hidden10, hidden10.global_position)
		# 投掷正例同样连挂两轮——同款观测：每 15 帧抓一份效用表快照。
		var thrown: bool = false
		var throw_snapshots: Array = []
		for i in range(60):
			if not get_tree().get_nodes_in_group(&"grenades").is_empty():
				thrown = true
				break
			if i % 15 == 0:
				throw_snapshots.append(
					"[第%d帧] %s" % [i, thrower10.get_node("SoldierAI").call("scores_text")]
				)
			await get_tree().physics_frame
		_check(thrown, "黑板有记忆且无通视 -> 雷被投出（grenades 组出现一颗）")
		for line in throw_snapshots:
			_emit("  [观测] %s" % line)
		_check(int(thrower10.get("grenades")) == 0, "投掷者 grenades 减 1（1 -> 0）")
		_check(
			int(thrower10.get("weapon").get("ammo_in_mag"))
				== int(thrower10.get("weapon").get("magazine_size")),
			"雷不耗弹药——弹匣仍是满的（PLAN 验收的『弹匣不受影响』）",
		)
		# 等这颗雷炸完，别让它搅后面的反例。
		await _wait_until(
			func (): return get_tree().get_nodes_in_group(&"grenades").is_empty(), 200
		)
		# 反例 1：没雷（grenades=0）——同样的记忆、同样的躲藏目标，不投。
		game.call("blackboard", 1).call("report_sighting", hidden10, hidden10.global_position)
		_check(
			await _grenades_stay_empty(30),
			"无雷不投（grenades=0：黑板照样有记忆，组里 30 帧内没有新雷）",
		)
	else:
		_check(false, "（Game autoload 不在，占位）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
		_check(false, "（占位：保持断言总数不变）")
	# 反例 2：有通视（看得见就不扔，直接开枪）。
	var shooter11 = _spawn_soldier(Vector2i(24, 8), 1, 100, true)
	var seen11 = _spawn_soldier(Vector2i(30, 8), 2)
	if game != null:
		game.call("blackboard", 1).call("report_sighting", seen11, seen11.global_position)
	await _wait(40)
	_check(
		int(shooter11.get("grenades")) == 1,
		"有通视不投（grenades 保持 1——枪打得着就用枪）",
	)
	_check(
		int(shooter11.get("weapon").get("ammo_in_mag"))
			< int(shooter11.get("weapon").get("magazine_size")),
		"同一时间枪在干活（弹匣已经动过）——不投雷不是因为它不敢打",
	)
	# 反例 3：目标超 200px（224px）——记忆在、人也看得见，就是够不着。
	var shooter12 = _spawn_soldier(Vector2i(24, 12), 1, 100, true)
	var far12 = _spawn_soldier(Vector2i(31, 12), 2)
	if game != null:
		game.call("blackboard", 1).call("report_sighting", far12, far12.global_position)
	await _wait(40)
	_check(int(shooter12.get("grenades")) == 1, "目标超 200px 不投（grenades 保持 1）")

	if game != null:
		game.call("clear_boards")
