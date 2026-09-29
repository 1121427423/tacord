# 全局游戏服务（autoload 单例 Game）：场景引导、指挥官命令下发、地图与部队的全局访问入口。
extends Node

signal order_issued(team: int, order: StringName)
signal battle_map_ready(map: Node2D)

## 默认战斗场景；load_battle() 可换成别的地图。
const BATTLE_SCENE_PATH := "res://scenes/battle/battle_map.tscn"

## 玩家阵营。
const PLAYER_TEAM := 1

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


func _ready() -> void:
	# 主场景由 project.godot 的 run/main_scene 自动加载；
	# 这里延迟到第一帧末尾做引导校验，此时 BattleMap 已经 _ready 并完成自注册。
	call_deferred("_boot")


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


## 加载 / 重开一局战斗场景。
func load_battle(path: String = BATTLE_SCENE_PATH) -> void:
	battle_map = null
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
