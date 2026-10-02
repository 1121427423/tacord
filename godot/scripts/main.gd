extends Node3D
## M1-A 的表现层：一座程序化生成的城 + 400 个士兵，挨打时自己找掩体。
##
## **边界（A6）**：这里没有规则逻辑，只有"把 sim 的状态搬到渲染"。
## 规则（什么时候该找掩体、哪个槽更好、够不够藏住）全在 Rust 侧
## （`sim_core::cover` + `gdext` 的 SimRoot），改行为请改那里，不要在这里打补丁。
##
## 四条"为了在浏览器里活下来"的设计（Web 版没有控制台可看，出了错就是一片黑）：
##
## 1. SimRoot **运行时**用 ClassDB 实例化，不写进 .tscn。
##    之前写进 .tscn 的后果：扩展一旦没加载（侧模块没起来），整个场景加载失败，
##    屏幕上什么都不剩，连一句"为什么"都没有。
## 2. HUD 第一个建、每一步都往屏幕上写字：出任何问题都能在画面上看到原因。
## 3. 士兵方块用 unlit 材质（有光没光都看得见）；墙按高度调明度，
##    即使打光没生效也还能靠明暗分出楼和地面 —— 少一个"黑屏"的失败模式。
## 4. 相机用 look_at 对准世界中心，**不要手算欧拉角**。
##    之前是 Rx(+45°) 放在 (0,40,40)：视线方向 (0,+0.707,-0.707) —— 朝天、背对世界，
##    世界中心在相机平面上且远在视锥下方，于是"引擎加载完成但没有游戏画面"。
##
## 颜色约定（一眼看懂在发生什么）：
##   **队 = 色系**：红队偏暖（橙红/黄），蓝队偏冷（青/绿）
##   **状态 = 明暗**：站着巡逻最亮、冲掩体次之、钻进掩体最暗、倒地接近黑
## 之所以让队占色系：交战之后最先要分辨的是"谁在打谁"，
## 状态靠姿态高度（站/蹲/趴）也能看出来，颜色重复一层不亏。

const CELL_M := 0.5  # 与 sim 的 CELL_MM = 500 对应

@export var auto_advance := true
@export var cube_width := 0.6

# 姿态高度（米）—— 与 sim 的 PostureCode 一一对应（站/蹲/趴/爬/探身/探头）
const H_STAND := 1.35
const H_CROUCH := 0.85
const H_PRONE := 0.40
const H_CRAWL := 0.30
const H_PEEK := 1.15
const H_PEEKOVER := 1.40

# 姿态高度表（按 sim_core::engage::PostureCode 的编码：0..5）
const POSTURE_H := [H_STAND, H_CROUCH, H_PRONE, H_CRAWL, H_PEEK, H_PEEKOVER]

# 红队（team 0）：巡逻橙 / 冲锋黄 / 藏起来暗红 / 倒地近黑褐
const R_PATROL := Color(1.00, 0.62, 0.30)
const R_RUSH := Color(1.00, 0.88, 0.35)
const R_HIDDEN := Color(0.78, 0.35, 0.22)
const R_DOWN := Color(0.26, 0.17, 0.15)
# 蓝队（team 1）：巡逻青 / 冲锋亮绿 / 藏起来深蓝 / 倒地近黑蓝
const B_PATROL := Color(0.30, 0.85, 1.00)
const B_RUSH := Color(0.55, 1.00, 0.55)
const B_HIDDEN := Color(0.20, 0.45, 0.88)
const B_DOWN := Color(0.15, 0.18, 0.26)

const C_TRACER := Color(1.00, 0.92, 0.55)   # 曳光弹：暖黄，一眼就能从灰城里跳出来
const TRACER_MAX := 1024                    # 渲染上限（sim 那边是 4096，画面上 1024 足够）

@onready var _camera: Camera3D = $Camera3D

var sim: Object = null
var _mm: MultiMeshInstance3D      # 士兵
var _walls: MultiMeshInstance3D   # 楼 / 墙 / 残骸
var _tracers: MultiMeshInstance3D  # 曳光弹（每发子弹这一 tick 飞过的线段）
var _hud: Label
var _status := ""
var _seed := 1


func _ready() -> void:
	_build_hud()          # 1. 先有屏幕上的字
	_build_environment()  # 2. 再有能看见的背景 / 光 / 地面
	_setup_sim()          # 3. 再接 sim（失败也要在屏幕上说清楚）
	if sim != null:
		_place_camera()
		_build_ground()
		_build_walls()
		_build_cubes()
		_build_tracers()
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
			" cover_slots=", sim.cover_slot_count(),
			" checksum=0x", String.num_uint64(sim.world_checksum(), 16))


