# 路径阵列 MVP（程序化场景生成 · 离散摆放）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Asset Forge 增加 `generate_path` 消息类型——bash 提供折线 + shape + 采样规则，插件沿路径等间距/等数量摆放 N 个 shape 节点并自动朝向切线。

**Architecture:** 方案 A（服务端展开）。新增 `PathGenerator`（纯几何静态类）+ `command_server` 加 `MSG_GENERATE_PATH` 分支（emit command_received 共享一个 batch_id）+ `plugin._on_command` 加 path 分支（parse→validate→sample→循环 place，复用 batch 语义）+ `forge_client.py` 加 path 子命令（客户端预测 n，复用 send_and_recv_batch）。

**Tech Stack:** GDScript（Godot 4.6，@tool，class_name 静态类）/ Python 3（forge_client.py + pytest）/ WebSocket JSON 协议。

## Global Constraints

- Godot 4.6.3，Forward+；缩进 = Tab；注释一律简体中文；保留 `IMPORTANT-N` / `Q-N` / `A-N` 标记惯例
- `ε = 1e-4`（米）：PathGenerator 与 forge_client.py n 预测必须同值（F1 同步约定）
- `BATCH_LIMIT = 64`：samples 超限 → `invalid_params`（复用 generate_batch 上限语义）
- 错误码不新增：path 校验失败一律归 `invalid_params` + message 承载细节；复用 `unsupported_shape` / `no_active_scene` / `parent_not_found` / `unauthorized`
- 静态类 `class_name X extends RefCounted`，不 preload 调用（全局注册）
- 跑测试：`D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`（Windows Git Bash，新 Godot 项目首跑需先 `--import`）

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `addons/asset_forge/path_generator.gd` | 新增。纯几何：parse_path / validate / sample + helpers | Task 1 |
| `tests/test_path_generator.gd` | 新增。PathGenerator 单测 + n 预测 parity 基准 | Task 1 |
| `tests/test_runner.gd` | 改。注册 PathGenerator suite | Task 1 |
| `addons/asset_forge/command_server.gd` | 改。`MSG_GENERATE_PATH` 常量 + `_handle_text` 分支 | Task 2 |
| `tests/test_command_server.gd` | 改。generate_path emit 共享 batch_id 测试 | Task 2 |
| `addons/asset_forge/asset_forge_plugin.gd` | 改。`_on_command` 加 path 分支 + `_handle_generate_path` 方法 | Task 3 |
| `tools/forge_client.py` | 改。path 子命令 + `predict_n` + `run_path` | Task 4 |
| `tests/test_forge_client_predict.py` | 新增。pytest 钉死 n 预测与 GDScript parity | Task 4 |
| `docs/protocol.md` / `README.md` | 改。generate_path 章节 + path 示例 + 朝向注记 | Task 5 |
| `tools/forge_client.py`（`run_selftest`） | 改。加 generate_path 集成自检 | Task 5 |

---

## Task 1: PathGenerator 纯几何类 + 单测

**Files:**
- Create: `addons/asset_forge/path_generator.gd`
- Create: `tests/test_path_generator.gd`
- Modify: `tests/test_runner.gd:12-15`

**Interfaces:**
- Produces: `PathGenerator.parse_path(raw: Variant) -> Dictionary{points: Array, error: String}`
- Produces: `PathGenerator.validate(points: Array, spacing: float, count: int, align: String, include_endpoints: bool) -> String`
- Produces: `PathGenerator.sample(points, spacing, count, align, include_endpoints) -> Array[{position: Vector3, rotation_deg: Vector3, distance: float}]`

- [ ] **Step 1: 写失败测试 `tests/test_path_generator.gd`**

```gdscript
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
```

- [ ] **Step 2: 跑测试确认失败（PathGenerator 类不存在 → 编译错）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_path_generator.gd`
Expected: 编译错误（"Identifier 'PathGenerator' not declared"）或 test_runner 无法注册。这是红阶段。

- [ ] **Step 3: 实现 `addons/asset_forge/path_generator.gd`**

```gdscript
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
static func validate(
	points: Array, spacing: float, count: int, align: String, include_endpoints: bool
) -> String:
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
	if has_count and count == 1 and include_endpoints:
		return "count==1 时 include_endpoints 必须为 false（含两端至少 2 个采样点）"
	return ""


