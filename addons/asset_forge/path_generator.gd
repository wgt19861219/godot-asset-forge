# path_generator.gd
# 路径阵列纯几何静态类（程序化场景生成 MVP）：折线 → 采样点列表。
# 不创建节点、不调 AssetFactory、不碰场景树（可独立 headless 单测）。
@tool
class_name PathGenerator
extends RefCounted

const _EPS: float = 1e-4  # 米；与 forge_client.predict_n 同值（F1 同步约定）


# path 数组 [[x,y,z],...] → {"points": Array[Vector3], "error": String}
static func parse_path(raw: Variant) -> Dictionary:
	if not (raw is Array):
		return {"points": [], "error": "path 必须是数组"}
	var arr := raw as Array
	if arr.size() < 2:
		return {"points": [], "error": "path 至少需要 2 个点"}
	var points: Array = []
	for i in arr.size():
		var v3: Variant = _to_vector3(arr[i])
		if v3 == null:
			return {"points": [], "error": "path 第 %d 个点必须是 [x,y,z] 数组" % i}
		points.append(v3)
	return {"points": points, "error": ""}


# 输入退化校验 → 错误描述字符串（空串 = 合法）
# mode: "discrete"（v1 默认，零回归）/ "continuous"（v2 段阵列）
static func validate(
	points: Array, spacing: float, count: int, align: String,
	include_endpoints: bool, mode := "discrete", align_vertices := false
) -> String:
	if mode != "discrete" and mode != "continuous":
		return "mode 必须 discrete|continuous"
	if align != "none" and align != "path" and align != "normal":
		return "align 必须是 none/path/normal"
	if points.size() < 2:
		return "path 至少需要 2 个点"
	var total := _total_length(points)
	if total < _EPS:
		return "path 所有点重合（总长为 0）"
	var has_spacing: bool = spacing > 0.0
	var has_count: bool = count >= 1
	if has_spacing and has_count:
		return "spacing 与 count 只能二选一"
	if not has_spacing and not has_count:
		return "必须提供 spacing（>0）或 count（>=1）之一"
	# F5：count=1 + endpoints 仅 discrete 模式拦截（continuous count=1 = 1 段，合法）
	if mode == "discrete" and has_count and count == 1 and include_endpoints:
		return "count==1 时 include_endpoints 必须为 false（含两端至少 2 个采样点）"
	# continuous：align 强制 path（length 沿 chord）
	if mode == "continuous" and align != "path":
		return "continuous align 强制 path（length 沿 chord），当前 " + align
	# v4：va 与不兼容模式冲突 → 报错（追加末尾，让 v2 既有校验先报；
	# va+count+spacing 被 spacing/count 互斥先拦，va+count 无 spacing 才落到此）
	if align_vertices and mode == "discrete":
		return "align_vertices 仅 continuous 模式可用"
	if align_vertices and mode == "continuous" and has_count:
		return "align_vertices 仅 spacing 模式可用（count 等分边界不对齐顶点）"
	return ""


# 已 valid 的输入 → 采样点列表 [{"position":Vector3,"rotation_deg":Vector3,"distance":float}, ...]
# mode="discrete"（v1）：返回顶点采样点（含 miter 切线）。
# mode="continuous"：返回段数组 [{position, rotation_deg, length, distance}]（每段沿 chord）。
static func sample(
	points: Array, spacing: float, count: int, align: String,
	include_endpoints: bool, mode := "discrete", align_vertices := false
) -> Array:
	if mode == "continuous":
		return _sample_continuous(points, spacing, count, include_endpoints, align_vertices)
	var last: int = points.size() - 1
	var seg_len: Array = []
	var vertex_d: Array = [0.0]  # vertex_d[i] = 顶点 i 的累计弧长
	var acc := 0.0
	for i in last:
		var l: float = (points[i] as Vector3).distance_to(points[i + 1] as Vector3)
		seg_len.append(l)
		acc += l
		vertex_d.append(acc)
	var total: float = acc

	var distances := _distances(total, spacing, count, include_endpoints)

	var samples: Array = []
	for d_var in distances:
		var d: float = float(d_var)
		var pos := _position_at(d, seg_len, points, total)
		var tangent := _tangent_at(d, vertex_d, seg_len, points)
		var yaw := rad_to_deg(atan2(-tangent.x, -tangent.z))
		var rot := Vector3.ZERO
		if align == "path":
			rot = Vector3(0.0, yaw, 0.0)
		elif align == "normal":
			rot = Vector3(0.0, yaw + 90.0, 0.0)
		samples.append({"position": pos, "rotation_deg": rot, "distance": d})
	return samples


