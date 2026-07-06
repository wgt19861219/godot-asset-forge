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
	# v5 _post_xs 纯函数单测（fence 柱 x 坐标，端柱参数）
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, true, true), [-1.5, -0.5, 0.5, 1.5], "#1 默认满配")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, true, false), [-1.5, -0.5, 0.5], "#2 去末柱（continuous 非末段）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, false, true), [-0.5, 0.5, 1.5], "#3 去首柱")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, false, false), [-0.5, 0.5], "#4 去首末")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 1, true, true), [-1.5], "#5 posts=1 走 t=0.0 特例（左端，make_fence 既有行为）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 1, false, false), [], "#6 posts=1 全去 → 空列表（不崩）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 2, true, true), [-1.5, 1.5], "#7 posts=2 两端柱")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 2, true, false), [-1.5], "#8 posts=2 去末")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 0, true, true), [], "#9 posts<1 → 空列表（不崩，信任上层 max(posts,1)）")
	# v6 make_ramp 手写 wedge（A3 + 斜顶法线 Y>0）
	var ramps := {
		"上升默认": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.0, "end_height": 1.0}),
		"上升自定义": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.2, "end_height": 0.8}),
		"水平退化": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.0, "end_height": 0.0}),
		"下降": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 1.0, "end_height": 0.5}),
	}
	for label in ramps:
		var rm: ArrayMesh = ramps[label]
		runner.check(rm != null and rm is ArrayMesh, "make_ramp %s 返回 ArrayMesh" % label)
		runner.check(rm.get_surface_count() == 1, "make_ramp %s 单 surface（A3）" % label)
		var rvlen: int = rm.surface_get_array_len(0)
		runner.check(rvlen > 0, "make_ramp %s 顶点数 > 0（实际 %d）" % [label, rvlen])
		# 斜顶法线断言：所有法线模长≈1（归一化）+ 存在朝上法线 Y>0.5（斜顶/水平顶朝上）
		var rarrays: Array = rm.surface_get_arrays(0)
		var rnormals: PackedVector3Array = rarrays[Mesh.ARRAY_NORMAL]
		var all_unit: bool = true
		var has_up_facing: bool = false  # 朝上法线（斜顶/水平顶 Y>0.5）
		for nv in rnormals:
			if absf(nv.length() - 1.0) > 0.01:
				all_unit = false
			if nv.y > 0.5:
				has_up_facing = true  # 斜顶（上升/下降 Y>0）或水平顶（start==end 时 (0,1,0)）
		runner.check(all_unit, "make_ramp %s 法线全归一化（模长≈1）" % label)
		runner.check(has_up_facing, "make_ramp %s 存在朝上法线 Y>0.5（斜顶/水平顶）" % label)


# v5 _post_xs 单测辅助：逐元素 is_equal_approx 比较浮点数组（posts=4 含 t=1/3 → -0.5 浮点，不能直接 ==）
func _check_xs(runner, actual: Array, expected: Array, label: String) -> void:
	var ok: bool = actual.size() == expected.size()
	if ok:
		for i in actual.size():
			if not is_equal_approx(float(actual[i]), float(expected[i])):
				ok = false
				break
	runner.check(ok, "_post_xs %s：期望 %s，实际 %s" % [label, str(expected), str(actual)])
