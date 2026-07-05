# 路径阵列 continuous 模式（v2）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `generate_path` 加 `mode: "continuous"`——栏板（wall/fence）沿路径首尾相连铺满，长度自适应段长，朝向 +X 对齐段弦方向。

**Architecture:** minimal-diff 在 v1 上加 mode 分流。`PathGenerator.sample/validate` 加 `mode` 默认参数（discrete 零回归）；plugin `_handle_generate_path` 加 continuous 分支（每段独立 `create_mesh` 注入 length）+ 抽 `_place_one` helper 消除两 loop 重复；`command_server` 零改动（mode 是 payload 字段透传）；`forge_client.py` 加 `--mode` + `predict_n` 加 mode 参数（spacing 模式 −1）。

**Tech Stack:** GDScript（Godot 4.6，@tool）/ Python 3（forge_client.py + pytest）/ WebSocket JSON。

## Global Constraints

- Godot 4.6.3 Forward+；缩进 = **Tab**；注释一律简体中文
- `ε = 1e-4`（米）：PathGenerator `_EPS` 与 forge_client `predict_n` 同值（v1 F1 同步约定，v2 沿用）
- `BATCH_LIMIT = 64`；错误码归并 `invalid_params` + message，复用 `unsupported_shape` / `no_active_scene` / `parent_not_found` / `unauthorized`
- continuous 模式 align 强制 `"path"`（validate 拦截 align≠path）
- continuous 模式 shape 白名单：仅 `wall` / `fence`（length 参数名一致，无需映射表）
- 静态类 `class_name X extends RefCounted`，全局注册不 preload
- 跑测试：`D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`（Windows Git Bash）
- pytest：`python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `addons/asset_forge/path_generator.gd` | 改：`sample/validate` 加 mode 参数 + `_sample_continuous` 内部方法 | Task 1 |
| `tests/test_path_generator.gd` | 改：continuous 用例（count/spacing 段、yaw、零长段跳过、validate）| Task 1 |
| `addons/asset_forge/asset_forge_plugin.gd` | 改：`_handle_generate_path` mode 分流 + 抽 `_place_one` helper | Task 2 |
| `tools/forge_client.py` | 改：`--mode` 参数 + `build_path_payload` mode + `predict_n` mode 参数 + `run_selftest` continuous 用例 | Task 3 + Task 4 |
| `tests/test_forge_client_predict.py` | 改：predict_n mode 用例 | Task 3 |
| `tests/test_command_server.gd` | 改：mode 透传检查 | Task 4 |
| `docs/protocol.md` / `README.md` | 改：mode 字段 + continuous 示例 + fence z-fighting 注记 | Task 4 |

---

## Task 1: PathGenerator 加 mode 参数 + continuous 分支

**Files:**
- Modify: `addons/asset_forge/path_generator.gd`（`validate` / `sample` 加 mode 参数 + 新增 `_sample_continuous`）
- Modify: `tests/test_path_generator.gd`（追加 continuous 用例）

**Interfaces:**
- Consumes: v1 `parse_path` / `_position_at` / `_total_length` / `_EPS`（已就位，零改动）
- Produces: `validate(..., mode := "discrete")` / `sample(..., mode := "discrete")` 加默认参数；continuous 模式 `sample` 返回 `[{position, rotation_deg, length, distance}]`（加 `length`）；`validate` 拦 continuous+align≠path / 非法 mode；continuous count=1 合法

- [ ] **Step 1: 追加失败测试到 `tests/test_path_generator.gd` 的 `run()` 末尾**

```gdscript
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
```

- [ ] **Step 2: 跑测试确认失败（sample/validate 不接 mode 参数 → 编译错或参数不匹配）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 编译错或 PathGenerator suite FAIL（sample/validate 签名不接 mode）。

- [ ] **Step 3: 改 `path_generator.gd` 的 `validate` 加 mode 参数 + 校验**

把现有 `validate` 签名和体改为：
```gdscript
static func validate(
	points: Array, spacing: float, count: int, align: String, include_endpoints: bool, mode := "discrete"
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
	return ""
```

- [ ] **Step 4: 改 `path_generator.gd` 的 `sample` 加 mode 分流 + 新增 `_sample_continuous`**

把现有 `sample` 签名加 `mode := "discrete"`，并在函数体最前面加 continuous 分流：
```gdscript
static func sample(
	points: Array, spacing: float, count: int, align: String, include_endpoints: bool, mode := "discrete"
) -> Array:
	if mode == "continuous":
		return _sample_continuous(points, spacing, count, include_endpoints)
	# 以下 v1 discrete 逻辑不变
	var last: int = points.size() - 1
	# ...（v1 现有代码原样保留）
```

在 `sample` 之后新增 `_sample_continuous`：
```gdscript
# continuous 模式：段 = 弧长边界相邻对，每段返回 {position, rotation_deg, length, distance}
static func _sample_continuous(
	points: Array, spacing: float, count: int, include_endpoints: bool
) -> Array:
	var last: int = points.size() - 1
	var seg_len: Array = []
	var vertex_d: Array = [0.0]
	var acc := 0.0
	for i in last:
		var l: float = (points[i] as Vector3).distance_to(points[i + 1] as Vector3)
		seg_len.append(l)
		acc += l
		vertex_d.append(acc)
	var total: float = acc
	# 段边界
	var boundaries: Array = []
	if spacing > 0.0:
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
```

- [ ] **Step 5: 跑全套 headless 确认绿（含 v1 零回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`（v1 PathGenerator 34 用例 + v2 continuous 约 18 用例，无回归）。

- [ ] **Step 6: Commit**

```bash
git add addons/asset_forge/path_generator.gd tests/test_path_generator.gd
git commit -m "feat: PathGenerator 加 mode 参数 + continuous 分支（v2 Task 1）

sample/validate 加 mode 默认参数（discrete 零回归）；
_sample_continuous：段=弧长边界相邻对，每段含 length，yaw=+X 沿 chord。
spec: docs/superpowers/specs/2026-07-05-path-continuous-design.md"
```

---

## Task 2: plugin mode 分流 + 抽 `_place_one` helper

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd`（`_handle_generate_path` 加 mode 分流 + shape 白名单 + 新增 `_place_one`）

**Interfaces:**
- Consumes: Task 1 `PathGenerator.validate/sample(..., mode)`；`AssetFactory.create_mesh` / `AssetFactory.create_material` / `ScenePlacer.place` / `_server.send_result`（现有）
- Produces: `_handle_generate_path` 读 `payload.mode`（默认 discrete），continuous 分支每段独立 `create_mesh(shape, seg_params)` 注入 length；`_place_one` helper 消除两 loop 重复

**注意**：plugin 是 EditorPlugin，headless 不加载。Task 2 验证 = 编译通过（headless 全套 N passed 不回归）+ 端到端集成在 Task 4 selftest。

- [ ] **Step 1: 改 `_handle_generate_path` 加 mode 分流 + shape 白名单**

把现有 `_handle_generate_path` 改为（在 parse_path 之前加 mode 校验；validate/sample 传 mode；shape 白名单；mode 分流）：
```gdscript
func _handle_generate_path(
	payload: Dictionary, batch_id: int, req_id: String, ws: WebSocketPeer
) -> void:
	var mode := String(payload.get("mode", "discrete"))
	if mode != "discrete" and mode != "continuous":
		_server.send_result(
			req_id,
			false,
			{"error": "invalid_params", "message": "mode 必须 discrete|continuous"},
			ws
		)
		return
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
	var verr: String = PathGenerator.validate(
		points, spacing, count, align, include_endpoints, mode
	)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	var samples: Array = PathGenerator.sample(
		points, spacing, count, align, include_endpoints, mode
	)
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
	var base_params: Dictionary = payload.get("params", {})
	# continuous 模式 shape 白名单（length 沿 X）
	if mode == "continuous" and shape != "wall" and shape != "fence":
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message":
				"continuous 模式仅支持 wall/fence（length 沿 X），当前 " + shape
			},
			ws
		)
		return
	var probe_mesh = AssetFactory.create_mesh(shape, base_params)
	if probe_mesh == null:
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
	if mode == "discrete":
		for i in samples.size():
			var s: Dictionary = samples[i]
			_place_one(
				root, probe_mesh, material, base_name, i, s["position"], s["rotation_deg"],
				payload, batch_id, req_id, ws
			)
	else:  # continuous：每段独立 create_mesh（length 注入）
		for i in samples.size():
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
			var seg_mesh := AssetFactory.create_mesh(shape, seg_params)
			_place_one(
				root, seg_mesh, material, base_name, i, seg["position"], seg["rotation_deg"],
				payload, batch_id, req_id, ws
			)
	EditorInterface.mark_scene_as_unsaved()
