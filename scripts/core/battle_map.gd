# 地图管理器：网格/世界坐标互转、地形数据、AStar2D 寻路，以及基于真实几何的掩体评估查询。
extends Node2D

signal terrain_changed(cell: Vector2i, terrain: StringName)
signal path_graph_rebuilt()

## 地形类型。cover / blocked 都会生成实体碰撞体并阻挡视线，区别在于语义与配色。
const TERRAIN_OPEN := &"open"
const TERRAIN_COVER := &"cover"
const TERRAIN_HIGH := &"high"
const TERRAIN_BLOCKED := &"blocked"

## 不可走的地形：凡是 add_obstacle() 会生成实体碰撞体的类型都必须列在这里，
## 否则 A* 会规划出"穿墙"路径，士兵被 move_and_slide 卡在墙上永远走不到终点。
const UNWALKABLE_TERRAIN := [&"cover", &"blocked"]

## 物理层：1 = 单位，2 = 静态障碍（墙/木箱）。视线射线只打第 2 层。
const LAYER_UNITS := 1
const LAYER_OBSTACLES := 2

const TERRAIN_COLORS := {
	&"open": Color(0.216, 0.227, 0.251),
	&"cover": Color(0.125, 0.129, 0.141),
	&"high": Color(0.412, 0.545, 0.706),
	&"blocked": Color(0.086, 0.09, 0.102),
}

const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.045)
const BORDER_COLOR := Color(1.0, 1.0, 1.0, 0.18)

## 网格尺寸：32 列 x 24 行。
@export var grid_size: Vector2i = Vector2i(32, 24)

## 每格边长（像素）。
@export var cell_size: int = 32

@export var show_grid: bool = true

## F1 打开：把每个格子相对敌方的掩体得分画成热区，用于验证“掩体是算出来的，不是标出来的”。
@export var debug_show_cover: bool = false

## key = Vector2i 格子坐标，value = 地形类型 StringName。
var terrain: Dictionary = {}

var _astar: AStar2D = AStar2D.new()
var _obstacles: Node2D = null


func _ready() -> void:
	add_to_group(&"battle_map")
	_obstacles = Node2D.new()
	_obstacles.name = &"Obstacles"
	add_child(_obstacles)
	_init_terrain()
	rebuild_pathfinding()
	# 向全局 Game（autoload）注册自己，把输入事件与地图打通。
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("set_battle_map"):
		game.call("set_battle_map", self)
	queue_redraw()


# ---------------------------------------------------------------- 坐标与地形查询


## 把整张地图初始化为 open 地形（terrain 字典的 key 覆盖每一个格子）。
func _init_terrain() -> void:
	terrain.clear()
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			terrain[Vector2i(x, y)] = TERRAIN_OPEN


## 世界坐标 -> 格子坐标。
func cell_at(world_pos: Vector2) -> Vector2i:
	return Vector2i(floori(world_pos.x / float(cell_size)), floori(world_pos.y / float(cell_size)))


## 格子坐标 -> 格子中心的世界坐标。
func world_pos(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * cell_size + cell_size * 0.5, cell.y * cell_size + cell_size * 0.5)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < grid_size.x and cell.y < grid_size.y


