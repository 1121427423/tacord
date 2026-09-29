# 全局游戏服务（autoload 单例 Game）：场景引导、指挥官命令下发、地图与部队的全局访问入口。
extends Node

signal order_issued(team: int, order: StringName)
signal battle_map_ready(map: Node2D)

## 某队失去了它曾经拥有过的最后一座 FOB —— MVP 的失败条件。
signal team_defeated(team: int)

## 建筑落点（M6）。
signal build_site_placed(site: BuildSite)

## 有人接手押送一个俘虏（M7）。投降本身的事件在 soldier.gd 的 surrendered 信号上。
signal escort_claimed(captive: CharacterBody2D, captor_team: int)

## 审讯完成并得到敌方工事情报。
signal intel_gained(team: int, revealed: Array)

## 默认战斗场景；load_battle() 可换成别的地图。
const BATTLE_SCENE_PATH := "res://scenes/battle/battle_map.tscn"

## 玩家阵营。
const PLAYER_TEAM := 1

## 部队上限：基础值 + 每座建成 FOB 的加成。
const BASE_UNIT_CAP := 6
const UNITS_PER_FOB := 3

## 审讯必须在己方建成的 FOB 旁边进行，这个距离以内才算「押到了」（M7）。
const INTERROGATE_RADIUS := 64.0

## MVP 按键绑定（后续迁到 Input Map 以支持重绑定）。
const ORDER_KEYS := {
	KEY_1: &"attack",
	KEY_2: &"defend",
	KEY_3: &"flank",
	KEY_4: &"hold",
}

## 当前战斗地图（battle_map.gd 实例）。由地图自己在 _ready() 里注册进来。
var battle_map: Node2D = null

## 玩家阵营当前的宏观命令。
var current_order: StringName = &"hold"

# 每队一块黑板（team -> Blackboard）。同队士兵共享敌情，换局时清空。
var _boards: Dictionary = {}

# team -> 是否曾经拥有过建成的 FOB。判负的前提是"曾经有过"，
# 否则开局谁都没建 FOB，双方会立刻同时判负。
var _fob_had: Dictionary = {}

# team -> 是否已经判负（避免每帧重复发信号）。
var _defeated: Dictionary = {}

# 俘虏 -> 押送者（M7）。押送权要唯一，否则三个兵会去拖同一个人。
var _escorts: Dictionary = {}

# 已经审过的俘虏：情报只值一次，不能押着同一个人反复问。
var _interrogated: Dictionary = {}


func _ready() -> void:
	# 主场景由 project.godot 的 run/main_scene 自动加载；
	# 这里延迟到第一帧末尾做引导校验，此时 BattleMap 已经 _ready 并完成自注册。
	call_deferred("_boot")


func _process(delta: float) -> void:
	# 黑板的时钟统一由 Game 推进：一队一块，不会因为有 6 个士兵就走快 6 倍。
	for board in _boards.values():
		board.advance(delta)
	_check_fob_defeat()
	_check_captives()


func _boot() -> void:
	if battle_map != null:
		return
	var map := get_tree().get_first_node_in_group(&"battle_map")
	if map != null:
		set_battle_map(map)
	else:
		push_warning("Game: 场景树里没有 BattleMap（group: battle_map），命令无法下发。")


## 由 BattleMap 自己调用，完成“输入 -> Game -> BattleMap”的接线。
func set_battle_map(map: Node2D) -> void:
	battle_map = map
	battle_map_ready.emit(map)


## 全局访问地图（可能为 null）。
func map() -> Node2D:
	return battle_map


## 取某队的小队黑板（没有就新建）。士兵 AI 在 _ready 里从这里拿到自己的黑板。
func blackboard(team: int) -> Blackboard:
	if not _boards.has(team):
		_boards[team] = Blackboard.new()
	return _boards[team]


## 一声枪响：记到所有**敌队**的黑板上。
## 自己队不用记——他们知道自己在开枪；枪声的价值在于让听不见看不见的敌人暴露位置。
func hear_gunshot(world_pos: Vector2, shooter_team: int) -> void:
	for team in _boards.keys():
		if int(team) != shooter_team:
			_boards[team].report_gunshot(world_pos, shooter_team)


## 清空所有敌情记忆（重开一局时调用）。
## 注意是清每块黑板的内容，不是丢掉字典：活着的士兵手里握着这些黑板的引用，
## 换掉对象会让 hear_gunshot 写进一块没人读的新黑板。
func clear_boards() -> void:
	for board in _boards.values():
		board.clear()


## 放下一个建筑工地（M6）。落点不可走或没有地图时返回 null。
func place_build_site(kind: StringName, cell: Vector2i, team: int) -> BuildSite:
	if battle_map == null or not battle_map.has_method("is_walkable"):
		return null
	if not bool(battle_map.call("is_walkable", cell)):
		return null
	var site := BuildSite.new()
	site.kind = kind
	site.team = team
	site.cell = cell
	battle_map.add_child(site)
	site.global_position = battle_map.call("world_pos", cell)
	if not _fob_had.has(team):
		_fob_had[team] = false
	build_site_placed.emit(site)
	return site


## 某队已建成的 FOB 数量。
func fob_count(team: int) -> int:
	var count: int = 0
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != team:
			continue
		if site.get("is_built") == true and site.get("kind") == &"fob":
			count += 1
	return count


