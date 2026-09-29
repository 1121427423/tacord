# 主场景入口：装配相机与地图，布置演示用地形/掩体，生成双方占位士兵并刷新 HUD。
extends Node2D

const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")
const TANK_SCENE := preload("res://scenes/units/tank.tscn")
const DRONE_SCENE := preload("res://scenes/units/drone.tscn")

const PLAYER_TEAM := 1
const ENEMY_TEAM := 2

## 每队第几个（0 基）当医疗兵。默认每队 3 人时即最后一人。
const MEDIC_INDEX := 2

@export var soldiers_per_team: int = 3

var units: Array = []

## 装甲车单列一个数组：部队上限（unit_cap）与战损统计都只算步兵，
## 坦克打掉一辆少一辆，不占编制、也不影响判负。
var tanks: Array = []

## 侦察无人机同坦克的思路单列：不占编制、不影响判负，掉一架少一架。
var drones: Array = []

@onready var camera: Camera2D = $Camera2D

# BattleMap 实例，不标注类型以便鸭子调用其查询接口。
@onready var map = $BattleMap

@onready var hud_label: Label = $HUD/OrderLabel


func _ready() -> void:
	_seed_terrain()
	_spawn_demo_units()
	_setup_camera()
	_update_hud()


func _process(_delta: float) -> void:
	_update_hud()
	# 审讯出新情报时要立刻重画标记。
	queue_redraw()


## 已审出的敌方工事画在地图上——M7 的验收标准是「敌方基地出现在地图上」，
## 光在 HUD 上写个数字不算数。Main 与 BattleMap 都在原点，世界坐标可以直接用。
func _draw() -> void:
	var game := get_node_or_null("/root/Game")
	if game == null or not game.has_method("blackboard"):
		return
	for team in [PLAYER_TEAM, ENEMY_TEAM]:
		# 自己审出来的画亮色，对面审出来的画暗色：AI 也知道，但不该抢玩家的注意力。
		var color := (
			Color(1.0, 0.86, 0.25, 0.95)
			if team == PLAYER_TEAM
			else Color(1.0, 0.45, 0.3, 0.35)
		)
		var board = game.call("blackboard", team)
		for pos in board.call("structures"):
			_draw_intel_marker(pos, color)


## 十字准星 + 圆圈：一眼能和木箱、墙区分开。
func _draw_intel_marker(pos: Vector2, color: Color) -> void:
	draw_arc(pos, 15.0, 0.0, TAU, 24, color, 2.0)
	for offset in [Vector2(-22, 0), Vector2(8, 0)]:
		draw_line(pos + offset, pos + offset + Vector2(14, 0), color, 1.5)
	for offset in [Vector2(0, -22), Vector2(0, 8)]:
		draw_line(pos + offset, pos + offset + Vector2(0, 14), color, 1.5)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 and map != null:
			map.debug_show_cover = not map.debug_show_cover
			map.queue_redraw()
		elif event.keycode == KEY_R:
			var game := get_node_or_null("/root/Game")
			if game != null:
				game.call("load_battle")
		elif event.keycode == KEY_5:
			_place_build_site(&"fob")
		elif event.keycode == KEY_6:
			_place_build_site(&"sandbag")
		elif event.keycode == KEY_7:
			_place_build_site(&"tent")


## 在蓝方第一个活人脚下放一个工地（指挥官把工事下在自己部队所在位置）。
func _place_build_site(kind: StringName) -> void:
	var game := get_node_or_null("/root/Game")
	if game == null or map == null or not game.has_method("place_build_site"):
		return
	var cell := Vector2i(-1, -1)
	for unit in units:
		if int(unit.get("team")) == PLAYER_TEAM and unit.get("is_dead") != true:
			cell = map.cell_at(unit.global_position)
			break
	if cell.x < 0:
		cell = Vector2i(4, 12)
	game.call("place_build_site", kind, cell, PLAYER_TEAM)


# ---------------------------------------------------------------- 场景装配


func _setup_camera() -> void:
	if camera == null or map == null:
		return
	var size: Vector2 = map.map_size()
	camera.position = size * 0.5
	# 缩一点，保证 32x24x32px 的地图在 1280x720 窗口里完整可见。
	camera.zoom = Vector2(0.85, 0.85)
	camera.limit_left = -200
	camera.limit_top = -200
	camera.limit_right = int(size.x) + 200
	camera.limit_bottom = int(size.y) + 200


