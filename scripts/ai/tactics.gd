# 近战与战术姿态（M8）：肉搏、扑倒、滑铲的效用打分与行为树叶子。
# M12 在这里追加：扑倒躲雷（evade）与投掷手雷（throw_grenade）——
# 这两个同样是"贴身或保命"的一簇，归这里管语义最顺。
# 从 soldier_ai.gd 分出来是因为那个文件 978 行、gdlint 上限 1000，
# 装不下更多考虑因素；打分与树都在这里，soldier_ai 只负责把它们并进
# 自己的表和树。
class_name Tactics
extends RefCounted

const ACTION_MELEE := &"melee"
const ACTION_PRONE := &"prone"
const ACTION_SLIDE := &"slide"

# M12：躲雷与投掷。
const ACTION_EVADE := &"evade"
const ACTION_THROW := &"throw_grenade"

## 肉搏的基础分。没有敌人贴身时一律 0——这一项平时不该干扰任何别的决策。
const MELEE_SCORE_BASE := 0.9

## 扑倒：压制到这个值以上、且身边三格内没有可躲的掩体才趴下。
const PRONE_SUPPRESSION := 0.75
const PRONE_SCORE := 0.85

## 滑铲：命令够明确（进攻/包抄）、且正处在火力里才滑。
const SLIDE_ORDER_MIN := 0.7
const SLIDE_DANGER := 0.4

## 躲雷（M12）：分数是二值的——96px 内存在引信 ≤ 1.0s 的雷（含正在空中
## 飞向自己的）就给满。爆炸不等人，这一项不该和危险程度讨价还价。
const EVADE_SCORE := 0.95
const EVADE_RADIUS := 96.0
const EVADE_FUSE_WINDOW := 1.0

## 投掷（M12）：雷是清躲猫猫的最后手段——只对躲起来（无通视）打不着
## 的目标出手，看得见的交给枪。
const THROW_SCORE := 0.85
const THROW_MIN_DIST := 60.0
const THROW_MAX_DIST := 200.0

## 权重。这三个都注册在最后，而 UtilityAI 用严格大于、平分归先注册者，
## 所以要在"该赢的时候"赢过先注册的 seek_cover（权重 1.05）就得靠权重。
## 数值关系：扑倒 0.85x1.4=1.19 > seek_cover 1.05，但 < 投降 1.5（投降是更大的决定）。
const MELEE_WEIGHT := 1.25
const PRONE_WEIGHT := 1.4

## M12 两个新权重，沿用上面那行的算术习惯把账写死。
## 躲雷 0.95x1.3=1.235 > flank 满分 1.0+粘性 0.15=1.15（CI 效用表实测：
## 对远处侧翼暴露的敌兵，flank 是躲雷之外的全场最高分）——保命压过一切
## 进攻选项；但 < 投降 1.5——都来得及举手就还来得及举手。
## 投掷 0.85x1.4=1.19：必须压过 flank 满分 + 粘性（1.15）——CI 首跑实测
## 0.98 输给 1.15，目标躲在掩体后（正是投雷的先决条件）时兵却永远在
## "包抄"侧翼，雷永远扔不出去。代价是 1.19 > seek_cover 1.05：语义成立，
## 因为投雷的先决条件（对目标无通视）恰好把 seek_cover 的高分场景
## （正被通视、挨打）排除在外——两条高分不同时成立。
const EVADE_WEIGHT := 1.3
const THROW_WEIGHT := 1.4

## 危险评估半径（像素）。与 SoldierAI 的 SCAN_RADIUS 保持一致。
const DANGER_RADIUS := 360.0

## 身边多少格内算"有掩体可躲"。有的话 seek_cover 严格优于趴下。
const COVER_PROBE_CELLS := 3

## 手雷场景（M12）：投掷叶子现场实例化。
const GRENADE_SCENE := preload("res://scenes/units/grenade.tscn")

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


## 把五个考虑因素并进 SoldierAI 的效用表。必须在它自己的注册之后调用，
## 否则平局会先归它们，而那不是我们想要的默认方向。
## M12 的两个追加在现有三个之后（注册顺序即平局优先级）。
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
	utility.register_consideration(
		ACTION_EVADE, score_evade, 0.0, 1.0, EVADE_WEIGHT, UtilityAI.CurveType.LINEAR
	)
	utility.register_consideration(
		ACTION_THROW, score_throw, 0.0, 1.0, THROW_WEIGHT, UtilityAI.CurveType.LINEAR
	)


