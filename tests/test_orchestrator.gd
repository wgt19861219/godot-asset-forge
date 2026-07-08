extends RefCounted
## orchestrator 编排层测试（claim 5，22 case）。覆盖 handle_command 三分支 + _handle_generate_path 校验链 + _place_one。
## MockServer inner class 记 send_result 调用；_get_root/_mark_unsaved/_dock_add 注入 Callable。
## 沿用 test_scene_placer 范式：Node3D root 入 runner.root 树使 ScenePlacer.place 的 NodePath 解析生效。


# MockServer：记录 send_result 调用（不调真实 ws send）。无 class_name（仅本文件用，避跨文件解析疑虑）。
class MockServer:
	extends RefCounted
	var sent: Array = []
	func send_result(req_id, ok, fields, ws) -> void:
		sent.append({"req_id": req_id, "ok": ok, "fields": fields})


# 常规 case 的 Orchestrator 工厂：_get_root 恒返 root、_mark_unsaved 捕获到 marked_arr[0]、_dock_add 捕获到 added_arr。
# P1-5 竞态 case（C 组）的 _get_root 是双值的，不 用此 helper，单独构造。
# 注：返回类型用 RefCounted 而非 Orchestrator —— headless 下 test 脚本用 `-> Orchestrator` 触发
# "Could not find type Orchestrator" class_name 跨文件时序坑（Orchestrator.new 调用本身不受影响）。
func _make_orch(
	mock: MockServer, stack: Array, root: Node, marked_arr: Array, added_arr: Array
) -> RefCounted:
	return Orchestrator.new(
		mock,
		stack,
		func() -> Node: return root,
		func() -> void: marked_arr[0] = true,
		func(n: String, p: String) -> void: added_arr.append({"name": n, "path": p}),
	)


func run(runner) -> void:
	var root := Node3D.new()
	root.name = "Root"
	runner.root.add_child(root)
	var ws := WebSocketPeer.new()  # 未连接，纯透传（Orchestrator 不调 ws 方法，只转给 send_result）

	# === A.1 undo 成功（R7：message "freed %d" 契约）===
	# 前置：stack 先 place 1 节点（undo 才有东西弹）
	var stack_a1: Array = []
	ScenePlacer.place(root, BoxMesh.new(), null, {"name": "a1"}, stack_a1, 100)
	var mock_a1 := MockServer.new()
	var marked_a1 := [false]
	var orch_a1 := _make_orch(mock_a1, stack_a1, root, marked_a1, [])
	orch_a1.handle_command({"__req_id": "r1", "__undo": true}, -1, ws)
	runner.check(mock_a1.sent.size() == 1, "A.1 undo 发 1 条 result")
	if mock_a1.sent.size() == 1:
		runner.check(bool(mock_a1.sent[0]["ok"]), "A.1 undo success=true")
		runner.check(String(mock_a1.sent[0]["fields"].get("error", "")) == "", "A.1 undo 无 error")
		# R7：成功 message 必须为 "freed N"（selftest 6 处 msg.split()[-1] 硬依赖）
		var msg_a1 := String(mock_a1.sent[0]["fields"].get("message", ""))
		runner.check(
			msg_a1.begins_with("freed ") and msg_a1.split(" ")[-1].is_valid_int(),
			"A.1 R7：undo message='%s' 必须为 'freed N'（selftest 硬依赖，不得改文案）" % msg_a1
		)
		runner.check(msg_a1 == "freed 1", "A.1 undo freed=1（栈内 1 节点）")

	# [后续 case 在此处追加]

	# 清理 root
	runner.root.remove_child(root)
	root.free()
