# custom_meshes.gd
# 5 个手写 ArrayMesh（cone/tube/torus/stairs/fence），全用 SurfaceTool。
# stairs/fence 把多部件烘焙成单 ArrayMesh（A3，防 first-mesh-multi-mesh 复发）。
@tool
class_name CustomMeshes
extends RefCounted

# --- cone 圆锥 ---
static func make_cone(params: Dictionary) -> ArrayMesh:
	var height: float = float(params.get("height", 1.0))
	var radius: float = float(params.get("radius", 0.5))
	var segments: int = max(int(params.get("segments", 24)), 3)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var yb := -height / 2.0
	var yt := height / 2.0
	for i in segments:
		var a0: float = (float(i) / segments) * TAU
		var a1: float = (float(i + 1) / segments) * TAU
		var v0 := Vector3(cos(a0) * radius, yb, sin(a0) * radius)
		var v1 := Vector3(cos(a1) * radius, yb, sin(a1) * radius)
		st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(Vector3(0.0, yt, 0.0))       # 侧面
		st.add_vertex(Vector3(0.0, yb, 0.0)); st.add_vertex(v1); st.add_vertex(v0)         # 底面（法线 -Y）
	st.index()
	st.generate_normals()
	return st.commit()

# --- tube 空心圆柱 ---
static func make_tube(params: Dictionary) -> ArrayMesh:
	var height: float = float(params.get("height", 1.0))
	var radius: float = float(params.get("radius", 0.5))
	var thickness: float = float(params.get("thickness", 0.1))
	var segments: int = max(int(params.get("segments", 24)), 3)
	var inner := maxf(radius - thickness, 0.001)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var yb := -height / 2.0
	var yt := height / 2.0
	for i in segments:
		var a0: float = (float(i) / segments) * TAU
		var a1: float = (float(i + 1) / segments) * TAU
		var o0b := Vector3(cos(a0) * radius, yb, sin(a0) * radius)
		var o1b := Vector3(cos(a1) * radius, yb, sin(a1) * radius)
		var o0t := Vector3(cos(a0) * radius, yt, sin(a0) * radius)
		var o1t := Vector3(cos(a1) * radius, yt, sin(a1) * radius)
		var i0b := Vector3(cos(a0) * inner, yb, sin(a0) * inner)
		var i1b := Vector3(cos(a1) * inner, yb, sin(a1) * inner)
		var i0t := Vector3(cos(a0) * inner, yt, sin(a0) * inner)
		var i1t := Vector3(cos(a1) * inner, yt, sin(a1) * inner)
		st.add_vertex(o0b); st.add_vertex(o1b); st.add_vertex(o0t)                         # 外侧面
		st.add_vertex(o1b); st.add_vertex(o1t); st.add_vertex(o0t)
		st.add_vertex(i0b); st.add_vertex(i0t); st.add_vertex(i1b)                         # 内侧面（反向）
		st.add_vertex(i1b); st.add_vertex(i0t); st.add_vertex(i1t)
		st.add_vertex(o0t); st.add_vertex(o1t); st.add_vertex(i1t)                         # 顶环
		st.add_vertex(o0t); st.add_vertex(i1t); st.add_vertex(i0t)
		st.add_vertex(o0b); st.add_vertex(i1b); st.add_vertex(o1b)                         # 底环（-Y）
		st.add_vertex(o0b); st.add_vertex(i0b); st.add_vertex(i1b)
	st.index()
	st.generate_normals()
	return st.commit()

# --- torus 圆环 ---
static func make_torus(params: Dictionary) -> ArrayMesh:
	var R: float = float(params.get("major_radius", 0.5))
	var r: float = float(params.get("minor_radius", 0.2))
	var ms: int = max(int(params.get("major_segments", 32)), 3)
	var ns: int = max(int(params.get("minor_segments", 16)), 3)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in ms:
		var a0: float = (float(i) / ms) * TAU
		var a1: float = (float(i + 1) / ms) * TAU
		for j in ns:
			var b0: float = (float(j) / ns) * TAU
			var b1: float = (float(j + 1) / ns) * TAU
			var p00 := _torus_vertex(R, r, a0, b0)
			var p01 := _torus_vertex(R, r, a0, b1)
			var p10 := _torus_vertex(R, r, a1, b0)
			var p11 := _torus_vertex(R, r, a1, b1)
			st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p01)
			st.add_vertex(p01); st.add_vertex(p10); st.add_vertex(p11)
	st.index()
	st.generate_normals()
	return st.commit()