# 已 valid 的输入 → 采样点列表 [{"position":Vector3,"rotation_deg":Vector3,"distance":float}, ...]
static func sample(
	points: Array, spacing: float, count: int, align: String, include_endpoints: bool
) -> Array:
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
```

- [ ] **Step 4: 注册 suite，改 `tests/test_runner.gd:11-17`**

把 `_initialize` 改为：
```gdscript
func _initialize() -> void:
	_run_suite("AssetFactory", preload("res://tests/test_asset_factory.gd").new())
	_run_suite("CustomMeshes", preload("res://tests/test_custom_meshes.gd").new())
	_run_suite("PathGenerator", preload("res://tests/test_path_generator.gd").new())
	_run_suite("ScenePlacer", preload("res://tests/test_scene_placer.gd").new())
	_run_suite("CommandServer", preload("res://tests/test_command_server.gd").new())
	print("\n=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
```

- [ ] **Step 5: 跑全套 headless 测试确认绿**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`（N = 原 116 + PathGenerator 新增约 35）。注意 PathGenerator suite 全 PASS，原有 4 suite 不回归。

- [ ] **Step 6: Commit**

```bash
git add addons/asset_forge/path_generator.gd tests/test_path_generator.gd tests/test_runner.gd
git commit -m "feat: 新增 PathGenerator 纯几何类 + 单测（路径阵列 MVP Task 1）

parse_path/validate/sample 三静态方法 + n 预测 parity 基准。
不碰场景树/AssetFactory，可独立 headless 单测。
spec: docs/superpowers/specs/2026-07-05-procedural-path-array-design.md"
```

---

## Task 2: command_server 协议层（MSG_GENERATE_PATH + 分支 + 测试）

**Files:**
- Modify: `addons/asset_forge/command_server.gd`（常量区 + `_handle_text` match）
- Modify: `tests/test_command_server.gd`（A-9 测试后、`server.stop()` 前插入）

**Interfaces:**
- Consumes: 无（command_server 保持零 domain 依赖）
- Produces: `MSG_GENERATE_PATH` 常量；`_handle_text` 收到 `generate_path` → 鉴权 → `_batch_counter += 1` → `command_received.emit(payload, batch_id, ws)`（与 generate 同形）

- [ ] **Step 1: 加常量到 `command_server.gd:22` 之后（MSG_UNDO_LAST 之后）**

```gdscript
const MSG_GENERATE_PATH := "generate_path"
```

- [ ] **Step 2: 加 `_handle_text` 分支到 `command_server.gd` 的 match 块（`MSG_GENERATE_BATCH` 之后、`MSG_UNDO_LAST` 之前）**

```gdscript
		MSG_GENERATE_PATH:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			_batch_counter += 1  # 一次 path 请求 = 一个 batch_id
			var gp: Dictionary = obj.get("payload", {})
			gp["__req_id"] = req_id
			command_received.emit(gp, _batch_counter, ws)
```

- [ ] **Step 3: 加测试到 `tests/test_command_server.gd` 的 `run()` 内，A-9 测试块（line 199-224）之后、`server.stop()`（line 227）之前**

```gdscript
	# === generate_path：emit command_received 共享同一 batch_id（与 generate 同语义）===
	recv.clear()
	ws2.send_text(
		JSON.stringify(
			{
				"type": "generate_path",
				"id": "rp",
				"payload":
					{"shape": "cylinder", "path": [[0, 0, 0], [1, 0, 0]], "count": 2, "name": "rp_test"}
			}
		)
	)
	for i in 30:
		ws2.poll()
		server.poll()
		if not recv.is_empty():
			break
		OS.delay_msec(20)
	runner.check(
		not recv.is_empty() and recv[0]["payload"].get("path") != null,
		"generate_path → command_received 含 path payload"
	)
	runner.check(int(recv[0]["batch"]) > 0, "generate_path batch_id > 0（共享 batch 语义）")
	runner.check(
		String(recv[0]["payload"].get("__req_id")) == "rp", "generate_path __req_id 透传"
	)
```

- [ ] **Step 4: 跑 headless 确认 CommandServer suite 绿**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 PASS，0 failed。新增 3 条 generate_path check 通过。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/command_server.gd tests/test_command_server.gd
git commit -m "feat: command_server 加 MSG_GENERATE_PATH 分支（路径阵列 MVP Task 2）

generate_path 镜像 generate 的鉴权 + batch_id 分配 + emit。
command_server 保持零 domain 依赖（不 preload PathGenerator）。"
```

---

## Task 3: plugin._on_command 加 path 分支

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd`（`_on_command` 加分支 + 新增 `_handle_generate_path` 方法）

**Interfaces:**
- Consumes: `PathGenerator.parse_path/validate/sample`（Task 1）；`MSG_GENERATE_PATH` emit（Task 2）；`AssetFactory.create_mesh/create_material`、`ScenePlacer.place`、`_server.send_result`、`_undo_stack`（现有）
- Produces: `_on_command` 收到含 `path` 的 payload → 调 `_handle_generate_path` → N 次 place + N 条 send_result（共享 batch_id）

**注意**：plugin 是 EditorPlugin，headless 不加载，无法单测 `_on_command`（依赖 `EditorInterface.get_edited_scene_root`）。本 task 验证靠：(1) headless 跑全套测试确认 plugin.gd 编译无错（项目导入成功）；(2) 端到端集成在 Task 5 的 selftest。

- [ ] **Step 1: 改 `_on_command`，在 undo 分支（line 73-81）之后、generate 分支（line 82）之前插入 path 分支**

把 `_on_command` 开头改为：
```gdscript
func _on_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	var req_id: String = String(payload.get("__req_id", ""))
	# undo（batch_id == -1）
	if bool(payload.get("__undo", false)):
		var ur := ScenePlacer.undo_last(_undo_stack)
		_server.send_result(
			req_id,
			bool(ur["success"]),
			{"message": "freed %d" % int(ur["freed"]), "error": String(ur["error"])},
			ws
		)
		return
	# generate_path（路径阵列，MVP）—— payload 含 path 走路径分支
	if payload.has("path"):
		_handle_generate_path(payload, batch_id, req_id, ws)
		return
	# generate（单件）
	var shape: String = String(payload.get("shape", ""))
	# ... 原 generate 分支不动
```

- [ ] **Step 2: 在 `_on_command` 之后新增 `_handle_generate_path` 方法**

```gdscript
# generate_path 编排：parse → validate → sample → 复用 place 循环（共享 batch_id，per-point 散回执）
func _handle_generate_path(
	payload: Dictionary, batch_id: int, req_id: String, ws: WebSocketPeer
) -> void:
	var parsed: Dictionary = PathGenerator.parse_path(payload.get("path", []))
	if String(parsed["error"]) != "":
		_server.send_result(
			req_id, false, {"error": "invalid_params", "message": String(parsed["error"])}, ws
		)
		return
	var points: Array = parsed["points"]
	var spacing: float = float(payload.get("spacing", 0.0))
	var count: int = int(payload.get("count", 0))
	var align: String = String(payload.get("align", "path"))
	var include_endpoints: bool = bool(payload.get("include_endpoints", true))
	var verr: String = PathGenerator.validate(points, spacing, count, align, include_endpoints)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	var samples: Array = PathGenerator.sample(points, spacing, count, align, include_endpoints)
	if samples.size() > _Server.BATCH_LIMIT:
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				"samples 上限 %d，实际 %d（缩短路径/增大 spacing/减少 count）"
				% [_Server.BATCH_LIMIT, samples.size()]
			},
			ws
		)
		return
	var shape: String = String(payload.get("shape", ""))
	var mesh = AssetFactory.create_mesh(shape, payload.get("params", {}))
	if mesh == null:
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message":
				(
					"未知 shape: %s（支持 box/cylinder/sphere/prism/wall/ramp/cone/tube/torus/stairs/fence）"
					% shape
				)
			},
			ws
		)
		return
	var material = AssetFactory.create_material(payload.get("material", null))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_server.send_result(
			req_id, false, {"error": "no_active_scene", "message": "无活动场景"}, ws
		)
		return
	var base_name: String = String(payload.get("name", ""))
	if base_name == "":
		base_name = shape
	for i in samples.size():
		var s: Dictionary = samples[i]
		var pos: Vector3 = s["position"]
		var rot: Vector3 = s["rotation_deg"]
		var place_payload := {
			"name": "%s_%d" % [base_name, i],
			"transform":
			{"position": [pos.x, pos.y, pos.z], "rotation_deg": [rot.x, rot.y, rot.z]},
			"parent": payload.get("parent", ""),
			"save": payload.get("save", false),
		}
		var r := ScenePlacer.place(root, mesh, material, place_payload, _undo_stack, batch_id)
		if bool(r["success"]):
			_server.send_result(
				req_id,
				true,
				{"node_path": String(r["node_path"]), "resource_path": String(r["resource_path"])},
				ws
			)
			if _dock:
				_dock.add_to_generated_list(
					String(place_payload["name"]), String(r["node_path"])
				)
		else:
			_server.send_result(
				req_id, false, {"error": String(r["error"]), "message": "place 失败"}, ws
			)
	EditorInterface.mark_scene_as_unsaved()
```

- [ ] **Step 3: 跑 headless 确认 plugin.gd 编译无错（项目导入成功 = 编译通过）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 PASS，0 failed。plugin.gd 改动不影响 headless 测试（plugin 不加载），但导入阶段会编译 plugin.gd——若有语法/类型错，导入阶段报错且测试可能无法跑。

- [ ] **Step 4: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd
git commit -m "feat: plugin._on_command 加 generate_path 分支（路径阵列 MVP Task 3）

_handle_generate_path：PathGenerator parse/validate/sample → 循环 ScenePlacer.place
共享 batch_id（per-point 散回执，与 generate_batch 同语义）。
集成验证在 Task 5 selftest。"
```

---

## Task 4: forge_client.py path 子命令 + n 预测单测

**Files:**
- Modify: `tools/forge_client.py`（加 `predict_n` + path 子命令参数 + `run_path` + `build_path_payload`）
- Create: `tests/test_forge_client_predict.py`

**Interfaces:**
- Consumes: `generate_path` 协议（Task 2/3）；PathGenerator.sample().size() parity 基准（Task 1）
- Produces: `forge_client.py path <shape> --path/--path-file --spacing|--count --align --no-endpoints ...`；`predict_n(path, spacing, count, include_endpoints) -> int`

- [ ] **Step 1: 写失败测试 `tests/test_forge_client_predict.py`**

```python
"""forge_client.predict_n 与 GDScript PathGenerator.sample().size() parity（F2 同步约定）。
基准来自 tests/test_path_generator.gd 的 parity 断言。"""
import math
import sys
from pathlib import Path

# 让 tests/ 能 import tools/forge_client.py
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
from forge_client import predict_n  # noqa: E402


def _dist(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def test_spacing_endpoints_exact_divisible():
    # spacing=1, total=4, endpoints → [0,1,2,3,4] = 5（与 GDScript parity 一致）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True) == 5


def test_spacing_endpoints_nondivisible():
    # spacing=3, total=4, endpoints → [0,3,4] = 3（补尾点）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, True) == 3


def test_spacing_no_endpoints():
    # spacing=3, total=4, no endpoints → [0,3] = 2
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, False) == 2


def test_spacing_endpoints_total_multiple():
    # spacing=2, total=4, endpoints → [0,2,4] = 3（整除，不补）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 2.0, 0, True) == 3


def test_count_mode():
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 0.0, 5, True) == 5
    assert predict_n(line, 0.0, 1, False) == 1