## 演示地形：中央一道带缺口的墙 + 几堆木箱 + 一片高地。
## 注意：这里没有任何“预设掩体点”，掩体价值全部由这些几何体实时算出来。
func _seed_terrain() -> void:
	if map == null:
		return
	for y in range(4, 20):
		if y >= 11 and y <= 13:
			continue  # 中央通道
		map.add_obstacle(Vector2i(16, y))
	for crate in [
		Vector2i(8, 6), Vector2i(9, 6), Vector2i(8, 7),
		Vector2i(22, 16), Vector2i(23, 16), Vector2i(23, 17),
		Vector2i(12, 20), Vector2i(13, 20),
	]:
		map.add_obstacle(crate)
	for x in range(19, 23):
		map.set_terrain(Vector2i(x, 3), &"high")
	for x in range(5, 9):
		map.set_terrain(Vector2i(x, 21), &"high")


func _spawn_demo_units() -> void:
	var blue_cells := [Vector2i(3, 6), Vector2i(2, 12), Vector2i(3, 18)]
	var red_cells := [Vector2i(28, 6), Vector2i(29, 12), Vector2i(28, 18)]
	for i in range(soldiers_per_team):
		var as_medic: bool = i == MEDIC_INDEX
		_spawn_unit(PLAYER_TEAM, blue_cells[i % blue_cells.size()], as_medic)
		_spawn_unit(ENEMY_TEAM, red_cells[i % red_cells.size()], as_medic)
	_spawn_tanks()
	_spawn_drones()
	# 蓝方守、红方攻：这样一开局就能看到 Utility AI 分化出不同行为。
	_issue_initial_orders()


func _spawn_unit(team: int, cell: Vector2i, as_medic: bool = false) -> void:
	if map == null:
		return
	# 部队上限由 FOB 数量决定（见 game.gd 的 unit_cap）。
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("can_reinforce") and not game.call("can_reinforce", team):
		push_warning("main: %d 队已达部队上限，跳过生成。" % team)
		return
	var unit := SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	unit.set("current_order", "hold")
	unit.name = _next_unit_name(team)
	if as_medic:
		# 名字带个"医"，HUD 上一眼能看出谁该去救人。
		unit.name = String(unit.name) + "医"
	map.add_child(unit)
	unit.global_position = map.world_pos(cell)
	# 医疗兵：救援意愿 x1.4、包扎速度 x2（见 soldier_ai.gd）。
	var unit_ai = unit.get_node_or_null("SoldierAI")
	if unit_ai != null:
		unit_ai.set("is_medic", as_medic)
	units.append(unit)


## 每队一辆装甲车。落位避开中央墙（x=16，y=4..10 与 14..20）与两堆木箱，
## 目标点对插敌方纵深——红方开局是"进攻"，它的坦克会当着你的面开过来。
func _spawn_tanks() -> void:
	if map == null:
		return
	_spawn_tank(PLAYER_TEAM, Vector2i(6, 15), Vector2i(29, 12))
	_spawn_tank(ENEMY_TEAM, Vector2i(25, 15), Vector2i(3, 12))


func _spawn_tank(team: int, cell: Vector2i, objective: Vector2i) -> void:
	var tank := TANK_SCENE.instantiate()
	tank.set("team", team)
	tank.set("objective", objective)
	map.add_child(tank)
	tank.global_position = map.world_pos(cell)
	tanks.append(tank)


## 每队一架侦察无人机。它的目击直接进本队黑板——步兵的「最后已知位置」
## 从此可以由天上来喂，这是它对防守方的全部意义。航点绕上半场一圈：
## 无人机不做通视判定（从上往下看），先于步兵看到墙后的一切。
func _spawn_drones() -> void:
	if map == null:
		return
	_spawn_drone(PLAYER_TEAM, Vector2i(3, 3), [Vector2i(12, 3), Vector2i(12, 9), Vector2i(3, 9)])
	_spawn_drone(
		ENEMY_TEAM, Vector2i(28, 20), [Vector2i(19, 20), Vector2i(19, 14), Vector2i(28, 14)]
	)


func _spawn_drone(team: int, cell: Vector2i, waypoint_cells: Array) -> void:
	var drone := DRONE_SCENE.instantiate()
	drone.set("team", team)
	map.add_child(drone)
	drone.global_position = map.world_pos(cell)
	var drone_ai = drone.get_node_or_null("DroneAI")
	if drone_ai != null:
		var route: Array[Vector2] = []
		for waypoint_cell in waypoint_cells:
			route.append(map.world_pos(waypoint_cell))
		drone_ai.set("waypoints", route)
	drones.append(drone)


func _next_unit_name(team: int) -> String:
	var prefix := "蓝" if team == PLAYER_TEAM else "红"
	var count: int = 0
	for unit in units:
		if int(unit.get("team")) == team:
			count += 1
	return "%s%d" % [prefix, count + 1]