# continuous 模式：段 = 弧长边界相邻对，每段返回 {position, rotation_deg, length, distance}
# - count 模式：N 等长段（step=total/N），段数=N
# - spacing 模式：每 spacing 一段，段数=v1 离散点数 - 1
# - yaw=atan2(-chord.z, chord.x)（+X 对齐 chord，与 discrete 的切线 miter 不同）
# - 零长段（length<_EPS）跳过
static func _sample_continuous(
	points: Array, spacing: float, count: int, include_endpoints: bool, align_vertices := false
) -> Array:
	var last: int = points.size() - 1
	var seg_len: Array = []
	var vertex_d: Array = [0.0]  # v4：va 分支激活此字段（v2 算完未用，死代码转核心）
	var acc := 0.0
	for i in last:
		var l: float = (points[i] as Vector3).distance_to(points[i + 1] as Vector3)
		seg_len.append(l)
		acc += l
		vertex_d.append(acc)
	var total: float = acc
	# 段边界
	var boundaries: Array = []
	if align_vertices:
		# v4：每折线段 [vertex_d[i], vertex_d[i+1]] 独立按 spacing 切 + 段末去重
		# validate 已保证 mode==continuous 且 spacing>0
		for i in range(last):
			var seg_start: float = float(vertex_d[i])
			var seg_end: float = float(vertex_d[i + 1])
			if float(seg_len[i]) < _EPS:
				continue  # 零长折线段跳过（其末顶点=下段起点，不丢）
			if boundaries.is_empty():
				boundaries.append(seg_start)  # 首段才补起点（跨段共享顶点）
			var d := seg_start + spacing
			while d < seg_end - _EPS:
				boundaries.append(d)
				d += spacing
			# 段末去重（复用 v2 :117 补尾模式，防御浮点近似整除重复边界）
			if (seg_end - float(boundaries[boundaries.size() - 1])) > _EPS:
				boundaries.append(seg_end)
	elif spacing > 0.0:
		var d := 0.0
		while d <= total + _EPS:
			boundaries.append(d)
			d += spacing
		if include_endpoints and (total - float(boundaries[boundaries.size() - 1])) > _EPS:
			boundaries.append(total)
	elif count >= 1:
		if count == 1:
			boundaries = [0.0, total]
		else:
			var step := total / float(count)
			for i in range(count + 1):
				boundaries.append(step * float(i))
	# 段 = 相邻边界对
	var segments: Array = []
	for i in range(boundaries.size() - 1):
		var d_start: float = float(boundaries[i])
		var d_end: float = float(boundaries[i + 1])
		var p_start := _position_at(d_start, seg_len, points, total)
		var p_end := _position_at(d_end, seg_len, points, total)
		var length: float = p_start.distance_to(p_end)
		if length < _EPS:
			continue  # 零长段跳过（不计 predict_n、不 place）
		var position := p_start.lerp(p_end, 0.5)
		var chord := p_end - p_start
		var yaw := rad_to_deg(atan2(-chord.z, chord.x))  # +X 对齐 chord
		segments.append(
			{
				"position": position,
				"rotation_deg": Vector3(0.0, yaw, 0.0),  # continuous 强制 align=path
				"length": length,
				"distance": d_start
			}
		)
	return segments


# --- helpers ---


static func _to_vector3(p: Variant) -> Variant:
	var arr: Array = []
	if p is Array:
		arr = (p as Array).duplicate()
	elif p is PackedFloat64Array:
		for x in (p as PackedFloat64Array):
			arr.append(x)
	else:
		return null
	if arr.size() < 3:
		return null
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _total_length(points: Array) -> float:
	var total := 0.0
	for i in points.size() - 1:
		total += (points[i] as Vector3).distance_to(points[i + 1] as Vector3)
	return total


static func _distances(
	total: float, spacing: float, count: int, include_endpoints: bool
) -> Array:
	var distances: Array = []
	if spacing > 0.0:
		var d := 0.0
		while d <= total + _EPS:
			distances.append(d)
			d += spacing
		if include_endpoints and (total - float(distances[distances.size() - 1])) > _EPS:
			distances.append(total)
	elif count >= 1:
		if count == 1:
			distances.append(total / 2.0)  # validate 已保证 include_endpoints=false
		elif include_endpoints:
			var step := total / float(count - 1)
			for i in count:
				distances.append(step * float(i))
		else:
			var step := total / float(count)
			for i in count:
				distances.append(step * (float(i) + 0.5))
	return distances


static func _position_at(
	d: float, seg_len: Array, points: Array, total: float
) -> Vector3:
	if d >= total - _EPS:
		return points[points.size() - 1] as Vector3
	var acc := 0.0
	for i in seg_len.size():
		var l: float = float(seg_len[i])
		if d <= acc + l + _EPS:
			var t: float = (d - acc) / l if l > _EPS else 0.0
			return (points[i] as Vector3).lerp(points[i + 1] as Vector3, t)
		acc += l
	return points[points.size() - 1] as Vector3


static func _tangent_at(
	d: float, vertex_d: Array, seg_len: Array, points: Array
) -> Vector3:
	var last: int = points.size() - 1
	# 末点
	if abs(d - float(vertex_d[last])) < _EPS:
		var li := last - 1
		while li >= 0 and float(seg_len[li]) < _EPS:
			li -= 1
		if li < 0:
			return Vector3.FORWARD
		return ((points[li + 1] as Vector3) - (points[li] as Vector3)).normalized()
	# 首点
	if abs(d - 0.0) < _EPS:
		var fi := 0
		while fi < last and float(seg_len[fi]) < _EPS:
			fi += 1
		if fi >= last:
			return Vector3.FORWARD
		return ((points[fi + 1] as Vector3) - (points[fi] as Vector3)).normalized()
	# 内部顶点 → miter（角平分线）
	for i in range(1, last):
		if abs(d - float(vertex_d[i])) < _EPS:
			var a := _seg_dir(seg_len, points, i - 1)
			var b := _seg_dir(seg_len, points, i)
			var bisect := a + b
			if bisect.length_squared() < 1e-8:  # F3：a ≈ -b 180° 折返 → 回退入边
				return a
			return bisect.normalized()
	# 段内点
	for i in last:
		if d >= float(vertex_d[i]) and d < float(vertex_d[i + 1]):
			return _seg_dir(seg_len, points, i)
	return Vector3.FORWARD


static func _seg_dir(seg_len: Array, points: Array, i: int) -> Vector3:
	if float(seg_len[i]) < _EPS:
		return Vector3.FORWARD
	return ((points[i + 1] as Vector3) - (points[i] as Vector3)).normalized()