```

- [ ] **Step 2: 新增 `_place_one` helper（在 `_handle_generate_path` 之后）**

```gdscript
# _place_one：构造 place_payload + ScenePlacer.place + send_result（discrete/continuous 共用，消除 loop 重复）
func _place_one(
	root: Node,
	mesh: Mesh,
	material: Material,
	base_name: String,
	i: int,
	pos_var: Variant,
	rot_var: Variant,
	payload: Dictionary,
	batch_id: int,
	req_id: String,
	ws: WebSocketPeer
) -> void:
	var pos: Vector3 = pos_var
	var rot: Vector3 = rot_var
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
```

- [ ] **Step 3: 跑 headless 确认 plugin.gd 编译无错（全套不回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`（与 Task 1 一致，无回归 = plugin.gd 编译通过）。

- [ ] **Step 4: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd
git commit -m "feat: plugin mode 分流 + _place_one helper（v2 Task 2）

_handle_generate_path 加 mode（discrete/continuous）分流；
continuous：shape 白名单 wall/fence + 每段独立 create_mesh 注入 length；
_place_one helper 消除两 loop 重复（顺便解 v1 F7 一半）。
集成验证在 Task 4 selftest。"
```

---

## Task 3: forge_client --mode + predict_n mode 参数

**Files:**
- Modify: `tools/forge_client.py`（`predict_n` 加 mode 参数 + `--mode` argparse + `build_path_payload` mode + `run_path` 传 mode）
- Modify: `tests/test_forge_client_predict.py`（mode 用例）

**Interfaces:**
- Consumes: Task 1/2 generate_path continuous 协议；v1 `predict_n` 公式
- Produces: `predict_n(path, spacing, count, include_endpoints, mode="discrete")`（spacing 模式 continuous = v1−1，count/discrete 不变）；`forge_client.py path ... --mode continuous`

- [ ] **Step 1: 追加失败测试到 `tests/test_forge_client_predict.py`**

```python
def test_continuous_count_unchanged():
    # count 模式 continuous = N（同 v1）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 0.0, 5, True, "continuous") == 5


