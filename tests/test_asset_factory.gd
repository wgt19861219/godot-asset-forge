extends RefCounted
## AssetFactory + MaterialLibrary 单测。
## Task 2 写材质断言；Task 4 在 run() 末尾追加 shape 断言。


func run(runner) -> void:
	# === 材质（Task 2）===
	var names := [
		"wood", "metal", "stone", "glass", "gold", "coral", "sand", "seaweed", "water", "default"
	]
	for n in names:
		var mat := MaterialLibrary.get_material(n)
		runner.check(mat != null, "MaterialLibrary.get_material('%s') 非 null" % n)
		runner.check(
			mat is StandardMaterial3D, "MaterialLibrary.get_material('%s') 是 StandardMaterial3D" % n
		)
	# 颜色抽检（spec §13-Q10）
	var wood := MaterialLibrary.get_material("wood")
	runner.check_approx(wood.albedo_color.r, 0x8B / 255.0, 0.02, "wood albedo.r ≈ #8B5A2B")
	var gold := MaterialLibrary.get_material("gold")
	runner.check_approx(gold.metallic, 1.0, 0.001, "gold metallic = 1.0")
	var sand := MaterialLibrary.get_material("sand")
	runner.check_approx(sand.roughness, 0.95, 0.001, "sand roughness = 0.95")
	# 透明材质 A4
	var glass := MaterialLibrary.get_material("glass")
	runner.check(
		glass.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "glass transparency = ALPHA (A4)"
	)
	runner.check_approx(glass.albedo_color.a, 0.3, 0.001, "glass alpha = 0.3")
	var water := MaterialLibrary.get_material("water")
	runner.check(
		water.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "water transparency = ALPHA (A4)"
	)
	runner.check_approx(water.albedo_color.a, 0.5, 0.001, "water alpha = 0.5")
	# 未知预设回退 default
	var unknown := MaterialLibrary.get_material("nonexistent")
	runner.check(unknown != null, "未知预设回退 default 非 null")
	runner.check_approx(unknown.roughness, 0.7, 0.001, "default roughness = 0.7 (fallback)")
	# 大小写不敏感（Task 2 review Minor 补测）
	var up := MaterialLibrary.get_material("WOOD")
	runner.check(
		up != null and absf(up.albedo_color.r - wood.albedo_color.r) < 0.02,
		"get_material 大小写不敏感（WOOD == wood）"
	)
	# === shape 断言（Task 4 追加）===
	var shapes := {
		"box": {"size": [2.0, 1.5, 1.2]},
		"cylinder": {"height": 1.0, "radius": 0.5},
		"sphere": {"radius": 0.5},
		"prism": {"size": [1.0, 1.0, 1.0]},
		"wall": {"length": 2.0, "height": 1.0, "thickness": 0.1},
		"ramp": {"length": 2.0, "height": 1.0, "width": 1.0},
		"cone": {"height": 1.0, "radius": 0.5},
		"tube": {"height": 1.0, "radius": 0.5, "thickness": 0.1},
		"torus": {"major_radius": 0.5, "minor_radius": 0.2},
		"stairs": {"steps": 5},
		"fence": {"length": 3.0, "height": 1.2},
	}
	for shape in shapes:
		var mesh: Mesh = AssetFactory.create_mesh(shape, shapes[shape])
		runner.check(mesh != null, "create_mesh('%s') 非 null" % shape)
	# box 尺寸透传
	var boxm: BoxMesh = AssetFactory.create_mesh("box", {"size": [2.0, 1.5, 1.2]})
	runner.check(boxm.size.is_equal_approx(Vector3(2.0, 1.5, 1.2)), "box size 透传 = [2,1.5,1.2]")
	# 未知 shape 返回 null
	runner.check(AssetFactory.create_mesh("pyramid", {}) == null, "未知 shape 'pyramid' 返回 null")
	# create_material 四来源
	runner.check(AssetFactory.create_material("wood") != null, "create_material('wood') 预设名")
	runner.check(AssetFactory.create_material(null) != null, "create_material(null) → default")
	var custom := AssetFactory.create_material({"color": "FF0000", "metallic": 0.5})
	runner.check(custom is StandardMaterial3D, "create_material(dict) 自定义 StandardMaterial3D")
	runner.check_approx(
		(custom as StandardMaterial3D).metallic, 0.5, 0.001, "custom metallic = 0.5"
	)
	runner.check_approx(
		(custom as StandardMaterial3D).albedo_color.r, 1.0, 0.02, "custom albedo.r = #FF0000"
	)
	# A-4：非法 hex 颜色回退白（非纯黑），不静默返 (0,0,0) + stderr 噪声
	var bad_color := AssetFactory.create_material({"color": "not_a_color"})
	runner.check(bad_color is StandardMaterial3D, "非法 hex 仍返回 StandardMaterial3D（A-4）")
	if bad_color is StandardMaterial3D:
		runner.check(
			(bad_color as StandardMaterial3D).albedo_color.r > 0.9,
			"非法 hex albedo.r 回退白 >0.9（A-4，不返纯黑 0）"
		)
		runner.check(
			(bad_color as StandardMaterial3D).albedo_color.g > 0.9, "非法 hex albedo.g 回退白 >0.9（A-4）"
		)
	# v6 ramp 分流（params 含 start_height/end_height → make_ramp ArrayMesh，否则 PrismMesh）
	var ramp_handmade = AssetFactory.create_mesh("ramp", {"start_height": 0.5, "end_height": 1.0, "length": 2.0, "width": 1.0})
	runner.check(ramp_handmade is ArrayMesh, "create_mesh('ramp', {start_height}) → ArrayMesh（make_ramp 手写）")
	var ramp_default = AssetFactory.create_mesh("ramp", {"length": 2.0, "height": 1.0, "width": 1.0})
	runner.check(ramp_default is PrismMesh, "create_mesh('ramp', {}) → PrismMesh（现状零回归）")
