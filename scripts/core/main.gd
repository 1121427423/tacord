# 主场景入口：装配相机与地图，布置演示用地形/掩体，生成双方占位士兵并刷新 HUD。
extends Node2D

const SOLDIER_SCENE := preload("res://scenes/units/soldier.tscn")

const PLAYER_TEAM := 1
const ENEMY_TEAM := 2

@export var soldiers_per_team: int = 3

var units: Array = []

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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 and map != null:
			map.debug_show_cover = not map.debug_show_cover
			map.queue_redraw()
		elif event.keycode == KEY_R:
			var game := get_node_or_null("/root/Game")
			if game != null:
				game.call("load_battle")


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
		_spawn_unit(PLAYER_TEAM, blue_cells[i % blue_cells.size()])
		_spawn_unit(ENEMY_TEAM, red_cells[i % red_cells.size()])
	# 蓝方守、红方攻：这样一开局就能看到 Utility AI 分化出不同行为。
	_issue_initial_orders()


func _spawn_unit(team: int, cell: Vector2i) -> void:
	if map == null:
		return
	var unit := SOLDIER_SCENE.instantiate()
	unit.set("team", team)
	unit.set("current_order", "hold")
	unit.name = _next_unit_name(team)
	map.add_child(unit)
	unit.global_position = map.world_pos(cell)
	units.append(unit)


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
	var text: String = "命令: %s    [1]进攻 [2]防守 [3]包抄 [4]待命    [F1]掩体热区 [R]重开\n" % order
	var blue_alive: int = 0
	var red_alive: int = 0
	for unit in units:
		if unit.get("is_dead") == true:
			continue
		if int(unit.get("team")) == PLAYER_TEAM:
			blue_alive += 1
		else:
			red_alive += 1
	text += "蓝方 %d 存活    红方 %d 存活\n" % [blue_alive, red_alive]
	text += "— 士兵自主决策 —\n"
	for unit in units:
		if unit.get("is_dead") == true:
			text += "%s  已阵亡\n" % _unit_tag(unit)
			continue
		text += "%s  hp=%d  压制=%.2f  命令=%s  行为=%s\n" % [
			_unit_tag(unit),
			int(unit.get("hp")),
			float(unit.get("suppression")),
			String(unit.get("current_order")),
			String(unit.call("current_action")),
		]
	hud_label.text = text


func _unit_tag(unit) -> String:
	return String(unit.get("name"))
