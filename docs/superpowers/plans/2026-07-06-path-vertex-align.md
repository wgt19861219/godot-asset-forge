# 路径顶点对齐分段（v4）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 continuous 模式加 `align_vertices` opt-in 参数（默认 false），true 时把折线每个顶点强制设为段边界，栏板在转角处自然断开不再切角；顺带激活 `_sample_continuous` 的 `vertex_d` 死代码 + 堵 v2 起漏的 spacing 过小循环爆。

**Architecture:** minimal-diff。`PathGenerator` 加 `align_vertices` 参数（sample / `_sample_continuous` / validate 三处），`_sample_continuous` 内 boundaries 生成处加 `if align_vertices:` 优先分支（每折线段独立按 spacing 切 + 段末去重）；validate 加 2 条不兼容模式报错 + spacing<_EPS 下限；forge_client `--align-vertices` + `predict_n` va 分支；plugin 透传 1 行；command_server 零改动。

**Tech Stack:** GDScript（Godot 4.6，@tool）/ Python 3（forge_client.py + pytest）/ WebSocket JSON。

## Global Constraints

- Godot 4.6.3 Forward+；缩进 = **Tab**；注释一律简体中文
- `_EPS = 1e-4`（path_generator.gd:8，F1 沿用）；`BATCH_LIMIT = 64`
- va 仅 `mode==continuous` + `spacing>0` 生效；`va+discrete` / `va+count` 报错（v2 §3.1 显式拦截原则）
- va 的 while 条件 `d < seg_end - _EPS` 保证段末长 >_EPS（va 不产生 <_EPS 段，:134 零长过滤对 va 无作用）
- 静态类 `class_name X extends RefCounted`，全局注册不 preload
- 跑 headless：`D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
- 跑 pytest：`python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `addons/asset_forge/path_generator.gd` | sample / `_sample_continuous` / validate 加 `align_vertices` + va 分支 + spacing<_EPS 下限 | Task 1 + Task 2 |
| `tests/test_path_generator.gd` | 追加 va 用例（10 例）+ spacing<_EPS 用例（2 例）| Task 1 + Task 2 |
| `tools/forge_client.py` | `--align-vertices` argparse + `build_path_payload` + `predict_n` va 分支 | Task 3 |
| `tests/test_forge_client_predict.py` | pytest predict_n va 用例（4 例）| Task 3 |
| `addons/asset_forge/asset_forge_plugin.gd` | `_handle_generate_path` 透传 `align_vertices`（1 行 + 2 处调用加实参）| Task 4 |
| `tools/forge_client.py`（`run_selftest`）| va 集成自检 | Task 4 |
| `docs/protocol.md` / `README.md` | align_vertices 字段 + 示例 + va 不产生 <_EPS 段注记 | Task 4 |

---

## Task 1: PathGenerator va 核心 + 10 例测试（TDD）

**Files:**
- Modify: `addons/asset_forge/path_generator.gd`（sample :59 / `_sample_continuous` :97 / validate :29）
- Modify: `tests/test_path_generator.gd`（追加 va 用例到 `run()` 末尾 :192 后）

**Interfaces:**
- Consumes: v2 `_sample_continuous`（seg_len / vertex_d / 段生成 :127-147）/ v2 validate
- Produces: `sample/_sample_continuous/validate` 加 `align_vertices := false` 尾参；va 分支产出 boundaries 喂段生成

- [ ] **Step 1: 追加 10 例失败测试到 `tests/test_path_generator.gd` 的 `run()` 末尾（:192 `runner.check(...默认 mode=discrete)` 之后）**

```gdscript
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
```

- [ ] **Step 2: 跑 headless 确认失败（va 分支不存在，sample 多传参数报错或返回 v2 结果）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: PathGenerator suite FAIL（va1.size()==4 实际 8/va 报错分支不存在）。

- [ ] **Step 3: 改 `path_generator.gd` 的 sample 加 align_vertices 参数（:59）**

把现有 `sample` 签名与 continuous 分支改为：
```gdscript
static func sample(
	points: Array, spacing: float, count: int, align: String,
	include_endpoints: bool, mode := "discrete", align_vertices := false
) -> Array:
	if mode == "continuous":
		return _sample_continuous(points, spacing, count, include_endpoints, align_vertices)
	var last: int = points.size() - 1
	# ...（discrete 分支不变，不传 align_vertices）
```

- [ ] **Step 4: 改 `_sample_continuous` 加 align_vertices 参数 + va 分支（:97）**

