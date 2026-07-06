# asset_factory.gd
# 调度层：create_mesh 分发（6 内置 PrimitiveMesh + 5 手写）+ create_material（4 来源）
@tool
class_name AssetFactory
extends RefCounted


static func create_mesh(shape: String, params: Dictionary) -> Mesh:
	match shape.to_lower():
		"box":
			var m := BoxMesh.new()
			m.size = _vec3(params, "size", Vector3.ONE)
			return m
		"cylinder":
			var m := CylinderMesh.new()
			m.height = float(params.get("height", 1.0))
			m.top_radius = float(params.get("radius", 0.5))
			m.bottom_radius = m.top_radius
			m.radial_segments = int(params.get("radial_segments", 24))
			return m
		"sphere":
			var m := SphereMesh.new()
			m.radius = float(params.get("radius", 0.5))
			m.radial_segments = int(params.get("radial_segments", 24))
			m.rings = int(params.get("rings", 16))
			return m
		"prism":
			var m := PrismMesh.new()
			m.size = _vec3(params, "size", Vector3.ONE)
			m.left_to_right = float(params.get("left_to_right", 0.5))
			return m
		"wall":  # 语义化 box：length/height/thickness
			var m := BoxMesh.new()
			m.size = Vector3(
				float(params.get("length", 2.0)),
				float(params.get("height", 1.0)),
				float(params.get("thickness", 0.1))
			)
			return m
		"ramp":  # 语义化 prism：坡道（v6：params 含 start_height/end_height → 手写 wedge 衔接，否则 PrismMesh 零回归）
			if params.has("start_height") or params.has("end_height"):
				return CustomMeshes.make_ramp(params)
			var m := PrismMesh.new()
			m.size = Vector3(
				float(params.get("length", 2.0)),
				float(params.get("height", 1.0)),
				float(params.get("width", 1.0))
			)
			m.left_to_right = 0.0
			return m
		"cone":
			return CustomMeshes.make_cone(params)
		"tube":
			return CustomMeshes.make_tube(params)
		"torus":
			return CustomMeshes.make_torus(params)
		"stairs":
			return CustomMeshes.make_stairs(params)
		"fence":
			return CustomMeshes.make_fence(params)
		_:
			LogHelper.error("AssetFactory: 未知 shape '%s'" % shape)
			return null


static func create_material(spec: Variant) -> Material:
	if spec == null:
		return MaterialLibrary.get_material("default")
	if spec is String:
		var s: String = spec
		if s.begins_with("res://"):
			var loaded = load(s)
			return loaded if loaded is Material else MaterialLibrary.get_material("default")
		return MaterialLibrary.get_material(s)  # 预设名（未知 → default 回退，Task 2 已测）
	if spec is Dictionary:
		var d: Dictionary = spec
		var mat := StandardMaterial3D.new()
		if d.has("color"):
			mat.albedo_color = _safe_html(String(d["color"]), Color(1, 1, 1))  # A-4：非法 hex 回退白
		mat.metallic = float(d.get("metallic", 0.0))
		mat.roughness = float(d.get("roughness", 0.7))
		if d.has("emissive"):
			mat.emission_enabled = true
			mat.emission = _safe_html(String(d["emissive"]), Color(0, 0, 0))  # A-4：非法 hex 回退黑（不发光）
		if d.has("alpha"):
			var a: float = float(d["alpha"])
			if a < 1.0:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var c: Color = mat.albedo_color
				c.a = a
				mat.albedo_color = c
		return mat
	return MaterialLibrary.get_material("default")


# A-4：Color.html 对非法 hex 返黑色 + stderr 噪声。校验合法 hex（3/4/6/8 位），非法时 warning + 回退 fallback
static func _safe_html(hex: String, fallback: Color) -> Color:
	var s := hex.strip_edges().lstrip("#")
	var ok_len := s.length() == 6 or s.length() == 8 or s.length() == 3 or s.length() == 4
	if ok_len and s.is_valid_hex_number():
		return Color.html(hex)
	LogHelper.warning("非法 hex 颜色 '%s'，回退 %s" % [hex, str(fallback)])
	return fallback


# JSON 数组 [x,y,z] → Vector3
static func _vec3(params: Dictionary, key: String, default_v: Vector3) -> Vector3:
	if not params.has(key):
		return default_v
	var arr: Variant = params[key]
	if arr is Array:
		var a := arr as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else default_v
	if arr is PackedFloat64Array:
		var a2 := arr as PackedFloat64Array
		return Vector3(a2[0], a2[1], a2[2]) if a2.size() >= 3 else default_v
	return default_v