def test_multi_segment():
    # L 形 total=2，spacing=1，endpoints → [0,1,2] = 3
    L = [[0, 0, 0], [1, 0, 0], [1, 0, 1]]
    assert predict_n(L, 1.0, 0, True) == 3
```

- [ ] **Step 2: 跑测试确认失败（predict_n 未定义）**

Run: `cd D:\GitHub\godot-asset-forge && python -m pytest tests/test_forge_client_predict.py -v`
Expected: ImportError（`cannot import name 'predict_n' from 'forge_client'`）。

- [ ] **Step 3: 加 `predict_n` 到 `tools/forge_client.py`（在 SHAPES_11 常量之后，约 line 31）**

```python
def predict_n(path, spacing, count, include_endpoints):
    """与 PathGenerator._distances 镜像（F1 同步约定，ε=1e-4）。
    返回采样点数，供 send_and_recv_batch 预定接收数。"""
    total = sum(_dist(p0, p1) for p0, p1 in zip(path, path[1:]))
    eps = 1e-4
    if spacing and spacing > 0:
        distances = []
        d = 0.0
        while d <= total + eps:
            distances.append(d)
            d += spacing
        if include_endpoints and (total - distances[-1]) > eps:
            distances.append(total)
        return len(distances)
    elif count and count >= 1:
        return count
    return 0