def test_continuous_spacing_minus_one():
    # spacing 模式 continuous = v1 点数 - 1（v1=5 点 → 4 段）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True, "continuous") == 4


def test_continuous_spacing_no_endpoints():
    # v1 spacing=3 no endpoints = [0,3] = 2 点 → continuous = 1 段
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, False, "continuous") == 1


def test_discrete_default_mode_zero_regression():
    # 不传 mode，默认 discrete = v1 行为（v1 6 pytest 零回归）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True) == 5
    assert predict_n(line, 0.0, 5, True) == 5


def test_continuous_multi_segment():
    # L 形 total=2，spacing=1 endpoints → v1 3 点 → continuous 2 段
    L = [[0, 0, 0], [1, 0, 0], [1, 0, 1]]
    assert predict_n(L, 1.0, 0, True, "continuous") == 2
```

- [ ] **Step 2: 跑测试确认失败（predict_n 不接 mode）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 5 个新 test FAIL（`predict_n() takes 4 positional arguments but 5 were given`）。

- [ ] **Step 3: 改 `forge_client.py` 的 `predict_n` 加 mode 参数**

把现有 `predict_n` 改为：
```python
def predict_n(path, spacing, count, include_endpoints, mode="discrete"):
    """与 PathGenerator._distances 镜像（ε=1e-4 同步约定）。
    continuous 模式 spacing：N 点 → N-1 段；count/discrete 不变。"""
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
        n = len(distances)
        if mode == "continuous":
            n = max(0, n - 1)
        return n
    elif count and count >= 1:
        return count
    return 0