func _place_camera() -> void:
	var half := float(sim.dim_cells()) * CELL_M * 0.5
	var center := Vector3(half, 0.0, half)
	# 俯视 3/4 视角。之前是 center + (0, half*1.6, half*2.2)，离城 43 m ——
	# 32 m 的城只占画面 8%（浏览器截图里 91% 是黑的），看着像"没画面"。
	# 现在按"把整座城塞进画面"反推：垂直 FOV 45°、16:9 ⇒ 水平视野 ≈ 72°，
	# 可见宽度 ≈ 2·d·tan(36°)；要让 32 m 的城占到七成，d ≈ 半幅 × 2.1。
	_camera.fov = 45.0
	var d := half * 2.1
	_camera.position = center + Vector3(0.0, d * 0.62, d * 0.78)   # ≈ 38° 俯角
	_camera.look_at(center, Vector3.UP)
	_camera.far = 500.0


func _build_cubes() -> void:
	# unlit：有光没光都看得见，士兵是画面里最该抢眼的东西
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	# 光开 use_colors 不够：材质不读顶点色的话，instance color 会被丢掉，
	# 结果是 400 个士兵全画成纯白（截图里那 10% 的纯白就是它们，不是墙）
	mat.vertex_color_use_as_albedo = true
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true   # 每个士兵按状态上色（不开这个 set_instance_color 是空操作）
	mm.mesh = box
	# **必须**给 custom_aabb：士兵每帧都被改写 transform，而 MultiMesh 的包围盒
	# 默认只在分配时算一次 —— 不写死一个覆盖全图的盒子，整批实例会被视锥裁掉，
	# 表现是"城在、人一个都看不见"，而且 headless 里完全看不出来。
	var span := float(sim.dim_cells()) * CELL_M
	mm.custom_aabb = AABB(Vector3(-8.0, -8.0, -8.0), Vector3(span + 16.0, 32.0, span + 16.0))
	mm.instance_count = sim.unit_count()
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = mm
	add_child(_mm)


## 城里的楼 / 院墙 / 残骸：sim 里每一段非地面体素画成一个盒子。
##
## 盒子数据由 sim 一次性给全（`wall_boxes`，每 6 个 float 一个：中心 xyz + 尺寸 xyz），
## 这里不做任何"哪些该画"的判断 —— 那属于规则。
func _build_tracers() -> void:
	# 子弹是**实体**：sim 每 tick 给的是"这一 tick 飞过的线段"，
	# 画成一个点会在墙里闪现（一 tick 就走 30 m），画成线段才是"从这儿飞到那儿"。
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = C_TRACER
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	# 与士兵同样的坑：包围盒只在分配时算一次，必须写死一个覆盖全图的
	var span := float(sim.dim_cells()) * CELL_M
	mm.custom_aabb = AABB(Vector3(-8.0, -8.0, -8.0), Vector3(span + 16.0, 32.0, span + 16.0))
	mm.instance_count = TRACER_MAX
	mm.visible_instance_count = 0
	_tracers = MultiMeshInstance3D.new()
	_tracers.multimesh = mm
	add_child(_tracers)


func _build_walls() -> void:
	var arr: PackedFloat32Array = sim.wall_boxes()
	var n: int = arr.size() / 6
	if n == 0:
		push_warning("[tacord] sim 没给任何墙段")
		return
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	# 别再往上调：0.66 的 albedo 乘上高度提亮（最高 0.92）再乘光照，
	# 顶面会直接烧成纯白 —— 截图里和 unlit 的士兵混成一片，谁是谁都分不出来
	mat.albedo_color = Color(0.50, 0.48, 0.44)
	mat.roughness = 0.95
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true   # 按高度调明度：打光万一没生效，还能靠明暗分出楼和地面
	mm.mesh = box
	mm.instance_count = n
	_walls = MultiMeshInstance3D.new()
	_walls.multimesh = mm
	add_child(_walls)
	for i in range(n):
		var t := Transform3D()
		var sx: float = arr[i * 6 + 3]
		var sy: float = arr[i * 6 + 4]
		var sz: float = arr[i * 6 + 5]
		t.origin = Vector3(arr[i * 6 + 0], arr[i * 6 + 1], arr[i * 6 + 2])
		t.basis.x = Vector3(sx, 0.0, 0.0)
		t.basis.y = Vector3(0.0, sy, 0.0)
		t.basis.z = Vector3(0.0, 0.0, sz)
		mm.set_instance_transform(i, t)
		# 越高越亮：0.5 m 的瓦砾最暗，7 m 的楼最亮
		var k: float = clampf(sy / 6.0, 0.0, 1.0)
		var v: float = 0.62 + 0.30 * k
		mm.set_instance_color(i, Color(v, v * 0.97, v * 0.92))