def _dist(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)
```

并在 `forge_client.py` 顶部 import 区加 `import math`（若未有）。

- [ ] **Step 4: 跑 predict_n 测试确认绿**

Run: `cd D:\GitHub\godot-asset-forge && python -m pytest tests/test_forge_client_predict.py -v`
Expected: 6 passed。

- [ ] **Step 5: 加 path 子命令参数到 `forge_client.py` 的 `main()` argparse（约 line 208-227，在 batch 子命令参数之后）**

在 `p.add_argument("--thickness", ...)` 之后加：
```python
    # path 子命令参数
    p.add_argument("--path", default=None, help='path 模式：JSON 数组 [[x,y,z],...] 如 \'[[0,0,0],[3,0,0]]\'')
    p.add_argument("--path-file", default=None, help="path 模式：从文件读 path JSON（每点一行或 JSON 数组）")
    p.add_argument("--spacing", type=float, default=None, help="path 模式：等间距采样（与 --count 互斥）")
    p.add_argument("--count", type=int, default=None, help="path 模式：等数量采样（与 --spacing 互斥）")
    p.add_argument("--align", default="path", choices=["none", "path", "normal"], help="path 模式：朝向（默认 path）")
    p.add_argument("--no-endpoints", action="store_true", help="path 模式：不含端点（默认含）")