## 五棵树都是单叶子：这几个动作没有"先接近再执行"的中间步骤，
## 接近本身就写在叶子内部（够不着就贴上去，下一周期再打）。
func build_trees() -> Dictionary:
	return {
		ACTION_MELEE: BehaviorTree.action(ACTION_MELEE, _do_melee),
		ACTION_PRONE: BehaviorTree.action(ACTION_PRONE, _do_prone),
		ACTION_SLIDE: BehaviorTree.action(ACTION_SLIDE, _do_slide),
		ACTION_EVADE: BehaviorTree.action(ACTION_EVADE, _do_evade),
		ACTION_THROW: BehaviorTree.action(ACTION_THROW, _do_throw),
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


## 躲雷分（M12）。96px 内存在引信 ≤ 1.0s 的雷（含飞行途中的）就给满。
## 雷只进 grenades 组，鸭子按 fuse_remaining 认它，不靠 class_name。
func score_evade() -> float:
	if soldier == null:
		return 0.0
	for grenade in soldier.get_tree().get_nodes_in_group(&"grenades"):
		if not grenade.has_method("fuse_remaining"):
			continue
		if soldier.global_position.distance_to(grenade.global_position) > EVADE_RADIUS:
			continue
		if float(grenade.call("fuse_remaining")) > EVADE_FUSE_WINDOW:
			continue
		return EVADE_SCORE
	return 0.0


## 投掷分（M12）。四个条件缺一即 0：手里有雷；最近的敌兵在 60~200px
## （太近直接开枪或肉搏，太远扔不着）；对它**无通视**（躲起来了，
## 枪打不着才值得动用雷）；黑板上有敌情记忆（总得知道往哪扔）。
func score_throw() -> float:
	if soldier == null or int(soldier.get("grenades")) <= 0:
		return 0.0
	var enemy = _nearest_enemy(THROW_MAX_DIST)
	if enemy == null:
		return 0.0
	if soldier.global_position.distance_to(enemy.global_position) < THROW_MIN_DIST:
		return 0.0
	if _enemy_visible(enemy):
		return 0.0
	if _throw_memory().is_empty():
		return 0.0
	return THROW_SCORE


## 敌人是不是看得见（该用枪的场合）。地图或通视接口缺失时按看得见处理——
## 无从断定"躲起来了"就别把宝贵的雷扔向猜想。
func _enemy_visible(enemy) -> bool:
	if map == null or not map.has_method("has_line_of_sight"):
		return true
	return bool(map.has_line_of_sight(soldier.global_position, enemy.global_position))


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


## 躲雷（M12）：就地扑倒，并写入「趴得住」窗口。光趴是不够的——M8 的起身
## 自动化只认压制（压制 < 0.35 即站起），而雷没给兵压制，不写 prone_hold 的话
## 躲雷的人一帧内就被翻回站立（CI 首跑实测翻车）。窗口 = 最近那颗雷的剩余
## 引信 + 0.3s：雷一炸完就允许起身，prone 不会粘住不放。
func _do_evade(_ctx: Dictionary, _delta: float) -> int:
	soldier.call("stop_moving")
	soldier.set("posture", Soldier.POSTURE_PRONE)
	soldier.set("prone_hold", _nearest_grenade_fuse() + 0.3)
	return BehaviorTree.Status.SUCCESS


## 够得着躲（EVADE 半径内、引信进窗）的雷里剩余引信最长的一颗；没有则 0。
## prone_hold 按它算：窗口盖住最晚炸的那颗，多颗雷时人趴到最后一炸结束。
func _nearest_grenade_fuse() -> float:
	if soldier == null:
		return 0.0
	var best: float = 0.0
	for grenade in soldier.get_tree().get_nodes_in_group(&"grenades"):
		if not grenade.has_method("fuse_remaining"):
			continue
		if soldier.global_position.distance_to(grenade.global_position) > EVADE_RADIUS:
			continue
		var fuse: float = float(grenade.call("fuse_remaining"))
		if fuse > EVADE_FUSE_WINDOW:
			continue
		best = maxf(best, fuse)
	return best


## 投掷（M12）：把雷扔向黑板记忆里敌人最后出现的位置。
## 弹匣与雷互不相账——这一下不耗一发子弹（M12 验收里专门有这条）。
func _do_throw(_ctx: Dictionary, _delta: float) -> int:
	var memory: Dictionary = _throw_memory()
	if memory.is_empty():
		return BehaviorTree.Status.FAILURE
	var count: int = int(soldier.get("grenades"))
	if count <= 0:
		return BehaviorTree.Status.FAILURE
	soldier.set("grenades", count - 1)
	var grenade = GRENADE_SCENE.instantiate()
	# 挂到士兵所在的父节点：跟士兵同处一张地图，随地图一起清理。
	soldier.get_parent().add_child(grenade)
	grenade.call("throw_grenade", soldier.global_position, memory["pos"], soldier)
	return BehaviorTree.Status.SUCCESS


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


## 本队黑板「最值得去查的记忆」的位置；没有 Game、黑板空着或记忆里
## 没有坐标都返回空字典——防御性地不投，总比对着空气扔雷好。
func _throw_memory() -> Dictionary:
	if soldier == null:
		return {}
	var game = soldier.get_node_or_null("/root/Game")
	if game == null or not game.has_method("blackboard"):
		return {}
	var my_team: int = int(soldier.get("team"))
	var board = game.call("blackboard", my_team)
	if board == null or not board.has_method("best_memory"):
		return {}
	var memory: Dictionary = board.call("best_memory", my_team)
	if memory.is_empty() or not memory.has("pos"):
		return {}
	return memory