func _build_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.06, 0.08, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.50, 0.60)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)

	# 一盏平行光：给墙体明暗，不然整座城是一张平面图，看不出高低。
	#
	# 属性名踩过一次坑：物理光照单位关着的时候（默认）Light3D 上是
	# `light_energy`，`light_intensity_lux` / `light_intensity_lumens` 只在
	# 打开 `use_physical_light_units` 之后才存在 —— 写 `light_intensity = 1.2`
	# 会报 "Invalid assignment of property or key"。
	# 不开阴影：400 人 + 上千个盒子，Web 上为这点观感不值。
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.0
	sun.rotation_degrees = Vector3(-45.0, 35.0, 0.0)
	add_child(sun)


func _build_ground() -> void:
	var half := float(sim.dim_cells()) * CELL_M
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(half, half)
	g.mesh = pm
	g.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	g.position = Vector3(half * 0.5, -0.02, half * 0.5)
	var m := StandardMaterial3D.new()
	# 别调太暗：0.16 的 albedo 经环境光照之后几乎是纯黑，和城外的背景色分不开
	m.albedo_color = Color(0.26, 0.27, 0.30)
	m.roughness = 1.0
	g.material_override = m
	add_child(g)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	# 顶层 Control 不会被自动撑开，不给 size 就整块被裁掉（浏览器里表现为"什么都没有"）
	_hud.size = Vector2(760, 260)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_hud.text = "tacord · 启动中…"
	layer.add_child(_hud)
	add_child(layer)


var _frames := 0


func _process(delta: float) -> void:
	if sim != null and auto_advance:
		sim.advance(delta)
	_sync()
	# 每 2 秒往控制台打一行实况。为什么需要：headless 不渲染，浏览器里也看不到
	# Actions 的 stdout —— 出了"画面看着不对"这种事，只能靠这一行判断
	# 到底是 sim 没跑、跑得慢、还是渲染的问题（fps 与 tick 分开看就知道）。
	_frames += 1
	if _frames % 60 == 0 and sim != null:
		# 三个数分开打，才能定位"画面看着不动"到底卡在哪一环：
		#   poscs 变 = sim 里的人真的在走
		#   mm0   变 = MultiMesh 的实例数据也被改写了
		#   两个都变而画面不动 = 渲染/上传那一段的问题，不是模拟的问题
		var npatrol := 0
		var nrush := 0
		var nhidden := 0
		for i in range(sim.unit_count()):
			match sim.unit_state(i):
				1:
					nrush += 1
				2:
					nhidden += 1
				_:
					npatrol += 1
		var mm0 := Vector3.ZERO
		if _mm != null:
			mm0 = _mm.multimesh.get_instance_transform(0).origin
		print("[tacord] 实况 frame=", _frames, " tick=", sim.tick_count(), " fps=", snappedf(Engine.get_frames_per_second(), 0.1), " in_cover=", sim.in_cover_count(), "/", sim.unit_count(), " 状态 巡逻/冲/藏=", npatrol, "/", nrush, "/", nhidden, " poscs=0x", String.num_uint64(sim.unit_position_checksum(), 16), " pos0=", str(sim.unit_position(0)), " mm0=", str(mm0))


func _sync() -> void:
	if _mm != null and sim != null:
		var t := Transform3D()
		var p: Vector3
		var h: float
		for i in range(_mm.multimesh.instance_count):
			var st: int = sim.unit_state(i)
			var po: int = sim.unit_posture(i)
			h = POSTURE_H[po] if po >= 0 and po < POSTURE_H.size() else H_STAND
			p = sim.unit_position(i)
			t.origin = Vector3(p.x, p.y + h * 0.5, p.z)
			t.basis.x = Vector3(cube_width, 0.0, 0.0)
			t.basis.y = Vector3(0.0, h, 0.0)
			t.basis.z = Vector3(0.0, 0.0, cube_width)
			_mm.multimesh.set_instance_transform(i, t)
			_mm.multimesh.set_instance_color(i, _color_of(sim.unit_team(i), st))
	_sync_tracers()
	_update_hud()


## 队 = 色系，状态 = 明暗（见文件头的颜色约定）
func _color_of(team: int, state: int) -> Color:
	if team == 0:
		match state:
			1:
				return R_RUSH
			2:
				return R_HIDDEN
			3:
				return R_DOWN
			_:
				return R_PATROL
	match state:
		1:
			return B_RUSH
		2:
			return B_HIDDEN
		3:
			return B_DOWN
		_:
			return B_PATROL


