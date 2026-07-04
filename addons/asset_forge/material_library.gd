# material_library.gd
# 10 个预设 StandardMaterial3D（水族馆主题，spec §7 / §13-Q10）
@tool
class_name MaterialLibrary
extends RefCounted

# hex 颜色 + PBR 参数；alpha < 1 时设透明（A4）
const _PRESETS: Dictionary = {
	"wood":    {"hex": "8B5A2B", "metallic": 0.0, "roughness": 0.8},
	"metal":   {"hex": "B0B0B0", "metallic": 1.0, "roughness": 0.4},
	"stone":   {"hex": "808080", "metallic": 0.0, "roughness": 0.9},
	"glass":   {"hex": "88CCEE", "metallic": 0.0, "roughness": 0.1, "alpha": 0.3},
	"gold":    {"hex": "FFD700", "metallic": 1.0, "roughness": 0.3},
	"coral":   {"hex": "FF7F50", "metallic": 0.0, "roughness": 0.7},
	"sand":    {"hex": "C2B280", "metallic": 0.0, "roughness": 0.95},
	"seaweed": {"hex": "2E8B57", "metallic": 0.0, "roughness": 0.8},
	"water":   {"hex": "1E90FF", "metallic": 0.0, "roughness": 0.2, "alpha": 0.5},
	"default": {"hex": "FFFFFF", "metallic": 0.0, "roughness": 0.7},
}

static func get_material(name: String) -> StandardMaterial3D:
	var key := name.to_lower()
	if not _PRESETS.has(key):
		LogHelper.warning("MaterialLibrary: 未知预设 '%s'，回退 default" % name)
		key = "default"
	return _build(_PRESETS[key])

static func _build(spec: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.html(spec.get("hex", "FFFFFF"))
	mat.metallic = float(spec.get("metallic", 0.0))
	mat.roughness = float(spec.get("roughness", 0.7))
	var alpha: float = float(spec.get("alpha", 1.0))
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var c: Color = mat.albedo_color
		c.a = alpha
		mat.albedo_color = c
	return mat
