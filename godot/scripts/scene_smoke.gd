extends SceneTree
## headless 冒烟：主场景能不能加载、能不能连续跑 30 帧。
##
## 为什么需要：Web 版没有控制台，"场景加载失败"在浏览器里只表现为一片黑。
## 这条冒烟把"脚本错误 / 类找不到 / 帧循环没跑起来"挡在 CI 里。
##
## 它挡不住什么：headless **不渲染**，所以"没光源导致的黑屏""相机朝向错了"
## 这类问题只能靠真看画面（或把判断写成断言）。

const WANT_FRAMES := 30

var _frames := 0
var _scene: Node


func _initialize() -> void:
	print("[scene] 加载 res://scenes/main.tscn")
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)
	print("[scene] 已实例化: ", _scene.name)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= WANT_FRAMES:
		if _scene.has_method("debug_state"):
			print("[scene] 状态: ", _scene.debug_state())
		quit()
		return true
	return false


func _finalize() -> void:
	print("[scene] DONE frames=", _frames)