```

- [ ] **Step 4: 加 `--mode` argparse 参数到 `main()`（在 `--no-endpoints` 之后）**

```python
    p.add_argument(
        "--mode",
        default="discrete",
        choices=["discrete", "continuous"],
        help="path 模式：discrete（默认，等间距独立物件）/ continuous（栏板铺满）",
    )
```

- [ ] **Step 5: `build_path_payload` 加 mode 字段（在 `if args.no_endpoints:` 块之后）**

```python
    if args.mode != "discrete":
        payload["mode"] = args.mode
```

- [ ] **Step 6: `run_path` 调 `predict_n` 传 mode（找到现有 `n = predict_n(path, spacing, count, include_endpoints)` 改为）**

```python
    n = predict_n(path, spacing, count, include_endpoints, args.mode)
```

- [ ] **Step 7: 跑 pytest 确认绿（v1 + v2 全过）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 11 passed（v1 6 + v2 5）。

- [ ] **Step 8: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_predict.py
git commit -m "feat: forge_client --mode + predict_n mode 参数（v2 Task 3）

predict_n 加 mode 默认参数（discrete 零回归；continuous spacing -1）；
--mode argparse + build_path_payload mode 字段。
pytest 11 passed（v1 6 + v2 5）。"
```

---

## Task 4: command_server 透传测试 + 文档 + selftest 集成

**Files:**
- Modify: `tests/test_command_server.gd`（generate_path 测试加 mode 透传）
- Modify: `docs/protocol.md`（generate_path 章节加 mode 字段）
- Modify: `README.md`（continuous 示例 + fence z-fighting 注记）
- Modify: `tools/forge_client.py`（`run_selftest` 加 continuous wall 用例）

**Interfaces:**
- Consumes: Task 1-3 全部产物

- [ ] **Step 1: 改 `tests/test_command_server.gd` 的 generate_path 测试块，加 mode 透传检查**

在现有 generate_path 测试块（发 `{"type": "generate_path", "id": "rp", "payload": {"shape": "cylinder", "path": ..., "count": 2, "name": "rp_test"}}`）之后追加一个带 mode 的检查：
```gdscript
	# === generate_path mode 字段透传（command_server 零改动验证）===
	recv.clear()
	ws2.send_text(
		JSON.stringify(
			{
				"type": "generate_path",
				"id": "rpm",
				"payload":
					{"shape": "wall", "path": [[0, 0, 0], [4, 0, 0]], "count": 2, "mode": "continuous"}
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
		not recv.is_empty() and String(recv[0]["payload"].get("mode", "")) == "continuous",
		"generate_path mode 字段透传（command_server 零改动）"
	)
```

- [ ] **Step 2: 改 `docs/protocol.md` 的 generate_path 章节，加 mode 字段说明**

在 generate_path 章节的字段列表中加（在 `include_endpoints` 之后）：
```markdown
- `mode`：`"discrete"`（默认，v1 等间距独立物件）或 `"continuous"`（栏板首尾相连铺满，仅 wall/fence，length 自适应段长，align 强制 path）
```

并在章节末尾加一段 continuous 说明：
```markdown
**continuous 模式**：栏板（wall/fence）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱重合 z-fighting 为 preview 级瑕疵（v3 去重）。
```

- [ ] **Step 3: 改 `README.md` 加 continuous 示例 + fence z-fighting 注记**

在「路径阵列」小节的示例代码块追加：
```markdown
# continuous 模式（栏板铺满）
python tools/forge_client.py path wall --path '[[0,0,0],[5,0,0],[5,0,5]]' --mode continuous --count 5 --mat stone
python tools/forge_client.py path fence --path '[[0,0,0],[10,0,0]]' --mode continuous --spacing 2 --mat wood
```

在「朝向注记」段落之后追加：
```markdown
**continuous 模式**：栏板（wall/fence）沿路径首尾相连铺满，length 自适应段长，仅支持 wall/fence（length 沿 X）。fence 段接缝端柱重合会 z-fighting（preview 级，生产用 discrete 或待 v3 去重）。
```

- [ ] **Step 4: 改 `tools/forge_client.py` 的 `run_selftest` 加 continuous wall 用例**

