extends RefCounted
## scene_placer 单测（place/undo 语义 IMPORTANT-2 + name 碰撞 + parent_not_found + batch 原子 + save .tscn 不被 undo 删）。
## root 入树（runner.root.add_child）以使绝对 NodePath 解析生效（项目惯例，见 test_alarm）。


func run(runner) -> void:
	var root := Node3D.new()
	root.name = "Root"
	runner.root.add_child(root)
	var mesh := BoxMesh.new()
	# 基本放置（同 batch=1，单次 undo 弹全部）
	var stack: Array = []
	var r1 := ScenePlacer.place(root, mesh, null, {"name": "crate"}, stack, 1)
	runner.check(bool(r1["success"]), "place 基本 success")
	runner.check(root.get_node_or_null(NodePath("crate")) != null, "crate 加到 root")
	runner.check(stack.size() == 1, "undo_stack +1")
	# name 碰撞 _001（Q3）—— 同 batch_id=1
	var r2 := ScenePlacer.place(root, mesh, null, {"name": "crate"}, stack, 1)
	runner.check(root.get_node_or_null(NodePath("crate_001")) != null, "name 碰撞 → crate_001")
	# parent_not_found（Q5：中间路径不自动建；不入栈）
	var r3 := ScenePlacer.place(root, mesh, null, {"name": "x", "parent": "/Root/Nope"}, stack, 1)
	runner.check(
		not bool(r3["success"]) and String(r3["error"]) == "parent_not_found",
		"parent 不存在 → parent_not_found"
	)
	# parent 指定子节点（同 batch_id=1）
	var decor := Node3D.new()
	decor.name = "Decor"
	root.add_child(decor)
	var r4 := ScenePlacer.place(
		root, mesh, null, {"name": "barrel", "parent": "/Root/Decor"}, stack, 1
	)
	runner.check(
		bool(r4["success"]) and decor.get_node_or_null(NodePath("barrel")) != null,
		"parent=/Root/Decor → barrel 进 Decor"
	)
	# undo_last 整 batch=1（3 节点原子弹）
	var ur1 := ScenePlacer.undo_last(stack)
	runner.check(
		bool(ur1["success"]) and int(ur1["freed"]) == 3, "undo_last freed 3（同 batch=1 原子弹）"
	)
	var ur2 := ScenePlacer.undo_last(stack)
	runner.check(
		not bool(ur2["success"]) and String(ur2["error"]) == "nothing_to_undo",
		"undo 空栈 → nothing_to_undo"
	)
	# batch 原子 undo（Q4）
	var stack2: Array = []
	ScenePlacer.place(root, mesh, null, {"name": "b1"}, stack2, 10)
	ScenePlacer.place(root, mesh, null, {"name": "b2"}, stack2, 10)
	ScenePlacer.place(root, mesh, null, {"name": "b3"}, stack2, 11)  # 不同 batch_id
	runner.check(stack2.size() == 3, "batch 测试放 3 个（2 个 batch=10，1 个 batch=11）")
	var ur3 := ScenePlacer.undo_last(stack2)
	runner.check(int(ur3["freed"]) == 1, "undo 仅弹 batch_id=11 一条（栈顶 batch）")
	var ur4 := ScenePlacer.undo_last(stack2)
	runner.check(int(ur4["freed"]) == 2, "再 undo 弹 batch_id=10 两条（batch 原子，Q4）")
	# save .tscn + undo 不删（IMPORTANT-2 核心）
	var stack3: Array = []
	var rs := ScenePlacer.place(root, mesh, null, {"name": "saveme", "save": true}, stack3, 20)
	runner.check(
		bool(rs["success"]) and String(rs["resource_path"]) != "", "save=true 返 resource_path"
	)
	var path: String = rs["resource_path"]
	runner.check(FileAccess.file_exists(path), ".tscn 存盘存在: " + path)
	ScenePlacer.undo_last(stack3)
	runner.check(FileAccess.file_exists(path), "undo 后 .tscn 仍在（IMPORTANT-2：undo 不删 .tscn）")
	DirAccess.remove_absolute(path)  # 清理
	# A-1：transform.position 以 PackedFloat64Array 传入应正确解析（与 asset_factory._vec3 约定一致，非 Vector3.ZERO）
	var stack4: Array = []
	var rpf := ScenePlacer.place(
		root,
		mesh,
		null,
		{"name": "pf64", "transform": {"position": PackedFloat64Array([1.5, 2.5, 3.5])}},
		stack4,
		30
	)
	runner.check(bool(rpf["success"]), "PackedFloat64Array position place success（A-1）")
	var pf64: Node3D = root.get_node_or_null(NodePath("pf64"))
	runner.check(pf64 != null, "pf64 节点存在（A-1）")
	if pf64 != null:
		runner.check_approx(
			pf64.position.x, 1.5, 0.001, "pf64 position.x = 1.5（A-1 PackedFloat64Array 解析，非 0）"
		)
		runner.check_approx(pf64.position.y, 2.5, 0.001, "pf64 position.y = 2.5（A-1）")
		runner.check_approx(pf64.position.z, 3.5, 0.001, "pf64 position.z = 3.5（A-1）")
	# === P2#5：undo_last freed 计数剔除已失效节点（手动释放中间节点，undo 不虚高）===
	var stack_p25: Array = []
	ScenePlacer.place(root, mesh, null, {"name": "p25_a"}, stack_p25, 40)
	ScenePlacer.place(root, mesh, null, {"name": "p25_b"}, stack_p25, 40)
	ScenePlacer.place(root, mesh, null, {"name": "p25_c"}, stack_p25, 40)
	# 手动释放中间节点 b（模拟用户在编辑器删了生成节点；栈条目仍在，is_instance_valid 已为 false）
	var node_b: Node = root.get_node_or_null(NodePath("p25_b"))
	if node_b != null:
		root.remove_child(node_b)
		node_b.free()
	var ur_p25 := ScenePlacer.undo_last(stack_p25)
	runner.check(bool(ur_p25["success"]), "P2#5 undo success（栈非空）")
	runner.check(
		int(ur_p25["freed"]) == 2,
		"P2#5 freed=2（3 条入栈但 b 已失效，只计 2 个真实释放，不虚报）"
	)
	runner.check(stack_p25.is_empty(), "P2#5 undo 后栈清空（3 条全弹，含失效条目）")
	# === ScenePlacer.resolve_path3d（v3 path_node）===
	# 构造 root + Path3D + Curve3D（注：本 suite 已有变量 r3 = place 返回值，此处用 path_root 避免冲突）
	var path_root := Node3D.new()
	path_root.name = "PathTestRoot"
	runner.root.add_child(path_root)
	# #1 Path3D 在原点 → points == baked_points（局部=世界）
	var p0 := Path3D.new()
	p0.name = "Path0"
	path_root.add_child(p0)
	p0.curve = Curve3D.new()
	p0.curve.add_point(Vector3(0, 0, 0))
	p0.curve.add_point(Vector3(2, 0, 0))
	p0.curve.add_point(Vector3(4, 0, 0))
	var res0 := ScenePlacer.resolve_path3d(path_root, "Path0")
	runner.check(res0["error"] == "", "resolve_path3d 原点 Path3D 无 error")
	runner.check(res0["points"].size() >= 2, "resolve_path3d 返回 baked_points（>=2 点）")
	runner.check(
		(res0["points"][0] as Vector3).is_equal_approx(Vector3(0, 0, 0)),
		"resolve_path3d 原点首点 = (0,0,0)"
	)
	# #2 Path3D 在 (10,0,0) → to_global 含位移
	var p1 := Path3D.new()
	p1.name = "Path1"
	p1.position = Vector3(10, 0, 0)
	path_root.add_child(p1)
	p1.curve = Curve3D.new()
	p1.curve.add_point(Vector3(0, 0, 0))
	p1.curve.add_point(Vector3(2, 0, 0))
	var res1 := ScenePlacer.resolve_path3d(path_root, "Path1")
	runner.check(
		(res1["points"][0] as Vector3).is_equal_approx(Vector3(10, 0, 0)),
		"resolve_path3d to_global 含位移（首点 0,0,0 → 10,0,0）"
	)
	# #3 Path3D 旋转 90°（绕 Y）→ to_global 含旋转（取 baked 末点 ≈ 控制点 (2,0,0) 经旋转 → 世界 Z 轴 ±2）
	var p2 := Path3D.new()
	p2.name = "Path2"
	p2.rotation = Vector3(0, deg_to_rad(90), 0)
	path_root.add_child(p2)
	p2.curve = Curve3D.new()
	p2.curve.add_point(Vector3(0, 0, 0))
	p2.curve.add_point(Vector3(2, 0, 0))  # 局部 +X，绕 Y +90° → 世界 -Z（右手系）
	var res2 := ScenePlacer.resolve_path3d(path_root, "Path2")
	var last2: Vector3 = res2["points"][res2["points"].size() - 1] as Vector3
	runner.check(
		abs(last2.z + 2.0) < 0.05 and abs(last2.x) < 0.05 and abs(last2.y) < 0.05,
		"resolve_path3d to_global 含旋转（局部末点 (2,0,0) 绕 Y +90° → 世界 (0,0,-2)，baked 末点 ≈）"
	)
	# #4 curve == null
	var p3 := Path3D.new()
	p3.name = "Path3"
	path_root.add_child(p3)
	# p3.curve 默认 null（不设）
	var res3 := ScenePlacer.resolve_path3d(path_root, "Path3")
	runner.check(res3["error"] != "", "resolve_path3d curve 未设置 → error")
	# #5 baked_points < 2（单点曲线）
	var p4 := Path3D.new()
	p4.name = "Path4"
	path_root.add_child(p4)
	p4.curve = Curve3D.new()
	p4.curve.add_point(Vector3(0, 0, 0))  # 仅 1 点
	var res4 := ScenePlacer.resolve_path3d(path_root, "Path4")
	runner.check(res4["error"] != "", "resolve_path3d baked_points < 2 → error")
	# #6 path_node 非 Path3D（MeshInstance3D）
	var m := MeshInstance3D.new()
	m.name = "NotPath"
	path_root.add_child(m)
	var res5 := ScenePlacer.resolve_path3d(path_root, "NotPath")
	runner.check(
		String(res5["error"]).find("必须是 Path3D") >= 0,
		"resolve_path3d 非 Path3D → error 含「必须是 Path3D」"
	)
	# #7 节点名不存在
	var res6 := ScenePlacer.resolve_path3d(path_root, "NotExist")
	runner.check(
		String(res6["error"]).find("未找到") >= 0, "resolve_path3d 节点不存在 → error 含「未找到」"
	)
	# 清理
	path_root.queue_free()
	# 清理 root
	runner.root.remove_child(root)
	root.free()