func is_walkable(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return false
	return not UNWALKABLE_TERRAIN.has(terrain.get(cell, TERRAIN_BLOCKED))


func set_terrain(cell: Vector2i, terrain_type: StringName) -> void:
	if not in_bounds(cell):
		push_warning("BattleMap.set_terrain: 越界格子 %s" % str(cell))
		return
	terrain[cell] = terrain_type
	rebuild_pathfinding()
	terrain_changed.emit(cell, terrain_type)
	queue_redraw()


func get_terrain(cell: Vector2i) -> String:
	return String(terrain.get(cell, TERRAIN_BLOCKED))


func map_size() -> Vector2:
	return Vector2(grid_size.x * cell_size, grid_size.y * cell_size)


## 以 cell 为中心、radius 为半径（切比雪夫距离）的所有格子。
func cells_in_radius(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	for y in range(maxi(0, center.y - radius), mini(grid_size.y, center.y + radius + 1)):
		for x in range(maxi(0, center.x - radius), mini(grid_size.x, center.x + radius + 1)):
			out.append(Vector2i(x, y))
	return out


## 距离 cell 最近的可走格子；找不到返回 (-1, -1)。
func nearest_walkable(cell: Vector2i, max_radius: int = 3) -> Vector2i:
	if is_walkable(cell):
		return cell
	var best := Vector2i(-1, -1)
	var best_dist: float = INF
	for candidate in cells_in_radius(cell, max_radius):
		if not is_walkable(candidate):
			continue
		var d: float = float(cell.distance_squared_to(candidate))
		if d < best_dist:
			best_dist = d
			best = candidate
	return best


# ---------------------------------------------------------------- 寻路（AStar2D）


func _point_id(cell: Vector2i) -> int:
	return cell.y * grid_size.x + cell.x


func _id_to_cell(id: int) -> Vector2i:
	return Vector2i(id % grid_size.x, floori(float(id) / float(grid_size.x)))


## 地形变化后重建 A* 点图（4 连通，仅连接可走格子）。
func rebuild_pathfinding() -> void:
	_astar.clear()
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var cell := Vector2i(x, y)
			_astar.add_point(_point_id(cell), world_pos(cell))
	# 只连 RIGHT / DOWN 两个方向并允许双向，等价于完整 4 连通且不会重复连边。
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var cell := Vector2i(x, y)
			if not is_walkable(cell):
				continue
			for offset in [Vector2i.RIGHT, Vector2i.DOWN]:
				var neighbor: Vector2i = cell + offset
				if is_walkable(neighbor):
					_astar.connect_points(_point_id(cell), _point_id(neighbor), true)
	path_graph_rebuilt.emit()


## A* 寻路，返回格子坐标序列（含起点与终点）。
## 目标不可达时返回空数组：allow_partial_path 传 false，否则 A* 会返回一条"走到墙边为止"
## 的半截路径，调用方无法区分"到达终点"和"卡在半路"。
func find_path(from_cell: Vector2i, to_cell: Vector2i) -> Array:
	var result: Array = []
	var start: Vector2i = nearest_walkable(from_cell)
	var goal: Vector2i = nearest_walkable(to_cell)
	if start == Vector2i(-1, -1) or goal == Vector2i(-1, -1):
		return result
	if not _astar.has_point(_point_id(start)) or not _astar.has_point(_point_id(goal)):
		return result
	var world_points: PackedVector2Array = _astar.get_point_path(
		_point_id(start), _point_id(goal), false
	)
	for point in world_points:
		result.append(cell_at(point))
	return result


# ---------------------------------------------------------------- 视线与掩体评估
# 设计要点（对应“没有预设掩体点”的目标）：
# 掩体价值完全由场景里真实存在的碰撞几何 + 地形网格实时算出，
# 一旦有敌人绕到侧翼（射线不再被挡住），这处掩体的分数会立刻掉下来。


## 两点之间是否通视（射线打第 2 层障碍体）。
func has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if from == to:
		return true
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, to, LAYER_OBSTACLES, [])
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query).is_empty()


## 单个格子的掩体得分 [0, 1]：
##   - 主项：对给定威胁列表的真实遮蔽率（射线被几何体挡住的比例）
##   - 次项：紧邻不可走格（可贴靠、可探头-缩回）
##   - 加分：高地
func cover_score(cell: Vector2i, threat_positions: Array) -> float:
	if not is_walkable(cell):
		return 0.0
	var center := world_pos(cell)
	var exposure: float = 0.0
	var threat_count: int = 0
	for threat in threat_positions:
		threat_count += 1
		if has_line_of_sight(center, threat):
			exposure += 1.0
	if threat_count > 0:
		exposure /= float(threat_count)
	var adjacency: float = 0.0
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor: Vector2i = cell + offset
		if in_bounds(neighbor) and not is_walkable(neighbor):
			adjacency += 0.25
	var terrain_bonus: float = 0.12 if get_terrain(cell) == String(TERRAIN_HIGH) else 0.0
	var covered: float = 1.0 - exposure if threat_count > 0 else 0.35
	return clampf(covered * 0.8 + clampf(adjacency, 0.0, 0.5) * 0.25 + terrain_bonus, 0.0, 1.0)


