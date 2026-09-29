# 近战与战术姿态（M8）：肉搏、扑倒、滑铲的效用打分与行为树叶子。
# 从 soldier_ai.gd 分出来是因为那个文件 978 行、gdlint 上限 1000，
# 装不下三个新考虑因素；这几个动作在语义上也自成一簇——都是"贴身或保命"，
# 而不是"去哪儿"。打分与树都在这里，soldier_ai 只负责把它们并进自己的表和树。
class_name Tactics
extends RefCounted

const ACTION_MELEE := &"melee"
const ACTION_PRONE := &"prone"
const ACTION_SLIDE := &"slide"

## 肉搏的基础分。没有敌人贴身时一律 0——这一项平时不该干扰任何别的决策。
const MELEE_SCORE_BASE := 0.9

## 扑倒：压制到这个值以上、且身边三格内没有可躲的掩体才趴下。
const PRONE_SUPPRESSION := 0.75
const PRONE_SCORE := 0.85

## 滑铲：命令够明确（进攻/包抄）、且正处在火力里才滑。
const SLIDE_ORDER_MIN := 0.7
const SLIDE_DANGER := 0.4

## 权重。这三个都注册在最后，而 UtilityAI 用严格大于、平分归先注册者，
## 所以要在"该赢的时候"赢过先注册的 seek_cover（权重 1.05）就得靠权重。
## 数值关系：扑倒 0.85x1.4=1.19 > seek_cover 1.05，但 < 投降 1.5（投降是更大的决定）。
const MELEE_WEIGHT := 1.25
const PRONE_WEIGHT := 1.4

## 危险评估半径（像素）。与 SoldierAI 的 SCAN_RADIUS 保持一致。
const DANGER_RADIUS := 360.0

## 身边多少格内算"有掩体可躲"。有的话 seek_cover 严格优于趴下。
const COVER_PROBE_CELLS := 3

var soldier: CharacterBody2D = null
var map = null
var weapon = null
var perc: Perception = null


## 一次性接线。所有引用在 _ready 之后都不再变化。
func setup(
	unit: CharacterBody2D, battle_map, unit_weapon, perception: Perception
) -> void:
	soldier = unit
	map = battle_map
	weapon = unit_weapon
	perc = perception


## 把三个考虑因素并进 SoldierAI 的效用表。必须在它自己的注册之后调用，
## 否则平局会先归它们，而那不是我们想要的默认方向。
func register_into(utility: UtilityAI) -> void:
	utility.register_consideration(
		ACTION_MELEE, score_melee, 0.0, 1.0, MELEE_WEIGHT, UtilityAI.CurveType.LINEAR
	)
	utility.register_consideration(
		ACTION_PRONE, score_prone, 0.0, 1.0, PRONE_WEIGHT, UtilityAI.CurveType.LINEAR
	)
	utility.register_consideration(
		ACTION_SLIDE, score_slide, 0.0, 1.0, 1.0, UtilityAI.CurveType.LINEAR
	)


## 三棵树都是单叶子：这几个动作没有"先接近再执行"的中间步骤，
## 接近本身就写在叶子内部（够不着就贴上去，下一周期再打）。
func build_trees() -> Dictionary:
	return {
		ACTION_MELEE: BehaviorTree.action(ACTION_MELEE, _do_melee),
		ACTION_PRONE: BehaviorTree.action(ACTION_PRONE, _do_prone),
		ACTION_SLIDE: BehaviorTree.action(ACTION_SLIDE, _do_slide),
	}


# ---------------------------------------------------------------- 打分


## 肉搏分。打光子弹之后这一项是唯一的输出手段，所以那时直接给满分。
func score_melee() -> float:
	if soldier == null or weapon == null:
		return 0.0
	if _nearest_enemy(_melee_reach()) == null:
		return 0.0
	var score: float = MELEE_SCORE_BASE
	if weapon.has_method("is_dry") and bool(weapon.call("is_dry")):
		score = 1.0
	# 贴着脸还因为害怕而不动手是最蠢的，所以压制只打折、不清零。
	return clampf(score * (1.0 - perc.suppression() * 0.25), 0.0, 1.0)