把现有 `_sample_continuous` 签名 + boundaries 生成（:97-125）改为（段生成 :127-147 不变）：
```gdscript
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
	# 段 = 相邻边界对（:127-147 不变）
	var segments: Array = []
	for i in range(boundaries.size() - 1):
		var d_start: float = float(boundaries[i])
		var d_end: float = float(boundaries[i + 1])
		var p_start := _position_at(d_start, seg_len, points, total)
		var p_end := _position_at(d_end, seg_len, points, total)
		var length: float = p_start.distance_to(p_end)
		if length < _EPS:
			continue
		var position := p_start.lerp(p_end, 0.5)
		var chord := p_end - p_start
		var yaw := rad_to_deg(atan2(-chord.z, chord.x))
		segments.append(
			{
				"position": position,
				"rotation_deg": Vector3(0.0, yaw, 0.0),
				"length": length,
				"distance": d_start
			}
		)
	return segments
```

- [ ] **Step 5: 改 `validate` 加 align_vertices 参数 + 2 条不兼容报错（:29）**

把现有 `validate` 签名加尾参，并在 `return ""`（:53）之前追加 2 条 va 校验：
```gdscript
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
```

- [ ] **Step 6: 跑 headless 确认绿（含 v1/v2/v3 零回归 + va 10 例）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`（v3 基线 179 + va 新增约 20 断言，0 failed）。

- [ ] **Step 7: Commit**

```bash
git add addons/asset_forge/path_generator.gd tests/test_path_generator.gd
git commit -m "feat: PathGenerator align_vertices va 分支 + 10 例测试（v4 Task 1）

sample/_sample_continuous/validate 加 align_vertices:=false（默认 false=v2 零回归）；
va 分支：每折线段独立按 spacing 切 + 段末去重，激活 vertex_d 死代码；
validate 加 va+discrete / va+count 报错（v2 §3.1 显式拦截原则）。
spec: docs/superpowers/specs/2026-07-06-path-vertex-align-design.md"
```

---

## Task 2: validate spacing<_EPS 下限（堵 v2 起漏的循环爆，独立健壮性 task）

**Files:**
- Modify: `addons/asset_forge/path_generator.gd`（validate :41-42 spacing 校验处）
- Modify: `tests/test_path_generator.gd`（追加 spacing<_EPS 用例）

**Interfaces:**
- Consumes: Task 1 validate（已加 align_vertices）
- Produces: validate 拦截 `spacing > 0 and spacing < _EPS`，堵 `_distances` / `_sample_continuous` 的 while 循环爆

**背景**：v2 起漏——spacing 极小（如 1e-5）但 >0 通过 validate，`while d <= total + _EPS: d += spacing` 循环 total/spacing（4/1e-5=40 万次）极慢。1 行下限堵住。是 v2 既有 bug fix（极小 spacing 从"循环爆"变 invalid_params），非真实回归。

- [ ] **Step 1: 追加失败测试到 `tests/test_path_generator.gd`（Task 1 va 用例之后）**

```gdscript
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
```

（注：GDScript 无法读私有 _EPS 常量，测试用字面量 1e-4 = PathGenerator._EPS 同值 F1）

- [ ] **Step 2: 跑 headless 确认失败（spacing<_EPS 当前不报错）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 2 个 spacing<_EPS 用例 FAIL（validate 当前返 ""）。

- [ ] **Step 3: 改 `validate` 在 has_spacing 定义后加 spacing<_EPS 下限（:41-42）**

把现有：
```gdscript
	var has_spacing: bool = spacing > 0.0
	var has_count: bool = count >= 1
	if has_spacing and has_count:
		return "spacing 与 count 只能二选一"
```
改为（在 has_spacing 后、互斥校验前插入）：
```gdscript
	var has_spacing: bool = spacing > 0.0
	var has_count: bool = count >= 1
	# v4 健壮性：spacing 过小（>0 但 <_EPS）→ invalid（堵 _distances/_sample_continuous while 循环爆）
	if has_spacing and spacing < _EPS:
		return "spacing 过小（< %s，会切极多段导致循环爆），最小 %s" % [str(_EPS), str(_EPS)]
	if has_spacing and has_count:
		return "spacing 与 count 只能二选一"
