# test_runner.gd
# Asset Forge 独立项目 minimal 测试运行器（headless）。
# 用法：godot --headless --path <项目根> --script res://tests/test_runner.gd
# 注册 4 个 suite：AssetFactory / CustomMeshes / ScenePlacer / CommandServer。
extends SceneTree

var _passed: int = 0
var _failed: int = 0


var _ran: bool = false

func _initialize() -> void:
	# 测试延迟到首帧 _process 跑，使 SceneTree.root（Window）已 attach、子 Node3D is_inside_tree=true。
	# 否则 to_global / get_global_transform 在 _initialize 阶段报 "!is_inside_tree"。
	pass


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_suite("AssetFactory", preload("res://tests/test_asset_factory.gd").new())
	_run_suite("CustomMeshes", preload("res://tests/test_custom_meshes.gd").new())
	_run_suite("PathGenerator", preload("res://tests/test_path_generator.gd").new())
	_run_suite("ScenePlacer", preload("res://tests/test_scene_placer.gd").new())
	_run_suite("CommandServer", preload("res://tests/test_command_server.gd").new())
	print("\n=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
	return true  # 主循环继续（quit 会退出，返回值无实际意义）


func _run_suite(suite_name: String, suite: RefCounted) -> void:
	print("\n--- Suite: %s ---" % suite_name)
	suite.run(self)


# runner API：测试文件通过 runner.check / runner.check_approx / runner.root 调用。
# runner.root 来自 SceneTree.root（Viewport），供需要入树的测试用（如 test_scene_placer）。


func check(cond: bool, message: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s: %s" % ["PASS" if cond else "FAIL", message])


func check_approx(actual: float, expected: float, eps: float, message: String) -> void:
	check(absf(actual - expected) <= eps, message)
