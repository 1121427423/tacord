# 态势感知：把 soldier / weapon / 场景树里的原始读数算成效用打分要用的 [0,1] 量。
# 全是纯查询、不持有可变状态，效用打分与行为树共用同一份判断。
# 从 soldier_ai.gd 拆出来的直接原因是那个文件顶到了 gdlint 的 max-file-lines(1000)；
# 但感知本来就该和决策分开——这里没有一个函数会改动世界。
class_name Perception
extends RefCounted

## 命令优先级：宏观命令通过它影响效用打分，士兵仍然自己决定怎么执行。
const ORDER_PRIORITY := {
	"attack": 1.0,
	"flank": 0.8,
	"defend": 0.35,
	"hold": 0.15,
	"retreat": 0.0,
}

## 没听过的命令按这个优先级算。
const DEFAULT_ORDER_PRIORITY := 0.15

## 所属士兵（soldier.gd）。
var soldier: CharacterBody2D = null

# BattleMap（battle_map.gd）。故意不标注类型以便鸭子调用 has_line_of_sight 等接口。
var map = null

# Weapon 组件（soldier 的子节点），同样不标注类型。
var weapon = null

## 场景树：士兵都在 &"soldiers" 组里，任何"看看四周"的查询都得过树。
var tree: SceneTree = null


## 一次性接线。四个引用在 SoldierAI._ready 之后都不再变化。
func setup(
	unit: CharacterBody2D, battle_map, unit_weapon, scene_tree: SceneTree
) -> void:
	soldier = unit
	map = battle_map
	weapon = unit_weapon
	tree = scene_tree


func suppression() -> float:
	if soldier == null:
		return 0.0
	return clampf(float(soldier.get("suppression")), 0.0, 1.0)


func health_ratio() -> float:
	if soldier == null:
		return 0.0
	var max_hp: float = maxf(1.0, float(soldier.get("max_hp")))
	return clampf(float(soldier.get("hp")) / max_hp, 0.0, 1.0)


## 弹药压力 [0,1]：正在换弹或弹匣已空最急，其余按弹匣余量线性。
func ammo_pressure() -> float:
	if weapon == null:
		return 0.0
	if weapon.get("is_reloading") == true:
		return 1.0
	var mag: int = int(weapon.get("magazine_size"))
	if mag <= 0:
		return 0.0
	return 1.0 - clampf(float(int(weapon.get("ammo_in_mag"))) / float(mag), 0.0, 1.0)


## 彻底打光（弹匣与备弹都空）时返回 1，否则 0。
func dry_factor() -> float:
	if weapon == null or not weapon.has_method("is_dry"):
		return 0.0
	return 1.0 if weapon.call("is_dry") else 0.0


## 当前宏观命令的优先级 [0,1]。
func order_priority() -> float:
	if soldier == null:
		return 0.0
	return float(
		ORDER_PRIORITY.get(String(soldier.get("current_order")), DEFAULT_ORDER_PRIORITY)
	)


## 半径内的敌方单位（排除自己、友军、倒地者与俘虏）。
func nearby_enemies(radius: float) -> Array:
	var out: Array = []
	if soldier == null or tree == null:
		return out
	var my_team: int = int(soldier.get("team"))
	# 士兵 + 装甲车都算敌人。载具自成 vehicles 组（救援、押送、帐篷治疗、
	# FOB 补弹都只扫 soldiers，它不进去就不会被那些逻辑误伤），
	# 所以这里显式多扫一个组。现有三个测试场景没有载具，
	# 第二个组恒返回 []，这条改动对 220 条断言零扰动。
	for group in [&"soldiers", &"vehicles"]:
		for unit in tree.get_nodes_in_group(group):
			if unit == soldier or int(unit.get("team")) == my_team:
				continue
			# 倒地的人不算有效目标：不鞭尸，也不为已经趴下的敌人计算危险压力。
			# 俘虏同理——他已经退出战斗，围着他不会让人更想投降。
			# 载具的 is_downed / is_captive 恒为 false（它不会倒地也不会被俘）。
			if unit.get("is_dead") == true or unit.get("is_downed") == true:
				continue
			if unit.get("is_captive") == true:
				continue
			if soldier.global_position.distance_to(unit.global_position) <= radius:
				out.append(unit)
	return out


