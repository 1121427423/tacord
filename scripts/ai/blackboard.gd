# 小队黑板：同队共享的敌情记忆（目击 + 枪声），是 M4「感知与记忆」的唯一事实来源。
class_name Blackboard
extends RefCounted

## 记忆保鲜期（秒）。过期就忘掉，免得士兵永远朝着开局那一声枪响搜索。
const MEMORY_TTL := 12.0

## 最多记住的枪声条数（超出就丢最旧的）。
const MAX_GUNSHOTS := 8

## 黑板自己的时钟。由拥有者（Game）用 advance() 推进，测试可以直接传大步长。
var now: float = 0.0

# 敌方单位 -> {"pos": Vector2, "time": float}，最后一次被真正看见的位置。
var _sightings: Dictionary = {}

# 听见的枪声：[{"pos": Vector2, "time": float, "team": int, "id": int}]。
var _gunshots: Array = []

var _next_shot_id: int = 1


## 推进时钟并清理过期记忆。测试里可以一次推进十几秒来验证遗忘。
func advance(delta: float) -> void:
	now += maxf(0.0, delta)
	_prune()


## 看见了一个敌人（必须有通视，不能靠猜）。
func report_sighting(unit, world_pos: Vector2) -> void:
	if unit == null:
		return
	_sightings[unit] = {"pos": world_pos, "time": now}


func has_sighting(unit) -> bool:
	return _sightings.has(unit)


## 某个敌人的最后已知位置；没有记忆返回空字典。
func memory_of(unit) -> Dictionary:
	var entry = _sightings.get(unit)
	if entry == null:
		return {}
	return {"pos": entry["pos"], "age": now - float(entry["time"]), "kind": &"sighting"}


## 听见一声枪响。shooter_team 让听者能分辨是自己人还是敌人在开火。
func report_gunshot(world_pos: Vector2, shooter_team: int) -> int:
	var shot_id: int = _next_shot_id
	_next_shot_id += 1
	_gunshots.append({"pos": world_pos, "time": now, "team": shooter_team, "id": shot_id})
	if _gunshots.size() > MAX_GUNSHOTS:
		_gunshots.pop_front()
	return shot_id


## 听者听得见的、来自敌队的最近一声枪响；没有则返回空字典。
## 声音不看视线：墙挡得住子弹，挡不住枪声。
func nearest_enemy_gunshot(listener_pos: Vector2, my_team: int, radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: float = radius
	for shot in _gunshots:
		if int(shot["team"]) == my_team:
			continue
		var distance: float = listener_pos.distance_to(shot["pos"])
		if distance < best_dist:
			best_dist = distance
			best = {
				"pos": shot["pos"],
				"id": int(shot["id"]),
				"age": now - float(shot["time"]),
				"kind": &"gunshot",
			}
	return best


## 敌队最近（时间上最新）的一声枪响；没有则返回空字典。
## 与 nearest_enemy_gunshot 的区别：这个不看听者位置，用于"小队整体该往哪查"。
func latest_enemy_gunshot(my_team: int) -> Dictionary:
	var best: Dictionary = {}
	var best_time: float = -INF
	for shot in _gunshots:
		if int(shot["team"]) == my_team:
			continue
		if float(shot["time"]) > best_time:
			best_time = float(shot["time"])
			best = {
				"pos": shot["pos"],
				"id": int(shot["id"]),
				"age": now - float(shot["time"]),
				"kind": &"gunshot",
			}
	return best


## 最值得去查的一条记忆（目击优先于枪声，其次看新鲜度）；没有则返回空字典。
func best_memory(my_team: int) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1.0
	for unit in _sightings.keys():
		var entry = _sightings[unit]
		# 目击比枪声更值得追：那是真看见过的人。
		var score: float = 2.0 - clampf((now - float(entry["time"])) / MEMORY_TTL, 0.0, 1.0)
		if score > best_score:
			best_score = score
			best = {"pos": entry["pos"], "age": now - float(entry["time"]), "kind": &"sighting"}
	var shot: Dictionary = latest_enemy_gunshot(my_team)
	if not shot.is_empty():
		var shot_score: float = 1.0 - clampf(float(shot["age"]) / MEMORY_TTL, 0.0, 1.0)
		if shot_score > best_score:
			best = shot
	return best


func clear() -> void:
	_sightings.clear()
	_gunshots.clear()


func _prune() -> void:
	for unit in _sightings.keys():
		if now - float(_sightings[unit]["time"]) > MEMORY_TTL:
			_sightings.erase(unit)
	var kept: Array = []
	for shot in _gunshots:
		if now - float(shot["time"]) <= MEMORY_TTL:
			kept.append(shot)
	_gunshots = kept
