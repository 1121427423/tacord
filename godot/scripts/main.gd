extends Node3D
## M0 的表现层：400 个 MultiMesh 方块跟着 sim 走。
##
## **边界（A6）**：这里没有规则逻辑，只有"把 sim 的位置搬到渲染"。
## 规则全在 Rust 侧（sim_core），改行为请改那里，不要在这里打补丁。
##
## 四条"为了在浏览器里活下来"的设计（Web 版没有控制台可看，出了错就是一片黑）：
##
## 1. SimRoot **运行时**用 ClassDB 实例化，不写进 .tscn。
##    之前写进 .tscn 的后果：扩展一旦没加载（侧模块没起来），整个场景加载失败，
##    屏幕上什么都不剩，连一句"为什么"都没有。
## 2. HUD 第一个建、每一步都往屏幕上写字：出任何问题都能在画面上看到原因。
## 3. 方块用 unlit 材质 + 环境光 + 地面：缺光源不会表现成"黑屏没画面"。
## 4. 相机用 look_at 对准世界中心，**不要手算欧拉角**。
##    之前是 Rx(+45°) 放在 (0,40,40)：视线方向 (0,+0.707,-0.707) —— 朝天、背对世界，
##    世界中心在相机平面上且远在视锥下方，于是"引擎加载完成但没有游戏画面"。

const CELL_M := 0.5  # 与 sim 的 CELL_MM = 500 对应

@export var auto_advance := true
@export var cube_size := Vector3(0.5, 0.5, 0.5)

@onready var _camera: Camera3D = $Camera3D

var sim: Object = null
var _mm: MultiMeshInstance3D
var _hud: Label
var _status := ""


func _ready() -> void:
	_build_hud()          # 1. 先有屏幕上的字
	_build_environment()  # 2. 再有能看见的背景 / 光 / 地面
	_setup_sim()          # 3. 再接 sim（失败也要在屏幕上说清楚）
	if sim != null:
		_place_camera()
		_build_ground()
		_build_cubes()
	_sync()


func _setup_sim() -> void:
	if not ClassDB.class_exists("SimRoot"):
		_status = "扩展没加载：SimRoot 未注册（侧模块 tacord_gdext.wasm 没起来）"
		_update_hud()
		push_error("[tacord] " + _status)
		return
	sim = ClassDB.instantiate("SimRoot")
	add_child(sim)
	sim.set_auto_advance(auto_advance)
	print("[tacord] units=", sim.unit_count(), " segments=", sim.segment_count(),
			" dim_cells=", sim.dim_cells(),
			" checksum=0x", String.num_uint64(sim.world_checksum(), 16))


func _place_camera() -> void:
	var half := float(sim.dim_cells()) * CELL_M * 0.5
	var center := Vector3(half, 0.0, half)
	_camera.position = center + Vector3(0.0, half * 1.6, half * 2.2)
	_camera.look_at(center, Vector3.UP)
	_camera.far = 500.0


func _build_cubes() -> void:
	var box := BoxMesh.new()
	box.size = cube_size
	var mat := StandardMaterial3D.new()
	# unlit：有光没光都看得见，避免"没配光源"表现成黑屏
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.30, 0.85, 1.0)
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = sim.unit_count()
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = mm
	add_child(_mm)


func _build_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.06, 0.08, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.50, 0.60)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)

	# 这里**故意不建 DirectionalLight3D**：方块和地面都是 unlit（unshaded）材质，
	# 有没有光都看得见 —— 少一个"光源没配好就黑屏"的失败模式。
	# 另外 4.7 的 Light3D 已经没有 `energy` 属性了（改成物理单位 Light3D.PARAM_INTENSITY /
	# light_intensity），照 4.3 的教程写 `light.energy = 1.2` 会报
	# "Invalid assignment of property or key 'energy'"。M1 真要做打光时再处理。


func _build_ground() -> void:
	var half := float(sim.dim_cells()) * CELL_M
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(half, half)
	g.mesh = pm
	g.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	g.position = Vector3(half * 0.5, -0.02, half * 0.5)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.17, 0.19, 0.24)
	g.material_override = m
	add_child(g)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	# 顶层 Control 不会被自动撑开，不给 size 就整块被裁掉（浏览器里表现为"什么都没有"）
	_hud.size = Vector2(720, 200)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_hud.text = "tacord · 启动中…"
	layer.add_child(_hud)
	add_child(layer)


func _process(delta: float) -> void:
	if sim != null and auto_advance:
		sim.advance(delta)
	_sync()


func _sync() -> void:
	if _mm != null and sim != null:
		var t := Transform3D()
		for i in range(_mm.multimesh.instance_count):
			t.origin = sim.unit_position(i)
			_mm.multimesh.set_instance_transform(i, t)
	_update_hud()


func _update_hud() -> void:
	if _hud == null:
		return
	if sim == null:
		_hud.text = "tacord\n!! " + _status
		return
	# 注意：sim 的校验和是 u64，Godot 的整数是 i64 ⇒ 必须 num_uint64，否则出现负号
	_hud.text = "tacord Web\n tick=%d  units=%d  %.0f fps\n world=0x%s\n pos=0x%s" % [
		sim.tick_count(),
		sim.unit_count(),
		Engine.get_frames_per_second(),
		String.num_uint64(sim.world_checksum(), 16).to_upper(),
		String.num_uint64(sim.unit_position_checksum(), 16).to_upper(),
	]


## 给 headless 冒烟用的一行状态（CI 里看不到画面，只能读这个）
func debug_state() -> String:
	if sim == null:
		return "NO-SIM: " + _status
	return "tick=%d units=%d cubes=%d pos=0x%s" % [
		sim.tick_count(),
		sim.unit_count(),
		0 if _mm == null else _mm.multimesh.instance_count,
		String.num_uint64(sim.unit_position_checksum(), 16).to_upper(),
	]