## 最近的、还站着能打的友军（排除倒地与已被俘的）；没有则返回 null。
## 投降判定的「无援」就是问这个。
func nearest_standing_ally(radius: float):
	return _nearest_ally(radius, false)


## 最近的倒地友军；没有则返回 null。
func nearest_downed_ally(radius: float):
	return _nearest_ally(radius, true)


## 有通视的最近敌人（不限射程，用于决定往哪推进）；没有则 null。
func visible_enemy(radius: float):
	if soldier == null or map == null:
		return null
	var best = null
	var best_dist: float = radius
	for enemy in nearby_enemies(radius):
		if not map.has_line_of_sight(soldier.global_position, enemy.global_position):
			continue
		var distance: float = soldier.global_position.distance_to(enemy.global_position)
		if distance <= best_dist:
			best_dist = distance
			best = enemy
	return best


## 危险压力 [0,1]：距离越近、越被通视，压力越大。
func danger_pressure(radius: float) -> float:
	var enemies := nearby_enemies(radius)
	if enemies.is_empty():
		return 0.0
	var pressure: float = 0.0
	for enemy in enemies:
		var distance: float = soldier.global_position.distance_to(enemy.global_position)
		var proximity: float = 1.0 - clampf(distance / radius, 0.0, 1.0)
		var visible: float = 1.0
		if map != null and map.has_method("has_line_of_sight"):
			visible = (
				1.0
				if map.has_line_of_sight(soldier.global_position, enemy.global_position)
				else 0.0
			)
		pressure += proximity * (0.35 + 0.65 * visible)
	return clampf(pressure / 2.0, 0.0, 1.0)


## 侧翼机会 [0,1]：我们处在敌人朝向的侧后方时接近 1（它的侧面/背面对我们敞开）。
func flank_opportunity(radius: float) -> float:
	var best: float = 0.0
	for enemy in nearby_enemies(radius):
		best = maxf(best, flank_alignment(enemy))
	return best


func flank_alignment(enemy) -> float:
	var facing: Vector2 = enemy.get("facing")
	var to_us: Vector2 = soldier.global_position - enemy.global_position
	if facing.length_squared() < 0.0001 or to_us.length_squared() < 1.0:
		return 0.0
	# dot = 1 表示我们正对它（无机会）；dot = -1 表示我们在它正后方（机会最大）。
	return clampf(-facing.normalized().dot(to_us.normalized()), 0.0, 1.0)


## FPV 逼近度 [0,1]：半径内最近敌方 FPV，距离越近越接近 1；没有则 0。
## 这是「听到」的专用读数（听到 = 未必看见）：nearby_enemies 把 FPV 当普通
## 敌人收进开火链路（它就在 vehicles 组，士兵据此可以打它），这里只回答
## 「有没有自杀无人机正冲我来」。识别约定（鸭子）：认 has_method("explode")
## ——场上只有 FPV 自杀无人机提供自爆接口，侦察机与坦克都没有，不靠
## class_name 也能认出它；nearby_enemies 的过滤顺带把坠毁的残骸筛掉——哑弹不吓人。
func fpv_threat(radius: float) -> float:
	var best: float = 0.0
	for enemy in nearby_enemies(radius):
		if not enemy.has_method("explode"):
			continue
		var distance: float = soldier.global_position.distance_to(enemy.global_position)
		best = maxf(best, 1.0 - clampf(distance / radius, 0.0, 1.0))
	return best


## 「站着能打的」与「倒地的」两种最近友军，只差一个过滤条件。
func _nearest_ally(radius: float, downed_only: bool):
	if soldier == null or tree == null:
		return null
	var best = null
	var best_dist: float = radius
	var my_team: int = int(soldier.get("team"))
	for unit in tree.get_nodes_in_group(&"soldiers"):
		if unit == soldier or int(unit.get("team")) != my_team:
			continue
		if unit.get("is_dead") == true:
			continue
		if downed_only:
			if unit.get("is_downed") != true:
				continue
		elif unit.get("is_downed") == true or unit.get("is_captive") == true:
			continue
		var d: float = soldier.global_position.distance_to(unit.global_position)
		if d <= best_dist:
			best_dist = d
			best = unit
	return best