static func _torus_vertex(R: float, r: float, a: float, b: float) -> Vector3:
	var ring := Vector3(cos(a) * R, 0.0, sin(a) * R)
	var n := Vector3(cos(a), 0.0, sin(a))
	return ring + n * cos(b) * r + Vector3.UP * sin(b) * r

# --- stairs 楼梯（多台阶 → 单 ArrayMesh，A3）---
static func make_stairs(params: Dictionary) -> ArrayMesh:
	var steps: int = max(int(params.get("steps", 5)), 1)
	var sh: float = float(params.get("step_height", 0.2))
	var sd: float = float(params.get("step_depth", 0.3))
	var w: float = float(params.get("width", 1.2))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in steps:
		_add_box(st, Vector3(0.0, (i + 0.5) * sh, (i + 0.5) * sd), Vector3(w, sh, sd))
	st.index()
	st.generate_normals()
	return st.commit()

# --- fence 栅栏（柱 + 横档 → 单 ArrayMesh，A3）---
static func make_fence(params: Dictionary) -> ArrayMesh:
	var length: float = float(params.get("length", 3.0))
	var height: float = float(params.get("height", 1.2))
	var posts: int = max(int(params.get("posts", 4)), 1)
	var pr: float = float(params.get("post_radius", 0.05))
	var rt: float = float(params.get("rail_thickness", 0.04))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 12
	for i in posts:
		var t: float = 0.0 if posts == 1 else float(i) / float(posts - 1)
		var x := (t - 0.5) * length
		_add_cylinder(st, Vector3(x, height / 2.0, 0.0), pr, height, seg)
	_add_box(st, Vector3(0.0, height * 0.8, 0.0), Vector3(length, rt, rt))   # 上横档
	_add_box(st, Vector3(0.0, height * 0.3, 0.0), Vector3(length, rt, rt))   # 下横档
	st.index()
	st.generate_normals()
	return st.commit()

# --- 辅助：box（12 三角面）加进 SurfaceTool ---
static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var hx := size.x / 2.0
	var hy := size.y / 2.0
	var hz := size.z / 2.0
	var c := center
	var v := [
		c + Vector3(-hx, -hy, -hz), c + Vector3( hx, -hy, -hz),
		c + Vector3( hx,  hy, -hz), c + Vector3(-hx,  hy, -hz),
		c + Vector3(-hx, -hy,  hz), c + Vector3( hx, -hy,  hz),
		c + Vector3( hx,  hy,  hz), c + Vector3(-hx,  hy,  hz),
	]
	var faces := [
		[0,1,2, 0,2,3], [5,4,7, 5,7,6], [4,0,3, 4,3,7],
		[1,5,6, 1,6,2], [3,2,6, 3,6,7], [4,5,1, 4,1,0],
	]
	for f in faces:
		for idx in f:
			st.add_vertex(v[idx])

# --- 辅助：圆柱侧面加进 SurfaceTool（栅栏柱用，无顶/底盖）---
static func _add_cylinder(st: SurfaceTool, center: Vector3, radius: float, height: float, segments: int) -> void:
	for i in segments:
		var a0: float = (float(i) / segments) * TAU
		var a1: float = (float(i + 1) / segments) * TAU
		var o0b := center + Vector3(cos(a0) * radius, -height / 2.0, sin(a0) * radius)
		var o1b := center + Vector3(cos(a1) * radius, -height / 2.0, sin(a1) * radius)
		var o0t := center + Vector3(cos(a0) * radius,  height / 2.0, sin(a0) * radius)
		var o1t := center + Vector3(cos(a1) * radius,  height / 2.0, sin(a1) * radius)
		st.add_vertex(o0b); st.add_vertex(o1b); st.add_vertex(o0t)
		st.add_vertex(o1b); st.add_vertex(o1t); st.add_vertex(o0t)