## 每发子弹画成一根细长的盒子：从这一 tick 的起点指到终点。
func _sync_tracers() -> void:
	if _tracers == null or sim == null:
		return
	var mm := _tracers.multimesh
	var n: int = mini(sim.projectile_count(), TRACER_MAX)
	var t := Transform3D()
	for i in range(n):
		var seg: PackedFloat32Array = sim.projectile_segment(i)
		if seg.size() < 6:
			continue
		var a := Vector3(seg[0], seg[1], seg[2])
		var b := Vector3(seg[3], seg[4], seg[5])
		var d := b - a
		var length := d.length()
		if length < 0.001:
			length = 0.05
		var dir := d / length
		# 手动搭基：Basis 的 z 轴对齐飞行方向，盒子就"躺"在弹道上
		var up := Vector3.UP
		if absf(dir.dot(up)) > 0.99:
			up = Vector3.RIGHT
		var z_axis := dir
		var x_axis := up.cross(z_axis).normalized()
		var y_axis := z_axis.cross(x_axis)
		t.basis = Basis(x_axis, y_axis, z_axis).scaled(Vector3(0.04, 0.04, length))
		t.origin = (a + b) * 0.5
		mm.set_instance_transform(i, t)
	# 只有前 n 个实例可见（剩下的别留在画面上）
	mm.visible_instance_count = n


func _update_hud() -> void:
	if _hud == null:
		return
	if sim == null:
		_hud.text = "tacord\n!! " + _status
		return
	# 注意：sim 的校验和是 u64，Godot 的整数是 i64 ⇒ 必须 num_uint64，否则出现负号
	var hits: int = sim.hit_count()
	var shots: int = sim.shot_count()
	var acc := (hits * 100 / shots) if shots > 0 else 0
	_hud.text = "tacord Web · M1-B 交战\n tick=%d  %.0f fps\n 红队 %d 人   蓝队 %d 人   倒地 %d\n 开火 %d   命中 %d（%d%%）   近失 %d\n 在掩体 %d   被压制 %d   打光弹药 %d\n 曳光弹 %d\n world=0x%s\n cover=0x%s\n F 重开   R 换地形   空格 暂停" % [
		sim.tick_count(),
		Engine.get_frames_per_second(),
		sim.team_alive(0),
		sim.team_alive(1),
		sim.downed_count(),
		shots,
		hits,
		acc,
		sim.near_miss_count(),
		sim.in_cover_count(),
		sim.pinned_count(),
		sim.dry_count(),
		sim.projectile_count(),
		String.num_uint64(sim.world_checksum(), 16).to_upper(),
		String.num_uint64(sim.cover_checksum(), 16).to_upper(),
	]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F:
			# M1-B 起没有"手动开一枪"这回事了（两边自己在打），
			# F 改成重开一局：看伤亡/弹药曲线比看单发有用
			if sim != null:
				sim.reset(sim.dim_cells(), sim.unit_count(), _seed)
				print("[tacord] 重开一局 seed=", _seed)
		KEY_R:
			_regenerate()
		KEY_SPACE:
			auto_advance = not auto_advance
			if sim != null:
				sim.set_auto_advance(auto_advance)
		_:
			pass


## 换一张地图（同一个 seed 序列的下一个）：墙要整个重建，士兵数量可能变。
func _regenerate() -> void:
	if sim == null:
		return
	_seed += 1
	sim.reset(sim.dim_cells(), sim.unit_count(), _seed)
	if _walls != null:
		remove_child(_walls)
		_walls.queue_free()
		_walls = null
	_build_walls()
	if _mm != null:
		_mm.multimesh.instance_count = sim.unit_count()
	print("[tacord] 换图 seed=", _seed, " units=", sim.unit_count(),
			" slots=", sim.cover_slot_count(),
			" world=0x", String.num_uint64(sim.world_checksum(), 16))


## 给 headless 冒烟用的一行状态（CI 里看不到画面，只能读这个）
func debug_state() -> String:
	if sim == null:
		return "NO-SIM: " + _status
	return "tick=%d units=%d cubes=%d walls=%d slots=%d in_cover=%d shots=%d pos=0x%s" % [
		sim.tick_count(),
		sim.unit_count(),
		0 if _mm == null else _mm.multimesh.instance_count,
		0 if _walls == null else _walls.multimesh.instance_count,
		sim.cover_slot_count(),
		sim.in_cover_count(),
		sim.shot_count(),
		String.num_uint64(sim.unit_position_checksum(), 16).to_upper(),
	]
