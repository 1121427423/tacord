# 极简行为树节点库：Utility AI 决定“做什么”，行为树负责把行为展开成可中断的动作序列。
class_name BehaviorTree
extends RefCounted

## 节点返回值。所有节点统一用 int 返回，便于 Callable 直接回传。
enum Status { FAILURE, SUCCESS, RUNNING }

# 说明：下列节点类都直接 extends RefCounted（而不是互相继承），
# 以避免 Godot 4 中“内类继承内类”的解析边界情况；它们共享同一套鸭子接口：
#   tick(ctx: Dictionary, delta: float) -> int
#   reset() -> void


## 叶子动作：把一个 Callable 包成行为树节点。
class BTAction:
	extends RefCounted

	var node_name: StringName = &"action"
	var callable: Callable = Callable()

	func _init(p_name: StringName = &"action", p_callable: Callable = Callable()) -> void:
		node_name = p_name
		callable = p_callable

	func tick(ctx: Dictionary, delta: float) -> int:
		if not callable.is_valid():
			return BehaviorTree.Status.FAILURE
		return int(callable.call(ctx, delta))

	func reset() -> void:
		pass


## 条件守卫：谓词为真返回 SUCCESS，否则 FAILURE。
class BTCondition:
	extends RefCounted

	var node_name: StringName = &"condition"
	var predicate: Callable = Callable()

	func _init(p_name: StringName = &"condition", p_predicate: Callable = Callable()) -> void:
		node_name = p_name
		predicate = p_predicate

	func tick(_ctx: Dictionary, _delta: float) -> int:
		if not predicate.is_valid():
			return BehaviorTree.Status.FAILURE
		return BehaviorTree.Status.SUCCESS if bool(predicate.call()) else BehaviorTree.Status.FAILURE

	func reset() -> void:
		pass


## 顺序节点：依次执行子节点，遇到 RUNNING 挂起，遇到 FAILURE 立即失败并复位。
class BTSequence:
	extends RefCounted

	var node_name: StringName = &"sequence"
	var children: Array = []
	var index: int = 0

	func _init(p_name: StringName = &"sequence", p_children: Array = []) -> void:
		node_name = p_name
		children = p_children.duplicate()

	func tick(ctx: Dictionary, delta: float) -> int:
		while index < children.size():
			var status: int = int(children[index].tick(ctx, delta))
			if status == BehaviorTree.Status.RUNNING:
				return BehaviorTree.Status.RUNNING
			if status == BehaviorTree.Status.FAILURE:
				reset()
				return BehaviorTree.Status.FAILURE
			index += 1
		reset()
		return BehaviorTree.Status.SUCCESS

	func reset() -> void:
		index = 0
		for child in children:
			child.reset()


## 选择节点：依次尝试子节点，遇到 SUCCESS/RUNNING 即返回，全部失败才失败。
class BTSelector:
	extends RefCounted

	var node_name: StringName = &"selector"
	var children: Array = []
	var index: int = 0

	func _init(p_name: StringName = &"selector", p_children: Array = []) -> void:
		node_name = p_name
		children = p_children.duplicate()

	func tick(ctx: Dictionary, delta: float) -> int:
		while index < children.size():
			var status: int = int(children[index].tick(ctx, delta))
			if status == BehaviorTree.Status.RUNNING:
				return BehaviorTree.Status.RUNNING
			if status == BehaviorTree.Status.SUCCESS:
				reset()
				return BehaviorTree.Status.SUCCESS
			index += 1
		reset()
		return BehaviorTree.Status.FAILURE

	func reset() -> void:
		index = 0
		for child in children:
			child.reset()


# ---- 构造快捷方式（让上层代码读起来更像 DSL）----


static func action(p_name: StringName, callable: Callable) -> BTAction:
	return BTAction.new(p_name, callable)


static func condition(p_name: StringName, predicate: Callable) -> BTCondition:
	return BTCondition.new(p_name, predicate)


static func sequence(p_name: StringName, children: Array = []) -> BTSequence:
	return BTSequence.new(p_name, children)


static func selector(p_name: StringName, children: Array = []) -> BTSelector:
	return BTSelector.new(p_name, children)


## 复位任意节点（鸭子调用，未实现 reset 的节点会被忽略）。
static func reset_node(node) -> void:
	if node != null and node.has_method("reset"):
		node.call("reset")