```

- [ ] **Step 4: 跑 headless 确认绿（含 Task 1 va + spacing<_EPS）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/path_generator.gd tests/test_path_generator.gd
git commit -m "fix: validate spacing<_EPS 下限堵循环爆（v4 Task 2）

spacing>0 但 <_EPS（如 1e-5）会让 _distances/_sample_continuous 的
while 循环 total/spacing 次（4/1e-5=40 万），极慢。1 行下限堵住。
v2 起漏的 bug fix（极小 spacing 从循环爆变 invalid_params）。"
```

---

## Task 3: forge_client --align-vertices + predict_n va 分支（TDD）

**Files:**
- Modify: `tools/forge_client.py`（`predict_n` :34 / `build_path_payload` :255 / `run_path` :305 / argparse :459）
- Modify: `tests/test_forge_client_predict.py`（追加 predict_n va 用例）

**Interfaces:**
- Consumes: Task 1 va 段数算法（server parity 基准）
- Produces: `predict_n(..., align_vertices=False)` va 分支；`--align-vertices` CLI；`build_path_payload` 加 `align_vertices`

- [ ] **Step 1: 追加 4 例失败 pytest 到 `tests/test_forge_client_predict.py` 末尾**

```python
def test_predict_n_va_l_shape_spacing3():
    """va L 形 spacing=3 → 4 段（与 server test_path_generator #1 parity）"""
    from forge_client import predict_n
    path = [(0, 0, 0), (4, 0, 0), (4, 0, 4)]
    assert predict_n(path, 3.0, 0, True, "continuous", align_vertices=True) == 4


def test_predict_n_va_exact_division():
    """va L 形 spacing=2 → 4 段（整除无短尾）"""
    from forge_client import predict_n
    path = [(0, 0, 0), (4, 0, 0), (4, 0, 4)]
    assert predict_n(path, 2.0, 0, True, "continuous", align_vertices=True) == 4


def test_predict_n_va_zero_length_segment():
    """va 折线含零长段 → 2 段（零长段贡献 0，与 server #8 parity）"""
    from forge_client import predict_n
    path = [(0, 0, 0), (2, 0, 0), (2, 0, 0), (4, 0, 0)]
    assert predict_n(path, 2.0, 0, True, "continuous", align_vertices=True) == 2


def test_predict_n_va_false_legacy():
    """va=False → 走 legacy（v1/v2，零回归）"""
    from forge_client import predict_n
    path = [(0, 0, 0), (4, 0, 0)]
    # v2 continuous spacing=1 total=4 → 5 点 → 4 段
    assert predict_n(path, 1.0, 0, True, "continuous", align_vertices=False) == 4
```

- [ ] **Step 2: 跑 pytest 确认失败（predict_n 不接 align_vertices / 无 va 分支）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 4 个新 test FAIL（TypeError: unexpected keyword 'align_vertices' 或返回 legacy 值）。

- [ ] **Step 3: 改 `predict_n` 加 align_vertices 参数 + va 分支（:34）**

把现有 `predict_n` 改为（在函数开头 total 计算后插入 va 分支）：
```python
def predict_n(path, spacing, count, include_endpoints, mode="discrete", align_vertices=False):
    """与 PathGenerator._distances/_sample_continuous 镜像（ε=1e-4 同步约定）。
    v4 align_vertices：每折线段 floor(seg/spacing)+(余数>eps?1:0) 之和。"""
    total = sum(_dist(p0, p1) for p0, p1 in zip(path, path[1:]))
    eps = 1e-4
    if align_vertices and mode == "continuous" and spacing and spacing > 0:
        # v4 va：每折线段独立按 spacing 切 + 短尾
        n = 0
        for p0, p1 in zip(path, path[1:]):
            seg = _dist(p0, p1)
            if seg < eps:
                continue  # 零长折线段贡献 0
            full = int(seg // spacing)
            n += full
            if seg - full * spacing > eps:
                n += 1  # 短尾段
        return n
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

- [ ] **Step 4: 加 `--align-vertices` argparse（main 函数 :459 `--mode` 之后）**

在 `--mode` 参数定义后追加：
```python
    p.add_argument(
        "--align-vertices",
        action="store_true",
        help="path 模式 continuous：顶点对齐分段（顶点=段边界，转角不切角），仅 continuous+spacing",
    )
```

- [ ] **Step 5: 改 `build_path_payload` 加 align_vertices（:285 `--mode` 处理之后）**

在 `if args.mode != "discrete": payload["mode"] = args.mode` 之后追加：
```python
    if args.align_vertices:
        payload["align_vertices"] = True
```

- [ ] **Step 6: 改 `run_path` 的 predict_n 调用加 align_vertices（:326）**

把现有：
```python
        n = predict_n(path, spacing, count, include_endpoints, args.mode)
