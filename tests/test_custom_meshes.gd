extends RefCounted
## 5 手写 ArrayMesh 单测（顶点>0 + 索引合法 + 单 surface A3）。


func run(runner) -> void:
	var meshes := {
		"cone": CustomMeshes.make_cone({"height": 1.0, "radius": 0.5, "segments": 12}),
		"tube":
		CustomMeshes.make_tube({"height": 1.0, "radius": 0.5, "thickness": 0.1, "segments": 12}),
		"torus":
		CustomMeshes.make_torus(
			{"major_radius": 0.5, "minor_radius": 0.2, "major_segments": 16, "minor_segments": 8}
		),
		"stairs":
		CustomMeshes.make_stairs({"steps": 5, "step_height": 0.2, "step_depth": 0.3, "width": 1.2}),
		"fence":
		CustomMeshes.make_fence(
			{"length": 3.0, "height": 1.2, "posts": 4, "post_radius": 0.05, "rail_thickness": 0.04}
		),
	}
	for shape in meshes:
		var mesh: ArrayMesh = meshes[shape]
		runner.check(mesh != null and mesh is ArrayMesh, "%s 返回 ArrayMesh" % shape)
		runner.check(mesh.get_surface_count() == 1, "%s 单 surface（A3 烘焙）" % shape)
		var vlen: int = mesh.surface_get_array_len(0)
		runner.check(vlen > 0, "%s 顶点数 > 0（实际 %d）" % [shape, vlen])
		# 索引合法性（A3 防 first-mesh-multi-mesh 复发：组合体也要索引合法）
		var arrays: Array = mesh.surface_get_arrays(0)
		var indices: PackedInt32Array = (
			arrays[Mesh.ARRAY_INDEX]
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array
			else PackedInt32Array()
		)
		if indices.size() > 0:
			var ok := true
			for idx in indices:
				if int(idx) >= vlen:
					ok = false
					break
			runner.check(ok, "%s 所有索引 < 顶点数（合法）" % shape)
	# stairs 顶点数随台阶数增长（参数化断言，防"少画 box"回归）
	var s3 := CustomMeshes.make_stairs(
		{"steps": 3, "step_height": 0.2, "step_depth": 0.3, "width": 1.2}
	)
	var s8 := CustomMeshes.make_stairs(
		{"steps": 8, "step_height": 0.2, "step_depth": 0.3, "width": 1.2}
	)
	var v3 := s3.surface_get_array_len(0)
	var v8 := s8.surface_get_array_len(0)
	runner.check(v8 > v3, "stairs 顶点随台阶数增长（steps=3 → %d，steps=8 → %d）" % [v3, v8])
	runner.check(v8 >= v3 + 5, "steps=8 顶点显著多于 steps=3（至少 +5，实际 +%d）" % (v8 - v3))
	# 与 steps 数绑定的下限断言（系数 6 = 实测每 box ≈6-8 唯一顶点的保守下界）
	# 同时抓"参数失效"（v3/v8 异常小）和"少画 box"（range(steps-1) / clamp-to-5）
	runner.check(v3 >= 3 * 6, "steps=3 顶点 ≥ 18（每 box ≥6 唯一顶点，实际 %d）" % v3)
	runner.check(v8 >= 8 * 6, "steps=8 顶点 ≥ 48（每 box ≥6 唯一顶点，实际 %d）" % v8)
	# I-3：box 法线轴对齐（stairs steps=1 = 单 box，每顶点法线应仅一个分量绝对值≈1，其余≈0；不再被平滑为多分量对角线）
	var box_mesh := CustomMeshes.make_stairs(
		{"steps": 1, "step_height": 0.2, "step_depth": 0.3, "width": 1.2}
	)
	var box_arrays := box_mesh.surface_get_arrays(0)
	var box_normals: PackedVector3Array = box_arrays[Mesh.ARRAY_NORMAL]
	runner.check(box_normals.size() > 0, "box 法线数组非空（I-3）")
	var axis_aligned: int = 0
	for nv in box_normals:
		# 轴对齐 = 仅一个分量绝对值 > 0.9
		var nz_count: int = 0
		if absf(nv.x) > 0.9:
			nz_count += 1
		if absf(nv.y) > 0.9:
			nz_count += 1
		if absf(nv.z) > 0.9:
			nz_count += 1
		if nz_count == 1:
			axis_aligned += 1
	runner.check(
		axis_aligned == box_normals.size(),
		"box 法线全轴对齐（%d/%d，I-3：不再被平滑为对角线）" % [axis_aligned, box_normals.size()]
	)
