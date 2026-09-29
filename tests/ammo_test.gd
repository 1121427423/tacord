# M14 弹药告急的独立冒烟场景：阈值上下两档 / 冷却实测两档对比 / 补弹自动恢复 /
# 打光边界（打光 ≠ 告急）/ 换弹中读数不误报 / 降级不伤命中与换弹 / 告急线精确踩线。
# 第六个里程碑场景（smoke 154 / mobility 40 / medic 26 / tank 40 / drone 37 / ammo 20）——
# 每个里程碑一个场景是 M8 定下的规矩（smoke_test.gd 顶着 gdlint 的 1000 行上限）。
# 推演提示：每条断言都得问一句"如果不是我想的那个原因，它会不会照样通过？"
# ——例如"冷却变长"必须两档对比着测：只测降级档，漏掉"两档都被拉长"查不出来；
# 只测正常档，漏掉"降级根本没生效"也查不出来。
extends Node

const MAP_SCENE := preload("res://scenes/battle/battle_map.tscn")
const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

# 本场景的断言总数。与其余五个场景同样的理由：只看"0 失败"会漏掉中途 abort。
const EXPECTED_CHECKS := 20

var _map = null
var _checks: int = 0
var _failures: int = 0
var _log: FileAccess = null


func _ready() -> void:
	_log = FileAccess.open("res://ammo_result.log", FileAccess.WRITE)
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _test_ammo()
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
		_emit("AMMO TEST PASSED: %d/%d" % [_checks, _checks])
		_close_log()
		get_tree().quit(0)
	else:
		_emit("AMMO TEST FAILED: %d/%d 项未通过" % [_failures, _checks])
		_close_log()
		get_tree().quit(1)


func _close_log() -> void:
	if _log != null:
		_log.close()
		_log = null


## 造士兵：默认关掉 AI——本场景要的全是静止状态下发生的武器读数。
func _spawn_soldier(cell: Vector2i, team: int, hp: int = 100):
	var unit = SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	_map.add_child(unit)
	unit.get_node("SoldierAI").set_process(false)
	unit.global_position = _map.world_pos(cell)
	unit.set("hp", hp)
	return unit


func _wait(frames: int) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


## 实测冷却：从上一枪到再次可以开火，经过了多少个物理帧。
## 士兵本体每物理帧驱动一次 weapon.tick（soldier._physics_process），
## 物理帧率固定 60（project.godot），帧数 ÷ 60 就是冷却秒数。
## 用帧数而不是秒表：物理 delta 恒为 1/60，数帧对 CI 机器快慢完全免疫。
func _frames_until_ready(w: Weapon, cap: int = 120) -> int:
	var frames: int = 0
	while not w.can_fire() and frames < cap:
		await get_tree().physics_frame
		frames += 1
	return frames


