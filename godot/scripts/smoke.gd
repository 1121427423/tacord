extends SceneTree
## CI 冒烟（headless）：扩展能加载 → 场景能实例化 → 能跑固定 tick → 校验和一致。
##
## 用法：godot --headless --path godot --script res://scripts/smoke.gd
## 退出码 0 = 通过；1 = 失败。

const TICKS := 300

func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var sim: SimRoot = scene.get_node("SimRoot")
	sim.set_auto_advance(false)   # 关掉帧驱动：校验和必须只由 tick 数决定

	var cs0 := sim.world_checksum()
	for _i in range(TICKS):
		sim.step()
	var pos0 := sim.unit_position(0)

	# 校验和是 u64（Godot 整数是 i64）⇒ 用 num_uint64 打印；这个数字用于跨平台逐位比对
	print("[smoke] units=", sim.unit_count(),
			" dim=", sim.dim_cells(),
			" tick=", sim.tick_count(),
			" world_checksum=0x", String.num_uint64(sim.world_checksum(), 16),
			" pos_checksum=0x", String.num_uint64(sim.unit_position_checksum(), 16),
			" pos0=", str(pos0))

	var ok := true
	ok = ok and sim.unit_count() == 400
	ok = ok and sim.tick_count() == TICKS
	ok = ok and sim.world_checksum() == cs0        # 这个演示里世界不变动
	ok = ok and sim.world_checksum() != 0
	ok = ok and pos0.length() > 0.0                # 单位确实动了

	print("[smoke] ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