## 部队上限：基础值 + 每座建成 FOB 的加成。
func unit_cap(team: int) -> int:
	return BASE_UNIT_CAP + UNITS_PER_FOB * fob_count(team)


## 该队是否还能补人（主场景的生成入口按它拦）。
func can_reinforce(team: int) -> bool:
	return alive_count(team) < unit_cap(team)


## 还活着的俘虏；captor_team < 0 表示全部（M7）。
func captives(captor_team: int = -1) -> Array:
	var out: Array = []
	for unit in soldiers(-1):
		if unit.get("is_captive") != true or unit.get("is_dead") == true:
			continue
		if captor_team >= 0 and int(unit.get("captor_team")) != captor_team:
			continue
		out.append(unit)
	return out


## 认领一个俘虏的押送权。已有人在押则返回 false（押送权唯一）。
func claim_escort(captive, escort) -> bool:
	if captive == null or escort == null:
		return false
	var current = _escorts.get(captive)
	if current != null and is_instance_valid(current) and current.get("is_dead") != true:
		return false
	_escorts[captive] = escort
	escort_claimed.emit(captive, int(captive.get("captor_team")))
	return true


## 放弃押送权（行为被打断、目标换了）。押送者本人没了由 _check_captives 兜。
func drop_escort(captive, escort) -> void:
	if captive == null:
		return
	var current = _escorts.get(captive)
	if current == escort:
		_escorts.erase(captive)


## 审讯俘虏，把敌方**已建成**的工事写进本队黑板。返回新揭露的坐标列表。
## 必须在己方建成的 FOB 旁边进行——审讯要有个地方审，这也让押送有终点。
func interrogate(captive) -> Array:
	if captive == null or not is_instance_valid(captive) or _interrogated.has(captive):
		return []
	if captive.get("is_captive") != true or captive.get("is_dead") == true:
		return []
	var captor_team: int = int(captive.get("captor_team"))
	if not _near_own_fob(captive.global_position, captor_team):
		return []
	_interrogated[captive] = true
	var board := blackboard(captor_team)
	var revealed: Array = []
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) == captor_team or site.get("is_built") != true:
			continue
		if board.report_structure(site.global_position, int(site.get("team"))):
			revealed.append(site.global_position)
	if not revealed.is_empty():
		intel_gained.emit(captor_team, revealed)
	return revealed


## 某坐标是否落在该队已建成 FOB 的审讯半径内。
func _near_own_fob(world_pos: Vector2, team: int) -> bool:
	for site in get_tree().get_nodes_in_group(&"build_sites"):
		if int(site.get("team")) != team:
			continue
		if not site.has_method("is_supply_point") or not bool(site.call("is_supply_point")):
			continue
		if world_pos.distance_to(site.global_position) <= INTERROGATE_RADIUS:
			return true
	return false


## 押送者阵亡/倒地，或押送方全军覆没 -> 俘虏跑掉。
## 这让押送成为一件有风险的事，而不是免费的搬运。
func _check_captives() -> void:
	for captive in _escorts.keys():
		if not is_instance_valid(captive) or captive.get("is_captive") != true:
			_escorts.erase(captive)
			_interrogated.erase(captive)
			continue
		var escort = _escorts[captive]
		var escort_gone: bool = (
			not is_instance_valid(escort)
			or escort.get("is_dead") == true
			or escort.get("is_downed") == true
			or alive_count(int(captive.get("captor_team"))) <= 0
		)
		if escort_gone:
			_escorts.erase(captive)
			captive.call("release")


## 某队是否已经因为失去全部 FOB 而判负。
func is_team_defeated(team: int) -> bool:
	return bool(_defeated.get(team, false))


## 失去曾经拥有过的最后一座 FOB 即判负。
func _check_fob_defeat() -> void:
	for team in _fob_had.keys():
		if bool(_defeated.get(team, false)):
			continue
		if fob_count(int(team)) > 0:
			_fob_had[team] = true
		elif bool(_fob_had[team]):
			_defeated[team] = true
			team_defeated.emit(int(team))


## 加载 / 重开一局战斗场景。
func load_battle(path: String = BATTLE_SCENE_PATH) -> void:
	battle_map = null
	# 上一局的敌情记忆不能带进新局。
	clear_boards()
	_fob_had.clear()
	_defeated.clear()
	_escorts.clear()
	_interrogated.clear()
	var error := get_tree().change_scene_to_file(path)
	if error != OK:
		push_error("Game: 无法加载战斗场景 %s (error=%d)" % [path, error])


## 指挥官命令入口：输入事件 -> Game -> BattleMap -> 士兵。
func issue_order(order: StringName, team: int = PLAYER_TEAM) -> void:
	current_order = order
	if battle_map != null and battle_map.has_method("issue_order"):
		battle_map.call("issue_order", order, team)
	order_issued.emit(team, order)


## 按阵营取士兵；team < 0 表示全部。
func soldiers(team: int = -1) -> Array:
	var all_units: Array = get_tree().get_nodes_in_group(&"soldiers")
	if team < 0:
		return all_units
	var filtered: Array = []
	for unit in all_units:
		if int(unit.get("team")) == team:
			filtered.append(unit)
	return filtered


func alive_count(team: int) -> int:
	var count: int = 0
	for unit in soldiers(team):
		if unit.get("is_dead") != true:
			count += 1
	return count


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	if not ORDER_KEYS.has(event.keycode):
		return
	issue_order(ORDER_KEYS[event.keycode])
