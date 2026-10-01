# 诊断用：把 Godot 自己看到的 .gdextension 内容、feature 判定、res:// 目录列出来。
#
# 背景：.gdextension 的 [libraries] 是按「标签全是 feature 且标签数最多者胜出」挑库的
# （core/extension/gdextension_library_loader.cpp: find_extension_library）。
# 一旦没挑中，只会报一句 "No GDExtension library found for current OS and architecture"，
# 看不出是标签不命中、还是段没解析到 —— 这个脚本就是把中间状态全打出来。
extends SceneTree

func _init() -> void:
	print("[diag] os=", OS.get_name(), " arch=", Engine.get_architecture_name())
	for f in ["linux", "macos", "x86_64", "arm64", "web", "wasm32", "debug", "release"]:
		print("[diag] feature ", f, "=", OS.has_feature(f))

	var cf := ConfigFile.new()
	var err := cf.load("res://tacord.gdextension")
	print("[diag] config load err=", err)
	print("[diag] sections=", cf.get_sections())
	if cf.has_section("libraries"):
		for k in cf.get_section_keys("libraries"):
			var v := str(cf.get_value("libraries", k))
			var tags: PackedStringArray = k.split(".")
			var met := true
			for t in tags:
				if not OS.has_feature(t):
					met = false
			print("[diag] key='", k, "' tags=", tags, " 全部命中=", met,
				" value='", v, "' 文件存在=", FileAccess.file_exists(v))
	else:
		print("[diag] ！！没有 [libraries] 段")

	var d := DirAccess.open("res://")
	if d:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			print("[diag] res:// 顶层: ", f)
			f = d.get_next()
	print("[diag] res://bin 列表: ", DirAccess.get_files_at("res://bin"))
	quit()
