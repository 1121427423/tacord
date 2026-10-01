extends Node3D
## M0 的表现层：400 个 MultiMesh 方块跟着 sim 走。
##
## **边界（A6）**：这里没有规则逻辑，只有"把 sim 的位置搬到渲染"。
## 规则全在 Rust 侧（sim_core），改行为请改那里，不要在这里打补丁。

@export var auto_advance := true
@export var cube_size := Vector3(0.5, 0.5, 0.5)

@onready var sim: SimRoot = $SimRoot

var _mm: MultiMeshInstance3D
var _hud: Label


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
	_build_hud()
	_sync()


func _process(delta: float) -> void:
	if auto_advance:
		sim.advance(delta)
	_sync()


## 屏幕左上角的 HUD：Web 版本没有控制台可看，这几个数字是"它真的在跑"的唯一证据
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.text = "tacord · 启动中"
	layer.add_child(_hud)
	add_child(layer)


func _update_hud() -> void:
	if _hud == null:
		return
	_hud.text = "tacord Web\n tick=%d  units=%d  %.0f fps\n world=0x%s\n pos=0x%s" % [
		sim.tick_count(),
		sim.unit_count(),
		Engine.get_frames_per_second(),
		String.num_uint64(sim.world_checksum(), 16).to_upper(),
		String.num_uint64(sim.unit_position_checksum(), 16).to_upper(),
	]


func _sync() -> void:
	var t := Transform3D()
	for i in range(_mm.multimesh.instance_count):
		t.origin = sim.unit_position(i)
		_mm.multimesh.set_instance_transform(i, t)
	_update_hud()