```
改为：
```python
        n = predict_n(path, spacing, count, include_endpoints, args.mode, args.align_vertices)
```

- [ ] **Step 7: 跑 pytest 确认绿（v1/v2/v3 + v4 va 全过）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 17 passed（v1 6 + v2 5 + v3 2 + v4 4）。

- [ ] **Step 8: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_predict.py
git commit -m "feat: forge_client --align-vertices + predict_n va 分支（v4 Task 3）

--align-vertices argparse + build_path_payload 加 align_vertices；
predict_n 加 va 分支（每折线段 floor(seg/spacing)+短尾，与 server parity）；
run_path predict_n 调用透传 align_vertices。
pytest 17 passed（v1 6 + v2 5 + v3 2 + v4 4）。"
```

---

## Task 4: plugin 透传 + 文档 + selftest + 端到端

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd`（`_handle_generate_path` :200-208）
- Modify: `docs/protocol.md`（generate_path 字段加 align_vertices）
- Modify: `README.md`（--align-vertices 示例 + va 注记）
- Modify: `tools/forge_client.py`（`run_selftest` 加 va 集成用例）

**Interfaces:**
- Consumes: Task 1-3 全部产物
- Produces: plugin 透传 align_vertices 到 validate/sample；文档；selftest va 端到端

**注意**：plugin 是 EditorPlugin，headless 不加载。Task 4 验证 = 编译通过（headless 全套不回归）+ selftest 端到端。

- [ ] **Step 1: 改 `asset_forge_plugin.gd::_handle_generate_path` 透传 align_vertices（:200-208）**

把现有（:200-209）：
```gdscript
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
```
改为（加 align_vertices 读取 + 两处调用加尾参）：
```gdscript
	var include_endpoints: bool = bool(payload.get("include_endpoints", true))
	var align_vertices: bool = bool(payload.get("align_vertices", false))  # v4 新增
	var verr: String = PathGenerator.validate(
		points, spacing, count, align, include_endpoints, mode, align_vertices
	)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	var samples: Array = PathGenerator.sample(
		points, spacing, count, align, include_endpoints, mode, align_vertices
	)
```

- [ ] **Step 2: 跑 headless 确认 plugin.gd 编译无错（全套不回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`（与 Task 2 一致，无回归 = plugin.gd 编译通过；plugin 逻辑靠 Step 5 selftest 端到端）。

- [ ] **Step 3: 改 `docs/protocol.md` generate_path 章节加 align_vertices 字段**

在 generate_path 字段列表（`mode` 之后）加：
```markdown
- `align_vertices`：可选 bool（默认 false），仅 `mode=continuous` + `spacing>0` 生效。true 时折线每个顶点强制为段边界，栏板在转角处断开不再切角。`va+discrete` / `va+count` → invalid_params（count 等分边界不对齐顶点）。`include_endpoints` 在 va 下忽略（va 已保证顶点=边界）
```

并加 va 说明段（在 continuous 说明之后）：
```markdown
**align_vertices 模式（v4）**：每个折线段 `[vertex_d[i], vertex_d[i+1]]` 独立按 spacing 切，段末顶点强制为边界（去重防御浮点）。栏板在转角顶点处自然断开，不横跨转角切角。短尾保留（丢短尾=丢顶点对齐）；va 的 while `_EPS` 阈值保证每段长 >_EPS，不产生极短段。
```

- [ ] **Step 4: 改 `README.md` 路径阵列小节加 --align-vertices 示例 + 注记**

在 continuous 示例之后追加：
```markdown
# 顶点对齐分段（v4）：栏板在折线转角处断开，不切角
python tools/forge_client.py path fence --path '[[0,0,0],[4,0,0],[4,0,4]]' --spacing 3 --mode continuous --align-vertices --mat wood
```

在朝向注记段之后追加：
```markdown
**顶点对齐分段（v4 `--align-vertices`）**：仅 continuous+spacing 模式生效。开启后折线每个顶点强制为段边界，栏板在转角处自然断开（v2 等间距可能横跨转角切角）。短尾段保留（如 4m 段 spacing=3 → 一块 3m + 一块 1m 短尾）。`--count` 与 `--align-vertices` 互斥报错。
```

- [ ] **Step 5: 改 `run_selftest` 加 va 集成用例（forge_client.py，continuous undo 之后 :418）**