在现有 `generate_path undo` 自检之后、`await ws.close()` 之前插入：
```python
    # generate_path continuous（wall 沿 L 路径铺满，N 段 → N 条 per-point result）
    cont_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_cont",
            "payload": {
                "shape": "wall",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "material": "stone",
                "name": "st_cont",
            },
        },
        3,
    )
    ok = len(cont_results) == 3 and all(bool(r.get("success")) for r in cont_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous（{len(cont_results)}/3 result）")
    # undo continuous（同 batch_id 原子弹 3 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_cont_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous undo（freed 3）")
```

- [ ] **Step 5: 跑 headless 全套确认绿（含 command_server mode 透传 + v1 零回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`（含新 mode 透传 check）。

- [ ] **Step 6: 端到端集成验证（编辑器 + selftest）**

创建 `D:\GitHub\godot-asset-forge\Demo.tscn`（若已存在跳过；最小 Node3D）：
```
[gd_scene load_steps=1 format=3]

[node name="Root" type="Node3D"]
```

后台启动编辑器（`run_in_background: true`，**不要** `| tail` 管道）：
```
D:\godot\Godot_v4.6.3-stable_win64.exe --editor --path D:\GitHub\godot-asset-forge "res://Demo.tscn" > /tmp/forge_v2.log 2>&1
```
等 15-20s，确认 `netstat -ano | grep 60650` LISTENING + token 存在 `C:/Users/wgt/AppData/Roaming/Godot/app_userdata/godot-asset-forge/asset_forge.token`。

跑 selftest（含新 continuous wall + undo）：
```
python D:\GitHub\godot-asset-forge\tools\forge_client.py --selftest
```
Expected: 全部 PASS，含 `PASS generate_path continuous（3/3 result）` 和 `PASS generate_path continuous undo（freed 3）`，exit 0。

手测 continuous 命令：
```
python tools/forge_client.py path wall --path '[[0,0,0],[5,0,0],[5,0,5]]' --mode continuous --count 5 --mat stone
python tools/forge_client.py path fence --path '[[0,0,0],[10,0,0]]' --mode continuous --spacing 2 --mat wood
```
Expected: `{"success": true, "results": [...], "count": N}`，编辑器视口沿路径出现连续墙/栅栏（fence 接缝端柱 z-fighting 符合预期）。

关编辑器：`tasklist | grep -i godot` 找 PID，`taskkill //PID <PID> //F`。

- [ ] **Step 7: Commit**

```bash
git add tests/test_command_server.gd docs/protocol.md README.md tools/forge_client.py
git commit -m "feat+selftest: continuous mode 透传测试 + 文档 + selftest 集成（v2 Task 4）

command_server mode 透传测试（零改动验证）；
protocol.md / README 加 continuous 章节 + fence z-fighting 注记；
run_selftest 加 continuous wall + undo 端到端自检。
selftest 全 PASS（含 continuous 3/3 + undo freed 3）。"
```

---

## 验收清单（全部 task 完成后）

- [ ] `tests/test_runner.gd` headless 全套 0 failed（v1 153 + Task 1 continuous 约 18 + Task 4 mode 透传 1）
- [ ] `pytest tests/test_forge_client_predict.py` 11 passed（v1 6 + v2 5）
- [ ] `forge_client.py --selftest` 含 `PASS generate_path continuous（3/3）` + `PASS generate_path continuous undo（freed 3）`
- [ ] `path wall --mode continuous --count N` 在编辑器视口沿路径生成连续墙
- [ ] `path fence --mode continuous --spacing N` 沿路径生成栅栏（接缝 z-fighting 符合预期）
- [ ] `protocol.md` / `README.md` 文档与实现一致
- [ ] v1 全部行为零回归（discrete 默认 mode + v1 selftest + v1 pytest）

## 已知限制（写进文档，非阻塞）

- fence continuous 段接缝端柱 z-fighting（preview 级，v3 顶点对齐分段 + 端柱去重）
- mesh 缓存未优化（count 模式 length 全同可共享，N<64 可忽略）
- probe_mesh continuous 下创建后丢弃（RefCounted 释放）
- continuous 仅 wall/fence（ramp/box 留 v3，ramp length 沿 X 零改动仅扩白名单）