func _test_ammo() -> void:
	_emit("[弹药告急]")

	# ================================================================
	# 1) 阈值上不降级：满弹匣 24 + 备弹 72 = 96 发，冷却照 0.35s 走
	# ================================================================
	var shooter = _spawn_soldier(Vector2i(4, 20), 1)
	var w: Weapon = shooter.get_node("Weapon")
	await _wait(2)
	_check(not w.is_conserving, "满弹 96 发离告急线（24）远，is_conserving == false")
	# 朝南空地开一枪（打不打得中无所谓，冷却照设），实测到再次可开火的帧数。
	# 0.35s × 60fps = 21 帧；容忍 18~27 帧的浮点/回调次序抖动。
	# 若正常档也被误拉长到 0.875s，实测会是 53 帧——本条专钉"正常档没被拉长"。
	w.try_fire(shooter.global_position + Vector2(0.0, 300.0))
	var normal_frames: int = await _frames_until_ready(w)
	_check(
		normal_frames >= 18 and normal_frames <= 27,
		"正常冷却实测 %d 帧（0.35s ≈ 21 帧，容忍 18~27）" % normal_frames,
	)

	# ================================================================
	# 2) 阈值下降级：只剩最后一匣（总量恰 24），冷却 ×2.5 -> 0.875s
	# ================================================================
	var low = _spawn_soldier(Vector2i(12, 20), 1)
	var low_w: Weapon = low.get_node("Weapon")
	low_w.ammo_in_mag = 24
	low_w.reserve_ammo = 0
	await _wait(2)
	_check(
		low_w.is_conserving,
		"总量恰好 24 发（满匣零备弹）踩进告急线，is_conserving == true",
	)
	low_w.try_fire(low.global_position + Vector2(0.0, 300.0))
	var conserving_frames: int = await _frames_until_ready(low_w)
	# 0.875s × 60fps = 52.5 -> 53 帧；容忍 46~60。
	# 若降级没生效，实测会是 21 帧——与上一档对比才钉得住"降级真的发生了"。
	_check(
		conserving_frames >= 46 and conserving_frames <= 60,
		"告急冷却实测 %d 帧（0.875s ≈ 53 帧，容忍 46~60）" % conserving_frames,
	)

	# ================================================================
	# 3) 补弹自动恢复：add_reserve 拉回告急线上 -> 读数回 false
	# ================================================================
	# 沿用第一个士兵（S1 已消耗 1 发，无妨），把弹药压回告急线：10 + 14 = 24。
	w.ammo_in_mag = 10
	w.reserve_ammo = 14
	await _wait(2)
	_check(w.is_conserving, "补弹前先钉住前提：总量 24，确实在告急")
	_check(w.add_reserve(10) == 10, "add_reserve 补进 10 发（FOB/卡车同款通道）")
	await _wait(2)
	_check(not w.is_conserving, "总量回到 34（> 24），is_conserving 自动回 false")

	# ================================================================
	# 4) 打光边界：打光 ≠ 告急；换弹中读数照常刷新、不误报
	# ================================================================
	var dry = _spawn_soldier(Vector2i(4, 12), 1)
	var dry_w: Weapon = dry.get_node("Weapon")
	dry_w.ammo_in_mag = 0
	dry_w.reserve_ammo = 0
	await _wait(2)
	_check(dry_w.is_dry(), "彻底打光：is_dry == true（总量 0）")
	_check(
		not dry_w.is_conserving,
		"打光不告急：已经沉寂的枪谈不上省着打（is_conserving == false）",
	)
	_check(not dry_w.start_reload(), "打光且零备弹：换弹被拒（这把枪就此沉寂）")
	# 换弹不误报之一：弹匣不满但备弹充足（总量 70 远在线上）——换弹中不能
	# 因为"弹匣暂时见底"就误报告急。若有人按弹匣余量算告急，这条当场翻车。
	var ample = _spawn_soldier(Vector2i(4, 14), 1)
	var ample_w: Weapon = ample.get_node("Weapon")
	ample_w.ammo_in_mag = 10
	ample_w.reserve_ammo = 60
	await _wait(2)
	ample_w.start_reload()
	await _wait(20)  # 0.33s：换弹（2.2s）进行到一半
	_check(
		ample_w.is_reloading and not ample_w.is_conserving,
		"换弹中不误报：总量 70 在告急线上，读数保持 false",
	)
	# 换弹不误报之二 + 换弹时长不被降级拉长：最后一匣（总量 24）换弹，
	# 途中读数稳定为 true 不闪烁；2.2s = 132 帧，等 160 帧必须已完成。
	var last = _spawn_soldier(Vector2i(4, 16), 1)
	var last_w: Weapon = last.get_node("Weapon")
	last_w.ammo_in_mag = 0
	last_w.reserve_ammo = 24
	await _wait(2)
	last_w.start_reload()
	await _wait(20)
	_check(
		last_w.is_reloading and last_w.is_conserving,
		"最后一匣换弹中：读数照常刷新为 true（总量 24，不闪烁）",
	)
	await _wait(140)  # 累计 160 帧 = 2.67s > 2.2s
	var full_mag: bool = last_w.ammo_in_mag == 24 and last_w.reserve_ammo == 0
	_check(
		not last_w.is_reloading and full_mag,
		"换弹 2.2s 如期完成（降级不拉长换弹），弹匣打满、备弹清零",
	)
	_check(
		last_w.is_conserving,
		"换弹后满匣零备弹 = 仍是最后一匣，告急不解除",
	)

	# ================================================================
	# 5) 降级不伤其它语义：命中、伤害、弹药消耗照旧
	#    沿用 drone_test 验证过的净空走廊 (16,4) -> (18,4)：64px 间距，
	#    ±3° 散布的最大横向偏移 ≈ 3.4px < 站姿命中半径 7px，这一枪必中。
	# ================================================================
	var cons = _spawn_soldier(Vector2i(16, 4), 1)
	var cons_w: Weapon = cons.get_node("Weapon")
	var target = _spawn_soldier(Vector2i(18, 4), 2)
	cons_w.ammo_in_mag = 24
	cons_w.reserve_ammo = 0
	await _wait(2)
	_check(cons_w.is_conserving, "前提钉住：这一枪确实是在告急状态下打的")
	var hit: bool = cons_w.try_fire(target.global_position)
	_check(hit, "告急状态下照常开火命中（降级不禁枪）")
	_check(int(target.get("hp")) == 88, "伤害照旧 12（100 -> 88，降级不减伤害）")
	_check(cons_w.ammo_in_mag == 23, "弹药消耗照旧一发（降级不多烧弹）")

	# ================================================================
	# 6) 告急线精确踩线：总量 == 24 算（≤ 含等号），== 25 不算
	# ================================================================
	var edge = _spawn_soldier(Vector2i(24, 4), 1)
	var edge_w: Weapon = edge.get_node("Weapon")
	edge_w.ammo_in_mag = 24
	edge_w.reserve_ammo = 0
	await _wait(2)
	_check(
		edge_w.is_conserving,
		"总量恰 == magazine_size（24）算告急（≤ 含等号）",
	)
	edge_w.reserve_ammo = 1
	await _wait(2)
	_check(
		not edge_w.is_conserving,
		"总量 == 25（一匣多一发）不算告急",
	)
