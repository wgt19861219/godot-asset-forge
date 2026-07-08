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

	# === A.2 undo nothing_to_undo（空栈 → error；P2#8：不报 freed 0，无 message）===
	var mock_a2 := MockServer.new()
	var orch_a2 := _make_orch(mock_a2, [], root, [false], [])  # 空 stack
	orch_a2.handle_command({"__req_id": "r2", "__undo": true}, -1, ws)
	runner.check(mock_a2.sent.size() == 1, "A.2 undo 发 1 条 result")
	if mock_a2.sent.size() == 1:
		runner.check(not bool(mock_a2.sent[0]["ok"]), "A.2 nothing_to_undo success=false")
		runner.check(
			String(mock_a2.sent[0]["fields"].get("error")) == "nothing_to_undo",
			"A.2 error='nothing_to_undo'"
		)
		runner.check(
			not mock_a2.sent[0]["fields"].has("message"),
			"A.2 P2#8：nothing_to_undo 不塞 message（不报 freed 0）"
		)

	# === A.3a unsupported_shape 单件（create_mesh 未知 shape 返 null，旧 :88-89）===
	var mock_a3a := MockServer.new()
	var orch_a3a := _make_orch(mock_a3a, [], root, [false], [])
	orch_a3a.handle_command({"__req_id": "r3a", "shape": "badshape"}, 1, ws)
	runner.check(mock_a3a.sent.size() == 1, "A.3a 发 1 条 result")
	if mock_a3a.sent.size() == 1:
		runner.check(not bool(mock_a3a.sent[0]["ok"]), "A.3a success=false")
		runner.check(
			String(mock_a3a.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.3a error='unsupported_shape'"
		)
		# grep 旧 plugin:92-105 message 文案（含支持列表）
		runner.check(
			String(mock_a3a.sent[0]["fields"].get("message", "")).find("未知 shape: badshape") >= 0,
			"A.3a message 含 '未知 shape: badshape'"
		)

	# === A.3b unsupported_shape path（discrete + badshape → probe_mesh null）===
	# 注：continuous 白名单会先拦非 wall/fence/ramp shape，到不了 probe_mesh null，故用 discrete
	var mock_a3b := MockServer.new()
	var orch_a3b := _make_orch(mock_a3b, [], root, [false], [])
	orch_a3b.handle_command(
		{"__req_id": "r3b", "shape": "badshape", "path": [[0, 0, 0], [3, 0, 0]], "count": 2}, 2, ws
	)
	runner.check(mock_a3b.sent.size() == 1, "A.3b 发 1 条 result")
	if mock_a3b.sent.size() == 1:
		runner.check(
			String(mock_a3b.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.3b path 分支 error='unsupported_shape'（probe_mesh null）"
		)

	# === A.4a no_active_scene 单件（_get_root 返 null；:113 message 长文案）===
	var mock_a4a := MockServer.new()
	# _get_root 返 null（不用 _make_orch，单独构造 callable）
	var orch_a4a := Orchestrator.new(
		mock_a4a, [],
		func() -> Node: return null,
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a4a.handle_command({"__req_id": "r4a", "shape": "box"}, 1, ws)
	runner.check(mock_a4a.sent.size() == 1, "A.4a 发 1 条 result")
	if mock_a4a.sent.size() == 1:
		runner.check(
			String(mock_a4a.sent[0]["fields"].get("error")) == "no_active_scene",
			"A.4a error='no_active_scene'"
		)
		# grep 旧 plugin:113 —— 单件长文案（与 :157 path 短文案不同，已实证）
		runner.check(
			String(mock_a4a.sent[0]["fields"].get("message")) == "无活动场景，请先在编辑器新建或打开场景再 generate",
			"A.4a message='无活动场景，请先在编辑器新建或打开场景再 generate'（长文案）"
		)

	# === A.4b no_active_scene path（_get_root 返 null；:157 短文案，与 A.4a 不同）===
	var mock_a4b := MockServer.new()
	var orch_a4b := Orchestrator.new(
		mock_a4b, [],
		func() -> Node: return null,
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a4b.handle_command(
		{"__req_id": "r4b", "shape": "cylinder", "path": [[0, 0, 0], [3, 0, 0]], "count": 2}, 2, ws
	)
	runner.check(mock_a4b.sent.size() == 1, "A.4b 发 1 条 result")
	if mock_a4b.sent.size() == 1:
		runner.check(
			String(mock_a4b.sent[0]["fields"].get("error")) == "no_active_scene",
			"A.4b path 分支 error='no_active_scene'"
		)
		# grep 旧 plugin:157 —— path 短文案
		runner.check(
			String(mock_a4b.sent[0]["fields"].get("message")) == "无活动场景",
			"A.4b message='无活动场景'（短文案，与 A.4a 长文案不同）"
		)

	# === A.5 path↔path_node 互斥（同时提供 → invalid_params）===
	# 注：旧「都无」分支不可达（_on_command 进 _handle_generate_path 需 has path or path_node），
	# 故只测「同时有」互斥分支。
	var mock_a5 := MockServer.new()
	var orch_a5 := _make_orch(mock_a5, [], root, [false], [])
	orch_a5.handle_command(
		{
			"__req_id": "r5", "shape": "wall", "count": 2,
			"path": [[0, 0, 0], [3, 0, 0]], "path_node": "/Root/Path0"
		},
		5, ws
	)
	runner.check(mock_a5.sent.size() == 1, "A.5 发 1 条 result")
	if mock_a5.sent.size() == 1:
		runner.check(
			String(mock_a5.sent[0]["fields"].get("error")) == "invalid_params",
			"A.5 互斥 → invalid_params"
		)
		runner.check(
			String(mock_a5.sent[0]["fields"].get("message")).find("互斥") >= 0,
			"A.5 message 含 '互斥'"
		)

	# === A.6 mode 非法（invalid_params；mode 校验在取 root 之前，不触发 _get_root）===
	var mock_a6 := MockServer.new()
	var get_root_calls_a6 := [0]
	var orch_a6 := Orchestrator.new(
		mock_a6, [],
		func() -> Node: get_root_calls_a6[0] += 1; return root,  # 计数，验证 mode 先返不取 root
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a6.handle_command(
		{"__req_id": "r6", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "mode": "bad"},
		6, ws
	)
	runner.check(mock_a6.sent.size() == 1, "A.6 发 1 条 result")
	if mock_a6.sent.size() == 1:
		runner.check(
			String(mock_a6.sent[0]["fields"].get("error")) == "invalid_params",
			"A.6 mode 非法 → invalid_params"
		)
		runner.check(
			String(mock_a6.sent[0]["fields"].get("message")).find("mode 必须") >= 0,
			"A.6 message 含 'mode 必须'"
		)
	runner.check(get_root_calls_a6[0] == 0, "A.6 mode 校验在取 root 之前（_get_root 未被调）")

	# === A.7 continuous 白名单（box 非 wall/fence/ramp → unsupported_shape）===
	var mock_a7 := MockServer.new()
	var orch_a7 := _make_orch(mock_a7, [], root, [false], [])
	orch_a7.handle_command(
		{"__req_id": "r7", "shape": "box", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "mode": "continuous"},
		7, ws
	)
	runner.check(mock_a7.sent.size() == 1, "A.7 发 1 条 result")
	if mock_a7.sent.size() == 1:
		runner.check(
			String(mock_a7.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.7 continuous box → unsupported_shape（白名单）"
		)
		# grep 旧 plugin:263-274
		runner.check(
			String(mock_a7.sent[0]["fields"].get("message")).find("continuous 模式仅支持") >= 0,
			"A.7 message 含 'continuous 模式仅支持'"
		)

	# === A.8 samples 空（spacing>total + include_endpoints=false → boundaries=[0] → 0 段）===
	var mock_a8 := MockServer.new()
	var orch_a8 := _make_orch(mock_a8, [], root, [false], [])
	orch_a8.handle_command(
		{
			"__req_id": "r8", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"spacing": 10.0, "mode": "continuous", "include_endpoints": false
		},
		8, ws
	)
	runner.check(mock_a8.sent.size() == 1, "A.8 发 1 条 result")
	if mock_a8.sent.size() == 1:
		runner.check(
			String(mock_a8.sent[0]["fields"].get("error")) == "invalid_params",
			"A.8 samples 空 → invalid_params"
		)
		runner.check(
			String(mock_a8.sent[0]["fields"].get("message")).find("采样点为 0") >= 0,
			"A.8 message 含 '采样点为 0'"
		)

	# === A.9 pre_est 超上限（spacing 路径 :215 分支）===
	# 注：spec 标 samples>BATCH_LIMIT，但 pre_est 是上界，samples 永远 ≤ pre_est，
	# samples>BATCH_LIMIT 是不可达死防线。A.9 改测 spacing 路径的 pre_est 拦截，
	# 与 A.10（count 路径 :217 分支）互补，覆盖 pre_est 两个计算分支。
	var mock_a9 := MockServer.new()
	var orch_a9 := _make_orch(mock_a9, [], root, [false], [])
	orch_a9.handle_command(
		{
			"__req_id": "r9", "shape": "wall", "path": [[0, 0, 0], [100, 0, 0]],
			"spacing": 1.0, "mode": "continuous"  # total=100 → pre_est=100/1+2=102 > 64
		},
		9, ws
	)
	runner.check(mock_a9.sent.size() == 1, "A.9 发 1 条 result")
	if mock_a9.sent.size() == 1:
		runner.check(
			String(mock_a9.sent[0]["fields"].get("error")) == "invalid_params",
			"A.9 pre_est 超上限 → invalid_params"
		)
		runner.check(
			String(mock_a9.sent[0]["fields"].get("message")).find("采样点预估") >= 0,
			"A.9 message 含 '采样点预估'"
		)

	# === A.10 pre_est 超上限（count 路径 :217 分支）===
	var mock_a10 := MockServer.new()
	var orch_a10 := _make_orch(mock_a10, [], root, [false], [])
	orch_a10.handle_command(
		{"__req_id": "r10", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]], "count": 64, "mode": "continuous"},
		# count=64 → pre_est=64+1=65 > 64
		10, ws
	)
	runner.check(mock_a10.sent.size() == 1, "A.10 发 1 条 result")
	if mock_a10.sent.size() == 1:
		runner.check(
			String(mock_a10.sent[0]["fields"].get("error")) == "invalid_params",
			"A.10 pre_est 超上限 → invalid_params"
		)

	# === A.11 path parse 错（path 非 Array → parse_path error）===
	var mock_a11 := MockServer.new()
	var orch_a11 := _make_orch(mock_a11, [], root, [false], [])
	orch_a11.handle_command(
		{"__req_id": "r11", "shape": "wall", "path": "not_array", "count": 2, "mode": "continuous"},
		11, ws
	)
	runner.check(mock_a11.sent.size() == 1, "A.11 发 1 条 result")
	if mock_a11.sent.size() == 1:
		runner.check(
			String(mock_a11.sent[0]["fields"].get("error")) == "invalid_params",
			"A.11 path 非 Array → invalid_params"
		)
		# grep PathGenerator.parse_path:14
		runner.check(
			String(mock_a11.sent[0]["fields"].get("message")).find("path 必须是数组") >= 0,
			"A.11 message 含 'path 必须是数组'"
		)

	# === A.12 path_node 解析错（节点不存在 → resolve_path3d error）===
	var mock_a12 := MockServer.new()
	var orch_a12 := _make_orch(mock_a12, [], root, [false], [])
	orch_a12.handle_command(
		{"__req_id": "r12", "shape": "wall", "path_node": "/Root/NotExist", "count": 2, "mode": "continuous"},
		12, ws
	)
	runner.check(mock_a12.sent.size() == 1, "A.12 发 1 条 result")
	if mock_a12.sent.size() == 1:
		runner.check(
			String(mock_a12.sent[0]["fields"].get("error")) == "invalid_params",
			"A.12 path_node 不存在 → invalid_params"
		)
		# grep ScenePlacer.resolve_path3d「未找到」
		runner.check(
			String(mock_a12.sent[0]["fields"].get("message")).find("未找到") >= 0,
			"A.12 message 含 '未找到'"
		)

	# === A.13 validate 错（spacing 与 count 都有 → validate 'spacing 与 count 只能二选一'）===
	var mock_a13 := MockServer.new()
	var orch_a13 := _make_orch(mock_a13, [], root, [false], [])
	orch_a13.handle_command(
		{
			"__req_id": "r13", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "spacing": 1.0, "mode": "continuous"
		},
		13, ws
	)
	runner.check(mock_a13.sent.size() == 1, "A.13 发 1 条 result")
	if mock_a13.sent.size() == 1:
		runner.check(
			String(mock_a13.sent[0]["fields"].get("error")) == "invalid_params",
			"A.13 validate 错 → invalid_params"
		)
		runner.check(
			String(mock_a13.sent[0]["fields"].get("message")).find("只能二选一") >= 0,
			"A.13 message 含 '只能二选一'"
		)

	# === B.14 单件 generate 成功（save=true → resource_path 非空 + _dock_add + _mark_unsaved）===
	var mock_b14 := MockServer.new()
	var marked_b14 := [false]
	var added_b14: Array = []
	var orch_b14 := _make_orch(mock_b14, [], root, marked_b14, added_b14)
	orch_b14.handle_command(
		{"__req_id": "r14", "shape": "box", "name": "b14", "save": true}, 14, ws
	)
	runner.check(mock_b14.sent.size() == 1, "B.14 发 1 条 result")
	if mock_b14.sent.size() == 1:
		runner.check(bool(mock_b14.sent[0]["ok"]), "B.14 success=true")
		var f14: Dictionary = mock_b14.sent[0]["fields"]
		runner.check(String(f14.get("node_path", "")) != "", "B.14 node_path 非空")
		# save=true → resource_path 非空（覆盖 :122 place_payload save 透传）
		var rp14 := String(f14.get("resource_path", ""))
		runner.check(rp14 != "", "B.14 save=true → resource_path 非空（:122 透传）")
		runner.check(bool(marked_b14[0]), "B.14 _mark_unsaved 被调")
		runner.check(added_b14.size() == 1, "B.14 _dock_add 被调 1 次")
		# 清理 save 的 .tscn
		if rp14 != "" and FileAccess.file_exists(rp14):
			DirAccess.remove_absolute(rp14)

	# === B.15 discrete path count=2（2 条 per-point result + _dock_add×2 + mark）===
	var mock_b15 := MockServer.new()
	var marked_b15 := [false]
	var added_b15: Array = []
	var orch_b15 := _make_orch(mock_b15, [], root, marked_b15, added_b15)
	orch_b15.handle_command(
		{"__req_id": "r15", "shape": "cylinder", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "name": "b15"},
		15, ws
	)
	runner.check(mock_b15.sent.size() == 2, "B.15 discrete count=2 → 2 条 result")
	var ok_count_b15 := 0
	for r15 in mock_b15.sent:
		if bool(r15["ok"]):
			ok_count_b15 += 1
	runner.check(ok_count_b15 == 2, "B.15 2 条都 success=true")
	runner.check(added_b15.size() == 2, "B.15 _dock_add 被调 2 次")
	runner.check(bool(marked_b15[0]), "B.15 any_success → _mark_unsaved 被调")

	# === B.16 continuous wall 2 段（count=2 → 2 段 → 2 条 result）===
	var mock_b16 := MockServer.new()
	var marked_b16 := [false]
	var orch_b16 := _make_orch(mock_b16, [], root, marked_b16, [])
	orch_b16.handle_command(
		{
			"__req_id": "r16", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "mode": "continuous", "name": "b16"
		},
		16, ws
	)
	runner.check(mock_b16.sent.size() == 2, "B.16 continuous count=2 → 2 条 result")
	runner.check(bool(marked_b16[0]), "B.16 any_success → _mark_unsaved 被调")

	# 清理 root
	runner.root.remove_child(root)
	root.free()