func _issue_initial_orders() -> void:
	var game := get_node_or_null("/root/Game")
	if game == null:
		return
	game.call("issue_order", &"defend", PLAYER_TEAM)
	game.call("issue_order", &"attack", ENEMY_TEAM)


# ---------------------------------------------------------------- HUD


func _update_hud() -> void:
	if hud_label == null:
		return
	var game := get_node_or_null("/root/Game")
	var order: String = "hold"
	if game != null:
		order = String(game.get("current_order"))
	var text: String = "命令: %s    [1]进攻 [2]防守 [3]包抄 [4]待命    " % order
	text += "[5]放FOB [6]放沙袋 [7]放医疗帐篷    [F1]掩体热区 [R]重开\n"
	if game != null and game.has_method("is_team_defeated") and game.call(
		"is_team_defeated", PLAYER_TEAM
	):
		text += "!! 蓝方失去全部 FOB —— 战败（按 R 重开）\n"
	var blue_alive: int = 0
	var red_alive: int = 0
	var blue_down: int = 0
	var red_down: int = 0
	for unit in units:
		if unit.get("is_dead") == true:
			continue
		var is_blue: bool = int(unit.get("team")) == PLAYER_TEAM
		if is_blue:
			blue_alive += 1
		else:
			red_alive += 1
		if unit.get("is_downed") == true:
			if is_blue:
				blue_down += 1
			else:
				red_down += 1
	text += "蓝方 %d 存活（%d 倒地）    红方 %d 存活（%d 倒地）\n" % [
		blue_alive, blue_down, red_alive, red_down
	]
	text += "装甲: %s\n" % _tank_text()
	text += "空中: %s\n" % _drone_text()
	text += "情报: %s\n" % _intel_text(game)
	text += "俘虏: %s\n" % _captive_text(game)
	text += "弹药: %s\n" % _ammo_text()
	text += "工事: %s\n" % _build_text(game)
	text += "— 士兵自主决策 —\n"
	for unit in units:
		if unit.get("is_dead") == true:
			text += "%s  已阵亡\n" % _unit_tag(unit)
			continue
		if unit.get("is_downed") == true:
			text += "%s  倒地  失血=%.1fs  倒地%d次  包扎=%.0f%%\n" % [
				_unit_tag(unit),
				float(unit.get("bleed_timer")),
				int(unit.get("down_count")),
				float(unit.call("rescue_ratio")) * 100.0,
			]
			continue
		if unit.get("is_captive") == true:
			text += "%s  俘虏（押往 %s方）  hp=%d\n" % [
				_unit_tag(unit),
				"蓝" if int(unit.get("captor_team")) == PLAYER_TEAM else "红",
				int(unit.get("hp")),
			]
			continue
		text += "%s  hp=%d  弹=%s  压制=%.2f  命令=%s  行为=%s%s\n" % [
			_unit_tag(unit),
			int(unit.get("hp")),
			_unit_ammo_text(unit),
			float(unit.get("suppression")),
			String(unit.get("current_order")),
			String(unit.call("current_action")),
			_posture_note(unit),
		]
	hud_label.text = text


## 装甲车状态一行。载具的 is_downed / is_captive 恒为 false，
## 所以不需要步兵那套倒地/俘虏分支。
func _tank_text() -> String:
	if tanks.is_empty():
		return "无"
	var parts: Array = []
	for tank in tanks:
		var side: String = "蓝" if int(tank.get("team")) == PLAYER_TEAM else "红"
		if tank.get("is_dead") == true:
			parts.append("%s方 已击毁" % side)
			continue
		parts.append(
			(
				"%s方 hp=%d 命令=%s 行为=%s"
				% [
					side,
					int(tank.get("hp")),
					String(tank.get("current_order")),
					String(tank.call("current_action")),
				]
			)
		)
	return "   ".join(parts)


## 侦察无人机状态一行。它的价值不在这行字里——目击直接进本队黑板
## （「情报」那行因此会动），这里只给 hp 与当前行为。
## 无人机的 is_downed / is_captive 与坦克一样恒为 false，不需要步兵那套分支。
func _drone_text() -> String:
	if drones.is_empty():
		return "无"
	var parts: Array = []
	for drone in drones:
		var side: String = "蓝" if int(drone.get("team")) == PLAYER_TEAM else "红"
		if drone.get("is_dead") == true:
			parts.append("%s方 已坠毁" % side)
			continue
		parts.append(
			(
				"%s方 hp=%d 行为=%s"
				% [side, int(drone.get("hp")), String(drone.call("current_action"))]
			)
		)
	return "   ".join(parts)