```

并在 `main()` 的命令分发（line 227-236）加 path 分支（在 `if args.shape == "batch":` 之前）：
```python
    if args.path is not None or args.path_file is not None:
        asyncio.run(run_path(args)); return
```

- [ ] **Step 6: 加 `build_path_payload` 和 `run_path` 到 `forge_client.py`（在 `run_batch` 之后）**

```python
def _parse_path_arg(args):
    """从 --path JSON 或 --path-file 读 path 数组，失败 → None（已打印错误）。"""
    import json as _json
    raw = None
    if args.path is not None:
        try:
            raw = _json.loads(args.path)
        except _json.JSONDecodeError as e:
            print(f"--path JSON 解析失败: {e}", file=sys.stderr)
            return None
    elif args.path_file is not None:
        try:
            raw = _json.loads(Path(args.path_file).read_text(encoding="utf-8"))
        except (OSError, _json.JSONDecodeError) as e:
            print(f"--path-file 读取/解析失败: {e}", file=sys.stderr)
            return None
    if not isinstance(raw, list) or len(raw) < 2:
        print("--path 必须是 ≥2 个点的 JSON 数组", file=sys.stderr)
        return None
    return raw


def build_path_payload(args, path):
    payload = {"shape": args.shape, "path": path}
    if args.name:
        payload["name"] = args.name
    if args.mat:
        if args.mat.startswith("{"):
            try:
                payload["material"] = json.loads(args.mat)
            except json.JSONDecodeError as e:
                print(f"--mat JSON 解析失败: {e}", file=sys.stderr)
                sys.exit(2)
        else:
            payload["material"] = args.mat
    if args.spacing is not None:
        payload["spacing"] = args.spacing
    if args.count is not None:
        payload["count"] = args.count
    if args.align != "path":
        payload["align"] = args.align
    if args.no_endpoints:
        payload["include_endpoints"] = False
    if args.parent:
        payload["parent"] = args.parent
    if args.save:
        payload["save"] = True
    params = {}
    if args.size:
        params["size"] = list(args.size)
    if args.radius is not None:
        params["radius"] = args.radius
    if args.height is not None:
        params["height"] = args.height
    if args.thickness is not None:
        params["thickness"] = args.thickness
    if params:
        payload["params"] = params
    return payload


