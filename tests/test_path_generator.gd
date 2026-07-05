extends RefCounted
## PathGenerator 纯几何单测（parse_path / validate / sample）+ n 预测 parity 基准。


func run(runner) -> void:
	# === parse_path ===
	var ok := PathGenerator.parse_path([[0, 0, 0], [1, 0, 0]])
	runner.check(ok["error"] == "" and ok["points"].size() == 2, "parse_path 合法 2 点")
	runner.check(
		(ok["points"][0] as Vector3).is_equal_approx(Vector3(0, 0, 0)), "parse_path → Vector3"
	)
	runner.check(
		PathGenerator.parse_path("not_array")["error"] != "", "parse_path 非数组 → error"
	)
	runner.check(
		PathGenerator.parse_path([[0, 0, 0]])["error"] != "", "parse_path <2 点 → error"
	)
	runner.check(
		PathGenerator.parse_path([[0, 0, 0], [1, 2]])["error"] != "", "parse_path 元素 <3 → error"
	)

	# === validate ===
	var line := [Vector3(0, 0, 0), Vector3(4, 0, 0)]  # total=4
	runner.check(PathGenerator.validate(line, 1.0, 0, "path", true) == "", "validate 合法 spacing")
	runner.check(PathGenerator.validate(line, 0.0, 5, "path", true) == "", "validate 合法 count")
	runner.check(
		PathGenerator.validate(line, 1.0, 5, "path", true) != "", "validate spacing+count 互斥"
	)
	runner.check(PathGenerator.validate(line, 0.0, 0, "path", true) != "", "validate 都不给")
	runner.check(PathGenerator.validate(line, -1.0, 0, "path", true) != "", "validate spacing<=0")
	runner.check(
		PathGenerator.validate(line, 0.0, 0, "sideways", true) != "", "validate 非法 align"
	)
	var coincident := [Vector3(1, 1, 1), Vector3(1, 1, 1)]
	runner.check(
		PathGenerator.validate(coincident, 1.0, 0, "path", true) != "", "validate 所有点重合"
	)
	runner.check(
		PathGenerator.validate(line, 0.0, 1, "path", true) != "",
		"validate count=1+endpoints → invalid（F5）"
	)
	runner.check(
		PathGenerator.validate(line, 0.0, 1, "path", false) == "",
		"validate count=1 endpoints=false 合法（F5）"
	)

	# === sample：spacing 模式 ===
	var s1 := PathGenerator.sample(line, 1.0, 0, "path", true)  # [0,1,2,3,4] = 5
	runner.check(s1.size() == 5, "sample spacing=1 total=4 endpoints → 5 点")
	runner.check(
		(s1[0]["position"] as Vector3).is_equal_approx(Vector3(0, 0, 0)), "sample 首点"
	)
	runner.check(
		(s1[4]["position"] as Vector3).is_equal_approx(Vector3(4, 0, 0)), "sample 末点"
	)
	runner.check(
		abs((s1[2]["position"] as Vector3).x - 2.0) < 0.001, "sample 中点 x≈2"
	)

	# === sample：count 模式（含两端）===
	var s2 := PathGenerator.sample(line, 0.0, 3, "path", true)  # [0,2,4] = 3
	runner.check(s2.size() == 3, "sample count=3 endpoints → 3 点")
	runner.check(
		abs((s2[1]["position"] as Vector3).x - 2.0) < 0.001, "sample count=3 中点 x≈2"
	)

	# === sample：count 模式（不含两端，居中）===
	var s3 := PathGenerator.sample(line, 0.0, 2, "path", false)  # step=2 → [1,3]
	runner.check(s3.size() == 2, "sample count=2 no endpoints → 2 点")
	runner.check(
		abs((s3[0]["position"] as Vector3).x - 1.0) < 0.001, "sample count=2 居中首点 x≈1"
	)

	# === sample：count=1 居中 ===
	var s4 := PathGenerator.sample(line, 0.0, 1, "path", false)
	runner.check(s4.size() == 1, "sample count=1 → 1 点")
	runner.check(
		abs((s4[0]["position"] as Vector3).x - 2.0) < 0.001, "sample count=1 居中 x≈2"
	)

	# === sample：切线（直线 +X → yaw = atan2(-1, 0) = -90°）===
	runner.check(
		abs((s1[1]["rotation_deg"] as Vector3).y - (-90.0)) < 0.1,
		"sample 直线切线 yaw=-90（沿 +X）"
	)

	# === sample：转角 miter（L 形 [0,0,0]→[1,0,0]→[1,0,1]）===
	var L := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)]  # total=2
	var sL := PathGenerator.sample(L, 0.0, 3, "path", true)  # [0,1,2]，顶点 1（d=1）是转角
	runner.check(sL.size() == 3, "sample L 形 count=3 → 3 点")
	# a=(1,0,0) b=(0,0,1) bisect=(1,0,1).normalized ≈ (0.707,0,0.707)
	# yaw = atan2(-0.707, -0.707) = -135°
	var corner_yaw: float = (sL[1]["rotation_deg"] as Vector3).y
	runner.check(
		abs(corner_yaw - (-135.0)) < 0.1,
		"sample L 形转角 miter yaw=-135（实际 %.2f）" % corner_yaw
	)

	# === sample：180° 折返（a ≈ -b → 回退入边，F3）===
	var U := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 0)]  # a=(1,0,0) b=(-1,0,0)
	var sU := PathGenerator.sample(U, 0.0, 3, "path", true)
	var fold_yaw: float = (sU[1]["rotation_deg"] as Vector3).y
	runner.check(
		abs(fold_yaw - (-90.0)) < 0.1,
		"sample 180° 折返回入边 yaw=-90（实际 %.2f）" % fold_yaw
	)

	# === sample：align 映射 ===
	var s_none := PathGenerator.sample(line, 1.0, 0, "none", true)
	runner.check(
		(s_none[0]["rotation_deg"] as Vector3) == Vector3.ZERO, "sample align=none → ZERO"
	)
	var s_normal := PathGenerator.sample(line, 1.0, 0, "normal", true)
	# 直线 yaw=-90，normal = -90+90 = 0
	runner.check(
		abs((s_normal[1]["rotation_deg"] as Vector3).y - 0.0) < 0.1,
		"sample align=normal → yaw+90=0（直线 +X）"
	)

	# === n 预测 parity 基准（与 tests/test_forge_client_predict.py 同步，F2）===
	runner.check(
		PathGenerator.sample(line, 1.0, 0, "path", true).size() == 5,
		"parity: spacing=1 total=4 endpoints → 5"
	)
	runner.check(
		PathGenerator.sample(line, 2.0, 0, "path", true).size() == 3,
		"parity: spacing=2 total=4 endpoints → 3"
	)
	runner.check(
		PathGenerator.sample(line, 3.0, 0, "path", true).size() == 3,
		"parity: spacing=3 total=4 endpoints → 3（补尾点）"
	)
	runner.check(
		PathGenerator.sample(line, 3.0, 0, "path", false).size() == 2,
		"parity: spacing=3 total=4 no endpoints → 2"
	)