在 `run_selftest` 的 continuous undo 块之后、`await ws.close()` 之前插入：
```python
    # v4 generate_path continuous + align_vertices（L 路径 spacing=3 → 4 段，顶点对齐）
    va_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_va",
            "payload": {
                "shape": "wall",
                "path": [[0, 0, 0], [4, 0, 0], [4, 0, 4]],
                "spacing": 3,
                "mode": "continuous",
                "align_vertices": True,
                "material": "stone",
                "name": "st_va",
            },
        },
        4,
    )
    ok = len(va_results) == 4 and all(bool(r.get("success")) for r in va_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous + align_vertices（{len(va_results)}/4 result）")
    # undo va（同 batch_id 原子弹 4 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_va_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 4
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path va undo（freed 4）")
```

- [ ] **Step 6: 端到端集成验证（编辑器 + selftest 手测）**

启动编辑器（后台）：
```
D:\godot\Godot_v4.6.3-stable_win64.exe --editor --path D:\GitHub\godot-asset-forge "res://Demo.tscn" > /tmp/forge_v4.log 2>&1
```
等 15-20s，确认 60650 LISTENING + token。

**手测 va**（路径阵列，转角对齐）：
```
python tools/forge_client.py path fence --path '[[0,0,0],[4,0,0],[4,0,4]]' --spacing 3 --mode continuous --align-vertices --mat wood
```
Expected: `{"success": true, "results": [...], "count": 4}`，编辑器视口沿 L 路径生成 4 段 fence（3m+1m+3m+1m），转角顶点 (4,0,0) 处 fence 断开（对比不带 --align-vertices 时段 (3,6) 横跨转角切角）。

**手测 va 错误分支**：
- `--align-vertices --count 3`（无 spacing）→ invalid_params「仅 spacing 模式可用」
- `--align-vertices`（不带 --mode continuous，默认 discrete）→ invalid_params「仅 continuous 模式可用」

**手测 selftest va 集成**：
```
python tools/forge_client.py --selftest
```
Expected: 含 `generate_path continuous + align_vertices（4/4 result）` PASS + `generate_path va undo（freed 4）` PASS。

关编辑器：`taskkill //PID <PID> //F`。

- [ ] **Step 7: 跑 headless 全套确认绿（含 v1/v2/v3/v4 零回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`。

- [ ] **Step 8: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd docs/protocol.md README.md tools/forge_client.py
git commit -m "feat+docs: plugin align_vertices 透传 + 文档 + selftest va 集成（v4 Task 4）

_handle_generate_path 透传 align_vertices 到 validate/sample；
protocol.md/README 加 align_vertices 字段 + 示例 + va 短尾/转角逐顶点对齐注记；
selftest 加 continuous+va 端到端（L 路径 spacing=3 → 4 段 + undo freed 4）。
端到端手测：va fence 4 段转角断开 + count/discrete+va 报错分支全过。"
```

---

## 验收清单（全部 task 完成后）

- [ ] `tests/test_runner.gd` headless 全套 0 failed（v3 基线 179 + va 约 20 断言 + spacing<_EPS 3 断言）
- [ ] `pytest tests/test_forge_client_predict.py` 17 passed（v1 6 + v2 5 + v3 2 + v4 4）
- [ ] `path fence --mode continuous --align-vertices --spacing 3` L 路径 → 4 段 fence，转角顶点处断开
- [ ] va 不带 --mode（默认 discrete）→ invalid_params「仅 continuous 模式可用」
- [ ] va + --count（无 spacing）→ invalid_params「仅 spacing 模式可用」
- [ ] va=false / 不传 = v2 等间距行为（零回归，现有测试覆盖）
- [ ] validate spacing<_EPS（如 1e-5）→ invalid_params（堵循环爆）
- [ ] selftest 含 va 用例 PASS（4 段 + undo freed 4）
- [ ] v1/v2/v3 全部行为零回归（discrete/continuous/path JSON/path_node + v1/v2/v3 selftest）

## 已知限制（写进文档，非阻塞）

- va 仅 continuous+spacing（count/discrete 报错，v2 §3.1 显式拦截原则）
- va 短尾保留（丢短尾=丢顶点对齐）；while _EPS 阈值保证不产生 <_EPS 段
- include_endpoints 在 va 下静默忽略（冗余非冲突）
- BATCH_LIMIT 仍护段数（va 短路径不超限；超长路径 + 小 spacing 段数超 64 → invalid_params）
- fence 端柱去重（相邻段接缝 z-fighting）推 v5（独立 mesh 改造，与 va 正交）
