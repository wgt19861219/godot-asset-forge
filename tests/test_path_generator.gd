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

	# === continuous mode ===
	# count 模式 N 等长段（line total=4，count=4 → 4 段，length=total/N=1.0）
	var c1 := PathGenerator.sample(line, 0.0, 4, "path", true, "continuous")
	runner.check(c1.size() == 4, "continuous count=4 → 4 段")
	runner.check(abs(float(c1[0]["length"]) - 1.0) < 0.001, "continuous count 段长 = total/N")
	runner.check(
		abs((c1[0]["position"] as Vector3).x - 0.5) < 0.001, "continuous 段 0 中心 x=0.5"
	)
	runner.check(
		abs((c1[3]["position"] as Vector3).x - 3.5) < 0.001, "continuous 段 3 中心 x=3.5"
	)
	# continuous yaw：+X 沿 chord（line 沿 +X，chord=(1,0,0) → yaw=atan2(0,1)=0°）
	runner.check(
		abs((c1[0]["rotation_deg"] as Vector3).y - 0.0) < 0.1,
		"continuous +X 路径 yaw=0（+X 对齐 chord，与 discrete -90 差 90°）"
	)
	# L 形 continuous（转角在段接缝，非 miter）
	var cL := PathGenerator.sample(L, 0.0, 2, "path", true, "continuous")  # L total=2，2 段
	runner.check(cL.size() == 2, "continuous L count=2 → 2 段")
	runner.check(
		abs((cL[0]["rotation_deg"] as Vector3).y - 0.0) < 0.1,
		"continuous L 段 0 yaw=0（chord +X）"
	)
	runner.check(
		abs((cL[1]["rotation_deg"] as Vector3).y - (-90.0)) < 0.1,
		"continuous L 段 1 yaw=-90（chord +Z，转角在接缝）"
	)
	# spacing 模式 continuous（v1 点数 - 1）
	var cs := PathGenerator.sample(line, 1.0, 0, "path", true, "continuous")  # v1 5 点 → 4 段
	runner.check(cs.size() == 4, "continuous spacing=1 total=4 endpoints → 4 段（v1 点数 -1）")
	runner.check(
		abs(float(cs[0]["length"]) - 1.0) < 0.001, "continuous spacing 段长 = spacing"
	)
	# path 局部重合点（count 模式弧长等分，段数 = N，不受重合点影响）
	var dup := [Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 0), Vector3(4, 0, 0)]
	var cd := PathGenerator.sample(dup, 0.0, 3, "path", true, "continuous")  # total=4，3 等长段
	runner.check(cd.size() == 3, "continuous 跨局部重合点（count 模式段数 = N）")
	# === validate continuous ===
	runner.check(
		PathGenerator.validate(line, 1.0, 0, "none", true, "continuous") != "",
		"validate continuous + align=none → invalid（强制 path）"
	)
	runner.check(
		PathGenerator.validate(line, 0.0, 1, "path", true, "continuous") == "",
		"validate continuous count=1 endpoints=true 合法（与 discrete F5 不同）"
	)
	runner.check(
		PathGenerator.validate(line, 1.0, 0, "path", true, "sideways") != "",
		"validate 非法 mode → invalid"
	)
	# discrete 默认 mode（v1 调用不传 mode，零回归）
	runner.check(
		PathGenerator.validate(line, 1.0, 0, "path", true) == "",
		"validate 默认 mode=discrete（v1 零回归）"
	)
	# === v4 align_vertices（顶点对齐分段，va 仅 continuous+spacing 生效）===
	# L 形 [(0,0,0),(4,0,0),(4,0,4)]，两段各 4m，vertex_d=[0,4,8]
	var L4 := [Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 4)]
	# #1 va=true spacing=3 → boundaries [0,3,4,7,8] → 4 段（长 3/1/3/1，转角顶点 4=边界）
	var va1 := PathGenerator.sample(L4, 3.0, 0, "path", true, "continuous", true)
	runner.check(va1.size() == 4, "va L spacing=3 → 4 段（实际 %d）" % va1.size())
	runner.check(abs(float(va1[0]["length"]) - 3.0) < 0.001, "va 段 0 长 3")
	runner.check(abs(float(va1[1]["length"]) - 1.0) < 0.001, "va 段 1 长 1（短尾）")
	runner.check(abs(float(va1[2]["length"]) - 3.0) < 0.001, "va 段 2 长 3")
	runner.check(abs(float(va1[3]["length"]) - 1.0) < 0.001, "va 段 3 长 1（短尾）")
	runner.check(abs(float(va1[2]["distance"]) - 4.0) < 0.001, "va 段 2 d_start=4（转角顶点=边界）")
	# #2 va=true spacing=2 → [0,2,4,6,8] → 4 段（整除无短尾，段末去重不重复边界）
	var va2 := PathGenerator.sample(L4, 2.0, 0, "path", true, "continuous", true)
	runner.check(va2.size() == 4, "va L spacing=2 → 4 段（整除，实际 %d）" % va2.size())
	runner.check(abs(float(va2[0]["length"]) - 2.0) < 0.001, "va 整除段长 = spacing")
	runner.check(abs(float(va2[3]["distance"]) - 6.0) < 0.001, "va 整除段 3 d_start=6")
	# #3 单段 3.1m spacing=3 → [0,3,3.1] → 2 段（3 + 短尾 0.1 保留）
	var seg31 := [Vector3(0, 0, 0), Vector3(3.1, 0, 0)]
	var va3 := PathGenerator.sample(seg31, 3.0, 0, "path", true, "continuous", true)
	runner.check(va3.size() == 2, "va 单段 3.1 spacing=3 → 2 段（短尾，实际 %d）" % va3.size())
	runner.check(abs(float(va3[1]["length"]) - 0.1) < 0.001, "va 短尾段长 0.1（保留）")
	# #4 count + va=true → invalid_params
	runner.check(
		PathGenerator.validate(L4, 0.0, 3, "path", true, "continuous", true) != "",
		"validate va + count → invalid（仅 spacing 模式可用）"
	)
	# #5 discrete + va=true → invalid_params
	runner.check(
		PathGenerator.validate(L4, 1.0, 0, "path", true, "discrete", true) != "",
		"validate va + discrete → invalid（仅 continuous 模式可用）"
	)
	# #6 va=false（默认）→ = v2 continuous（L total=8 spacing=1 → 8 段，零回归）
	var va6 := PathGenerator.sample(L4, 1.0, 0, "path", true, "continuous", false)
	runner.check(va6.size() == 8, "va=false = v2（L spacing=1 → 8 段，零回归，实际 %d）" % va6.size())
	# #7 include_endpoints + va=true → 静默忽略（true/false 同结果）
	var va7b := PathGenerator.sample(L4, 3.0, 0, "path", false, "continuous", true)
	runner.check(va7b.size() == va1.size(), "va 静默忽略 include_endpoints（true/false 同段数）")
	# #8 折线含零长段 [(0,0,0),(2,0,0),(2,0,0),(4,0,0)] spacing=2 → [0,2,4] → 2 段
	var dup_va := [Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 0), Vector3(4, 0, 0)]
	var va8 := PathGenerator.sample(dup_va, 2.0, 0, "path", true, "continuous", true)
	runner.check(va8.size() == 2, "va 跨零长折线段 → 2 段（实际 %d）" % va8.size())
	runner.check(abs(float(va8[0]["length"]) - 2.0) < 0.001, "va 零长段例段 0 长 2")
	# #9 单段 0.3m spacing=0.1（浮点近似整除）→ 近似 [0,0.1,0.2,0.3] → 3 段
	var seg03 := [Vector3(0, 0, 0), Vector3(0.3, 0, 0)]
	var va9 := PathGenerator.sample(seg03, 0.1, 0, "path", true, "continuous", true)
	runner.check(va9.size() == 3, "va 浮点近似整除 0.3/0.1 → 3 段（实际 %d）" % va9.size())
	# #10 va 短路径合法（BATCH_LIMIT 在 plugin 层护，PathGenerator validate 不拦）
	runner.check(
		PathGenerator.validate(L4, 3.0, 0, "path", true, "continuous", true) == "",
		"validate va L spacing=3 合法"
	)
	# === v4 健壮性：spacing 过小（< _EPS）→ invalid（堵 v2 起漏的 while 循环爆）===
	runner.check(
		PathGenerator.validate(line, 1e-5, 0, "path", true) != "",
		"validate spacing<_EPS → invalid（堵 discrete _distances 循环爆）"
	)
	runner.check(
		PathGenerator.validate(line, 1e-5, 0, "path", true, "continuous") != "",
		"validate continuous spacing<_EPS → invalid（堵 _sample_continuous 循环爆）"
	)
	# spacing=_EPS 边界合法（< 才拦；=_EPS 切 4/1e-4=4 万段会被 plugin BATCH_LIMIT 另护）
	runner.check(
		PathGenerator.validate(line, 1e-4, 0, "path", true) == "",
		"validate spacing=_EPS 合法（边界，< 才拦）"
	)
