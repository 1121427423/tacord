# 诊断用：把 Godot 自己认定的 OS / 架构 / feature 打印出来。
#
# 为什么需要它：.gdextension 的 [libraries] 是按 "标签全是 feature 且标签最多者胜出"
# 来挑库的（core/extension/gdextension_library_loader.cpp: find_extension_library）。
# 一旦某个标签被判成 false，就会报 "No GDExtension library found for current OS
# and architecture (...)"，而日志里看不出到底是哪个标签没命中。
extends SceneTree

var _names := ["linux", "macos", "windows", "web", "android",
	"x86_64", "x86_32", "arm64", "arm32", "wasm32",
	"debug", "release", "editor", "template"]

func _init() -> void:
	print("[features] os=", OS.get_name(), " arch=", Engine.get_architecture_name(),
		" debug_build=", OS.is_debug_build())
	for f in _names:
		print("[features] ", f, "=", OS.has_feature(f))
	quit()