async def run_path(args):
    """path 阵列：客户端预测 n，发 generate_path，收齐 n 条 per-point result 聚合。"""
    path = _parse_path_arg(args)
    if path is None:
        sys.exit(2)
    spacing = args.spacing if args.spacing is not None else 0.0
    count = args.count if args.count is not None else 0
    include_endpoints = not args.no_endpoints
    n = predict_n(path, spacing, count, include_endpoints)
    if n == 0:
        print("path 参数错误：需 --spacing >0 或 --count >=1（且二选一）", file=sys.stderr)
        sys.exit(2)
    if n > 64:
        print(
            f"采样点 {n} 超过 BATCH_LIMIT 64（缩短路径/增大 spacing/减少 count）",
            file=sys.stderr,
        )
        sys.exit(2)
    ws = await connect_and_handshake(args)
    payload = build_path_payload(args, path)
    results = await send_and_recv_batch(
        ws, {"type": "generate_path", "id": "r_path", "payload": payload}, n
    )
    all_ok = all(bool(r.get("success")) for r in results)
    aggregated = {"success": all_ok, "results": results, "count": n}
    print(json.dumps(aggregated, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if all_ok else 1)
```

- [ ] **Step 7: 跑 predict_n 测试再确认绿（确保 import + 改动不回归）**

Run: `cd D:\GitHub\godot-asset-forge && python -m pytest tests/test_forge_client_predict.py -v`
Expected: 6 passed。

- [ ] **Step 8: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_predict.py
git commit -m "feat: forge_client.py 加 path 子命令 + n 预测（路径阵列 MVP Task 4）

predict_n 与 PathGenerator._distances 镜像（ε=1e-4 同步约定）。
predict_n 单测（pytest）钉死与 GDScript parity。
path 子命令复用 send_and_recv_batch，零协议改动。"
```

---

## Task 5: 文档 + selftest 集成 + 端到端验证

**Files:**
- Modify: `docs/protocol.md`（加 generate_path 章节）
- Modify: `README.md`（加 path 示例 + 朝向注记）
- Modify: `tools/forge_client.py`（`run_selftest` 加 generate_path）

**Interfaces:**
- Consumes: 全部前 4 task 的产物

- [ ] **Step 1: 加 generate_path 章节到 `docs/protocol.md`（在 `## generate_batch` 之后、`## undo_last` 之前）**

```markdown
## generate_path（路径阵列离散摆放，程序化生成 MVP）

请求：
```json
{"type":"generate_path","id":"p1","payload":{
  "shape":"cylinder",
  "params":{"height":1.5,"radius":0.1},
  "material":"metal",
  "path":[[0,0,0],[3,0,0],[3,0,5]],
  "spacing":2.0,
  "align":"path",
  "include_endpoints":true,
  "name":"lamp",
  "parent":"/Root3D/Decor",
  "save":false
}}
```

- `path` 必填（≥2 点，每点 `[x,y,z]`）；`spacing` / `count` 二选一；`align` 默认 `"path"`（none/path/normal）；`include_endpoints` 默认 `true`
- **采样规则**：`spacing` = 等间距（含端点补尾点）；`count` = 等数量（含两端 N-1 等分）；`count==1` 时 `include_endpoints` 必须为 `false`（单点居中）
- **朝向**：`yaw = atan2(-tangent.x, -tangent.z)`；`none`=不转、`path`=沿切线、`normal`=切线+90°（路径前进方向左侧法线）
- **回执**：N 条独立 `generate_result` 共享同一 `req_id`（与 `generate_batch` 同语义，per-point 散）
- **undo**：所有采样点共享一个 batch_id，一条 `undo_last` 全删

错误码：path<2 点 / total_len=0 / spacing/count 缺失·非正·互斥违反 / `count==1`+endpoints / samples>BATCH_LIMIT → 一律 `invalid_params` + message；复用 `unsupported_shape` / `no_active_scene` / `parent_not_found`。
```

- [ ] **Step 2: 加 path 示例 + 朝向注记到 `README.md`**

在「快速开始」代码块（line 41-62）的 batch 示例之后、save 示例之前插入：
```markdown
# 路径阵列（沿折线摆 shape，自动朝向切线）
python tools/forge_client.py path cylinder --path '[[0,0,0],[5,0,0],[5,0,5]]' --spacing 1 --mat metal
python tools/forge_client.py path box --path '[[0,0,0],[10,0,0]]' --count 5 --mat wood
```

在「## 11 种 shape」表格之后加一节：
```markdown
## 路径阵列（程序化生成 MVP）

`path` 子命令沿折线摆放 shape：

| 参数 | 说明 |
|------|------|
| `--path '[[x,y,z],...]'` | 折线点列表（≥2 点） |
| `--path-file <file>` | 从 JSON 文件读 path |
| `--spacing <米>` | 等间距采样（与 `--count` 互斥） |
| `--count <N>` | 等数量采样（含两端 N-1 等分） |
| `--align none\|path\|normal` | 朝向：不转 / 沿切线 / 切线+90°（默认 path） |
| `--no-endpoints` | 不含端点（默认含） |

**朝向注记**：`align=path` 基于「物件正面 -Z、XZ 地平面、Y up」假设。旋转对称物件（box/cylinder/sphere/prism/cone/tube/torus）无视觉差异；**方向敏感物件**（fence/wall 长度沿 X、stairs 上行沿 +Z）用 `align=path` 朝向会偏 90°——离散摆放适合对称物件，方向敏感件的连续铺设留待 v2。
```

- [ ] **Step 3: 加 generate_path 自检到 `tools/forge_client.py` 的 `run_selftest`（在 undo_last 之后、`await ws.close()` 之前）**

把 `run_selftest` 末尾改为：
```python
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_undo"})
    ok = bool(result.get("success"))
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  undo_last")
    # generate_path（路径阵列，3 个采样点 → 3 条 per-point result）
    path_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_path",
            "payload": {
                "shape": "cylinder",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "material": "metal",
                "name": "st_path",
            },
        },
        3,
    )
    ok = len(path_results) == 3 and all(bool(r.get("success")) for r in path_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path（{len(path_results)}/3 result）")
    # undo 掉 path 生成的 3 个节点（同 batch_id，原子）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_path_undo"})
    ok = bool(result.get("success")) and int(result.get("freed", 0)) == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path undo（freed 3）")
    await ws.close()
    sys.exit(0 if all_ok else 1)
```

- [ ] **Step 4: 端到端集成验证（需编辑器跑着 + token 就绪）**

先确保有可打开的场景——源仓库是 minimal 壳默认无场景，创建 `D:\GitHub\godot-asset-forge\Demo.tscn`（最小 Node3D，让 `--editor res://Demo.tscn` 能自动打开为编辑场景）：
```
[gd_scene load_steps=1 format=3]

[node name="Root" type="Node3D"]
```

启动编辑器（后台）：
```bash
D:\godot\Godot_v4.6.3-stable_win64.exe --editor --path D:\GitHub\godot-asset-forge "res://Demo.tscn" > /tmp/forge_e2e.log 2>&1 &
```
等待 15s 让插件 + WS server 起来，确认 token：`ls C:/Users/wgt/AppData/Roaming/Godot/app_userdata/godot-asset-forge/asset_forge.token`

跑 selftest（含新 generate_path + undo）：
```bash
python D:\GitHub\godot-asset-forge\tools\forge_client.py --selftest --godot-user-dir "C:/Users/wgt/AppData/Roaming/Godot/app_userdata/godot-asset-forge"
```
Expected: 全部 PASS，含 `PASS generate_path（3/3 result）` 和 `PASS generate_path undo（freed 3）`，exit 0。

手测 path 子命令：
```bash
python tools/forge_client.py path cylinder --path '[[0,0,0],[5,0,0],[5,0,5]]' --spacing 1 --mat metal --godot-user-dir "C:/Users/wgt/AppData/Roaming/Godot/app_userdata/godot-asset-forge"
```
Expected: `{"success": true, "results": [...], "count": N}`，编辑器视口沿 L 形路径出现金属柱。结束后 `taskkill //PID <编辑器 PID> //F`。

- [ ] **Step 5: Commit**

```bash
git add docs/protocol.md README.md tools/forge_client.py
git commit -m "docs+selftest: generate_path 章节 + path 示例 + selftest 集成（路径阵列 MVP Task 5）

protocol.md 加 generate_path 完整 schema + 错误码；
README 加 path 示例 + 朝向约定注记；
run_selftest 加 generate_path 3 点 + undo 端到端自检。"
```

---

## 验收清单（全部 task 完成后）

- [ ] `tests/test_runner.gd` headless 全套 0 failed（原 116 + PathGenerator ~35 + CommandServer +3）
- [ ] `pytest tests/test_forge_client_predict.py` 6 passed
- [ ] `forge_client.py --selftest` 含 `PASS generate_path（3/3）` + `PASS generate_path undo（freed 3）`
- [ ] `forge_client.py path cylinder --path ... --spacing 1` 在编辑器视口沿路径生成节点
- [ ] `protocol.md` / `README.md` 文档与实现一致
- [ ] 全部 commit 已落（5 个 feat/docs commit）

## 已知限制（写进文档，非阻塞）

- 服务端 fatal 校验失败 → 客户端 30s 超时（与 generate_batch 一致，留 v2 terminal-flag 改造）
- `_handle_generate_path` 与单件 generate 分支有 ~15 行重复（minimal-diff，第三生成器出现时再抽 helper）
- 方向敏感物件（fence/stairs/wall）连续铺设留 v2（届时 align 改为「长度对齐切线」）
