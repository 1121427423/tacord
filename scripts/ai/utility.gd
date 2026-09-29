# 通用 Utility AI 评估器：注册若干“考虑因素”，经响应曲线归一化打分，返回得分最高的行为名。
class_name UtilityAI
extends RefCounted

## 响应曲线类型。数值即 _apply_curve() 的分支，Consideration.curve 用裸 int 存储以免内类循环引用。
enum CurveType { LINEAR, TANH, SMOOTHSTEP, STEP }

## 单个考虑因素：一个 Callable + 定义域 [min_value, max_value] + 曲线与权重。
class Consideration:
	extends RefCounted

	var id: StringName = &""
	var source: Callable = Callable()
	var min_value: float = 0.0
	var max_value: float = 1.0
	var weight: float = 1.0
	var curve: int = 1  # UtilityAI.CurveType.TANH
	var slope: float = 1.0
	var raw: float = 0.0  # 最近一次采样的原始输入
	var score: float = 0.0  # 最近一次归一化 + 曲线 + 权重后的得分


## 行为粘性：给“正在执行的行为”额外加分，避免分数抖动导致每个 tick 反复横跳。
var stickiness: float = 0.0

## 最近一次 evaluate() 的全部得分（行为名 -> 分数），供 HUD/调试使用。
var last_scores: Dictionary = {}

## 最近一次 evaluate() 选中的行为名。
var last_action: StringName = &""

var _considerations: Dictionary = {}  # StringName -> Consideration
var _registration_order: Array = []  # 注册顺序，用于稳定的平局裁决


## 注册一个考虑因素。source 必须是返回 float 的无参 Callable。
## 返回 self，方便链式注册。
func register_consideration(
	id: StringName,
	source: Callable,
	min_value: float,
	max_value: float,
	weight: float = 1.0,
	curve: int = CurveType.TANH,
	slope: float = 1.0
) -> UtilityAI:
	var c := Consideration.new()
	c.id = id
	c.source = source
	c.min_value = min_value
	c.max_value = max_value
	c.weight = weight
	c.curve = curve
	c.slope = slope
	_considerations[id] = c
	if not _registration_order.has(id):
		_registration_order.append(id)
	return self


## 采样所有考虑因素并返回得分最高的行为名。
## current_action 传入当前正在执行的行为，可获得 stickiness 加分。
func evaluate(current_action: StringName = &"") -> StringName:
	last_scores.clear()
	var best_id: StringName = &""
	var best_score: float = -INF
	for id in _registration_order:
		var c: Consideration = _considerations[id]
		var raw: float = 0.0
		if c.source.is_valid():
			raw = float(c.source.call())
		c.raw = raw
		var t: float = _normalize(raw, c.min_value, c.max_value)
		var score: float = _apply_curve(t, c.curve, c.slope) * c.weight
		if current_action == c.id:
			score += stickiness
		c.score = score
		last_scores[c.id] = score
		if score > best_score:
			best_score = score
			best_id = c.id
	last_action = best_id
	return best_id


## 某个考虑因素最近一次的最终得分（未找到返回 0.0）。
func score_of(id: StringName) -> float:
	return float(last_scores.get(id, 0.0))


## 某个考虑因素最近一次的原始输入（未找到返回 0.0）。
func raw_of(id: StringName) -> float:
	var c = _considerations.get(id)
	if c == null:
		return 0.0
	return float(c.raw)


func set_weight(id: StringName, weight: float) -> void:
	var c = _considerations.get(id)
	if c != null:
		c.weight = weight


func has_consideration(id: StringName) -> bool:
	return _considerations.has(id)


func considerations() -> Array:
	return _registration_order.duplicate()


func clear() -> void:
	_considerations.clear()
	_registration_order.clear()
	last_scores.clear()
	last_action = &""


## 把任意值域线性映射到 [0, 1]。
func _normalize(value: float, min_value: float, max_value: float) -> float:
	if max_value <= min_value:
		return 1.0 if value >= max_value else 0.0
	return clampf((value - min_value) / (max_value - min_value), 0.0, 1.0)


## 响应曲线：MVP 用简单数学映射，后续可替换为 AnimationCurve 资源以便策划调参。
func _apply_curve(t: float, curve: int, slope: float) -> float:
	match curve:
		CurveType.LINEAR:
			return t
		CurveType.TANH:
			var k: float = maxf(slope, 0.0001)
			return tanh(t * k) / tanh(k)
		CurveType.SMOOTHSTEP:
			return smoothstep(0.0, 1.0, t)
		CurveType.STEP:
			return 1.0 if t >= 0.5 else 0.0
	return t