func _unit_tag(unit) -> String:
	return String(unit.get("name"))


## 姿态标注：站姿不写（默认即常态），伏地/滑铲/翻越要一眼看出来。
## 趴下的人更难被打中、滑行的人开不了枪——这两件事直接影响观感与结果。
func _posture_note(unit) -> String:
	if unit.get("is_vaulting") == true:
		return "  [翻越]"
	match StringName(unit.get("posture")):
		&"prone":
			return "  [伏地]"
		&"slide":
			return "  [滑铲]"
	return ""


## 单个士兵的弹药读数，形如 "18/72"，换弹时加标注。
func _unit_ammo_text(unit) -> String:
	var unit_weapon = unit.get_node_or_null("Weapon")
	if unit_weapon == null:
		return "无武器"
	var text: String = "%d/%d" % [
		int(unit_weapon.get("ammo_in_mag")), int(unit_weapon.get("reserve_ammo"))
	]
	if unit_weapon.get("is_reloading") == true:
		text += "换弹中"
	elif int(unit_weapon.call("total_ammo")) <= 0:
		text += "打光"
	return text


## 双方剩余弹药总量与打光人数——"阵地渐渐沉寂"要能一眼看出来。
func _ammo_text() -> String:
	var parts: Array = []
	for team in [PLAYER_TEAM, ENEMY_TEAM]:
		var tag: String = "蓝" if team == PLAYER_TEAM else "红"
		var total: int = 0
		var dry: int = 0
		var count: int = 0
		for unit in units:
			if unit.get("is_dead") == true or int(unit.get("team")) != team:
				continue
			var unit_weapon = unit.get_node_or_null("Weapon")
			if unit_weapon == null:
				continue
			count += 1
			var left: int = int(unit_weapon.call("total_ammo"))
			total += left
			if left <= 0:
				dry += 1
		parts.append("%s方 %d 发（%d/%d 人打光）" % [tag, total, dry, count])
	return "    ".join(parts)


## 俘虏与审讯战果：在押人数 + 已经审出多少处敌方工事。
func _captive_text(game) -> String:
	if game == null or not game.has_method("captives"):
		return "无（没有 Game 自动加载）"
	var parts: Array = []
	for team in [PLAYER_TEAM, ENEMY_TEAM]:
		var tag: String = "蓝" if team == PLAYER_TEAM else "红"
		var held: int = int(game.call("captives", team).size())
		var revealed: int = 0
		if game.has_method("blackboard"):
			revealed = int(game.call("blackboard", team).call("structure_count"))
		parts.append("%s方在押 %d · 已审出 %d 处工事" % [tag, held, revealed])
	return "    ".join(parts)


## 工地与 FOB 状态：数量、部队上限、每个工地的施工进度。
func _build_text(game) -> String:
	var parts: Array = []
	if game != null and game.has_method("fob_count"):
		for team in [PLAYER_TEAM, ENEMY_TEAM]:
			var tag: String = "蓝" if team == PLAYER_TEAM else "红"
			parts.append(
				"%s方 FOB %d（上限 %d 人）"
				% [tag, game.call("fob_count", team), game.call("unit_cap", team)]
			)
	var sites: Array = []
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		var tag: String = "蓝" if int(site.get("team")) == PLAYER_TEAM else "红"
		if site.get("is_built") == true:
			sites.append("%s%s %dhp" % [tag, site.call("label"), int(site.get("hp"))])
		else:
			sites.append(
				"%s%s %.0f%%" % [tag, site.call("label"), float(site.call("build_ratio")) * 100.0]
			)
	if sites.is_empty():
		parts.append("无工地（按 5 放 FOB / 6 放沙袋 / 7 放医疗帐篷）")
	else:
		parts.append(" ".join(sites))
	return "    ".join(parts)


## 双方小队黑板里最值得追的那条记忆。让「靠记忆搜索」在画面上看得见。
func _intel_text(game) -> String:
	if game == null or not game.has_method("blackboard"):
		return "无（没有 Game 自动加载）"
	var parts: Array = []
	for team in [PLAYER_TEAM, ENEMY_TEAM]:
		var tag: String = "蓝" if team == PLAYER_TEAM else "红"
		var board = game.call("blackboard", team)
		var memory: Dictionary = board.call("best_memory", team)
		if memory.is_empty():
			parts.append("%s方 无" % tag)
			continue
		parts.append(
			"%s方 %s %.1fs 前 @(%d,%d)"
			% [
				tag,
				String(memory["kind"]),
				float(memory["age"]),
				int((memory["pos"] as Vector2).x),
				int((memory["pos"] as Vector2).y),
			]
		)
	return "    ".join(parts)
