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
	runner.check(not bool(r3["success"]) and String(r3["error"]) == "parent_not_found", "parent 不存在 → parent_not_found")
	# parent 指定子节点（同 batch_id=1）
	var decor := Node3D.new()
	decor.name = "Decor"
	root.add_child(decor)
	var r4 := ScenePlacer.place(root, mesh, null, {"name": "barrel", "parent": "/Root/Decor"}, stack, 1)
	runner.check(bool(r4["success"]) and decor.get_node_or_null(NodePath("barrel")) != null, "parent=/Root/Decor → barrel 进 Decor")
	# undo_last 整 batch=1（3 节点原子弹）
	var ur1 := ScenePlacer.undo_last(stack)
	runner.check(bool(ur1["success"]) and int(ur1["freed"]) == 3, "undo_last freed 3（同 batch=1 原子弹）")
	var ur2 := ScenePlacer.undo_last(stack)
	runner.check(not bool(ur2["success"]) and String(ur2["error"]) == "nothing_to_undo", "undo 空栈 → nothing_to_undo")
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
	runner.check(bool(rs["success"]) and String(rs["resource_path"]) != "", "save=true 返 resource_path")
	var path: String = rs["resource_path"]
	runner.check(FileAccess.file_exists(path), ".tscn 存盘存在: " + path)
	ScenePlacer.undo_last(stack3)
	runner.check(FileAccess.file_exists(path), "undo 后 .tscn 仍在（IMPORTANT-2：undo 不删 .tscn）")
	DirAccess.remove_absolute(path)  # 清理
	# 清理 root
	runner.root.remove_child(root)
	root.free()
