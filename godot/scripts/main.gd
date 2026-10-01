extends Node3D
## M0 的表现层：400 个 MultiMesh 方块跟着 sim 走。
##
## **边界（A6）**：这里没有规则逻辑，只有"把 sim 的位置搬到渲染"。
## 规则全在 Rust 侧（sim_core），改行为请改那里，不要在这里打补丁。

@export var auto_advance := true
@export var cube_size := Vector3(0.5, 0.5, 0.5)

@onready var sim: SimRoot = $SimRoot

var _mm: MultiMeshInstance3D


func _ready() -> void:
	sim.set_auto_advance(auto_advance)
	var box := BoxMesh.new()
	box.size = cube_size
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = sim.unit_count()
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = mm
	add_child(_mm)
	# 注意：sim 的校验和是 u64，Godot 的整数是 i64 ⇒ 必须用 num_uint64 打印，否则出现负号
	print("[tacord] units=", sim.unit_count(), " segments=", sim.segment_count(),
			" checksum=0x", String.num_uint64(sim.world_checksum(), 16))
	_sync()


func _process(delta: float) -> void:
	if auto_advance:
		sim.advance(delta)
	_sync()


func _sync() -> void:
	var t := Transform3D()
	for i in range(_mm.multimesh.instance_count):
		t.origin = sim.unit_position(i)
		_mm.multimesh.set_instance_transform(i, t)