## 扑倒分。前提是"被打得很惨"和"附近确实没地方躲"两个都成立。
func score_prone() -> float:
	if soldier == null or perc == null:
		return 0.0
	if perc.suppression() < PRONE_SUPPRESSION:
		return 0.0
	if _cover_within(COVER_PROBE_CELLS):
		return 0.0  # 有掩体就去掩体；趴下是没得选的下策，不是更优解
	return PRONE_SCORE


## 滑铲分。滑铲本质是"不会被压制打折的推进"——这正是它存在的理由，
## 所以分数跟着命令强度走，而不是跟着危险走（危险只做入场券）。
func score_slide() -> float:
	if soldier == null or perc == null:
		return 0.0
	if soldier.get("posture") == Soldier.POSTURE_SLIDE:
		return 0.0
	if float(soldier.get("slide_cooldown")) > 0.0:
		return 0.0
	var order: float = perc.order_priority()
	if order < SLIDE_ORDER_MIN:
		return 0.0
	var danger: float = perc.danger_pressure(DANGER_RADIUS)
	if danger < SLIDE_DANGER:
		return 0.0
	return clampf(order * (1.0 + 0.15 * danger), 0.0, 1.2)


# ---------------------------------------------------------------- 行为


## 肉搏：够不着就贴上去，够得着就抡一下。返回 SUCCESS 表示这一下交出去了，
## 冷却没转好时它同样返回 SUCCESS——下个思考周期再抡，不需要原地空转。
func _do_melee(_ctx: Dictionary, _delta: float) -> int:
	var reach: float = _melee_reach()
	var enemy = _nearest_enemy(reach)
	if enemy == null:
		return BehaviorTree.Status.FAILURE
	if soldier.global_position.distance_to(enemy.global_position) > reach:
		_move_to(map.cell_at(enemy.global_position))
		return BehaviorTree.Status.RUNNING
	weapon.call("try_melee", enemy)
	return BehaviorTree.Status.SUCCESS


## 扑倒：就地趴下。起身不用这里管——士兵一开始移动就会自动站直，
## 压制消散也会自己起来（见 soldier.gd 的 _update_posture）。
func _do_prone(_ctx: Dictionary, _delta: float) -> int:
	soldier.call("stop_moving")
	soldier.set("posture", Soldier.POSTURE_PRONE)
	return BehaviorTree.Status.SUCCESS


## 滑铲：朝看得见的敌人方向冲一段。滑铲不是逃跑动作，所以没有目标就干脆不滑。
func _do_slide(_ctx: Dictionary, _delta: float) -> int:
	if soldier.get("posture") == Soldier.POSTURE_SLIDE:
		return BehaviorTree.Status.RUNNING  # 还在滑，等它滑完
	var enemy = perc.visible_enemy(DANGER_RADIUS * 2.0)
	if enemy == null:
		return BehaviorTree.Status.FAILURE
	soldier.set("posture", Soldier.POSTURE_SLIDE)
	if soldier.get("posture") != Soldier.POSTURE_SLIDE:
		return BehaviorTree.Status.FAILURE  # 冷却没过（打分时不该走到这里）
	_move_to(map.cell_at(enemy.global_position))
	return BehaviorTree.Status.RUNNING


# ---------------------------------------------------------------- 查询


## 射程内、站着能打的最近敌人；没有则 null。俘虏不算——他不在场上。
## 肉搏半径。从武器读而不是自己定义常量：否则两个数字会各改各的。
func _melee_reach() -> float:
	if weapon == null:
		return 0.0
	return float(weapon.get("melee_range"))


func _nearest_enemy(radius: float):
	if soldier == null or perc == null:
		return null
	var best = null
	var best_dist: float = radius
	for enemy in perc.nearby_enemies(radius):
		var d: float = soldier.global_position.distance_to(enemy.global_position)
		if d <= best_dist:
			best_dist = d
			best = enemy
	return best


## 半径（格）内有没有 cover 地形。cover 格本身不可走，但贴着它就能挡住弹道。
func _cover_within(radius: int) -> bool:
	if soldier == null or map == null:
		return false
	var origin: Vector2i = map.cell_at(soldier.global_position)
	for cell in map.cells_in_radius(origin, radius):
		if map.get_terrain(cell) == "cover":
			return true
	return false


func _move_to(cell: Vector2i) -> void:
	if map == null or soldier == null:
		return
	soldier.call("move_to_cell", cell)