## 在 from_cell 周边 radius 格内找掩体得分最高、且离得最近的格子；找不到返回 (-1, -1)。
func find_cover_cell(from_cell: Vector2i, threat_positions: Array, radius: int = 6) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_value: float = -INF
	for cell in cells_in_radius(from_cell, radius):
		var score: float = cover_score(cell, threat_positions)
		if score <= 0.0:
			continue
		# 同等掩体质量下更倾向近处，避免士兵横穿战场去“更好的掩体”。
		var distance_penalty: float = float(from_cell.distance_to(cell)) * 0.01
		var value: float = score - distance_penalty
		if value > best_value:
			best_value = value
			best = cell
	return best


# ---------------------------------------------------------------- 障碍与命令


## 生成一个占位障碍（StaticBody2D + 矩形碰撞体），同时把该格标记为指定地形。
func add_obstacle(cell: Vector2i, terrain_type: StringName = TERRAIN_COVER) -> void:
	if not in_bounds(cell):
		return
	set_terrain(cell, terrain_type)
	var body := StaticBody2D.new()
	body.collision_layer = LAYER_OBSTACLES
	body.collision_mask = 0
	body.position = world_pos(cell)
	var shape_node := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(cell_size, cell_size)
	shape_node.shape = rect
	body.add_child(shape_node)
	_obstacles.add_child(body)


## 指挥官命令下发：Game -> BattleMap -> 该阵营所有士兵。
func issue_order(order: StringName, team: int = 1) -> void:
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) != team:
			continue
		if unit.has_method("set_order"):
			unit.call("set_order", String(order))


# ---------------------------------------------------------------- 占位渲染


func _draw() -> void:
	_draw_terrain()
	if show_grid:
		_draw_grid()
	if debug_show_cover:
		_draw_cover_heatmap()


func _draw_terrain() -> void:
	var rect_size := Vector2(cell_size, cell_size)
	for cell in terrain:
		var color: Color = TERRAIN_COLORS.get(terrain[cell], TERRAIN_COLORS[TERRAIN_OPEN])
		draw_rect(Rect2(world_pos(cell) - rect_size * 0.5, rect_size), color)


func _draw_grid() -> void:
	var total := map_size()
	for x in range(grid_size.x + 1):
		var px := float(x * cell_size)
		draw_line(Vector2(px, 0.0), Vector2(px, total.y), GRID_COLOR, 1.0)
	for y in range(grid_size.y + 1):
		var py := float(y * cell_size)
		draw_line(Vector2(0.0, py), Vector2(total.x, py), GRID_COLOR, 1.0)
	draw_rect(Rect2(Vector2.ZERO, total), BORDER_COLOR, false, 2.0)


func _draw_cover_heatmap() -> void:
	var threats := _enemy_positions(2)
	if threats.is_empty():
		return
	var rect_size := Vector2(cell_size, cell_size)
	for cell in terrain:
		if not is_walkable(cell):
			continue
		var score: float = cover_score(cell, threats)
		var color := Color(1.0, 0.25, 0.2, 0.35).lerp(Color(0.25, 1.0, 0.45, 0.45), score)
		draw_rect(Rect2(world_pos(cell) - rect_size * 0.5, rect_size), color)


func _enemy_positions(team: int) -> Array:
	var positions: Array = []
	for unit in get_tree().get_nodes_in_group(&"soldiers"):
		if int(unit.get("team")) == team and unit.get("is_dead") != true:
			positions.append(unit.global_position)
	return positions
