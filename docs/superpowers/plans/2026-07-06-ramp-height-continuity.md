# v6 ramp continuous 接缝高度衔接 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解 continuous 模式 ramp 相邻段接缝高度台阶（折线/直线都解，v5 留的已知局限），支持下降（rise<0）。

**Architecture:** minimal-diff。`CustomMeshes.make_ramp` 手写 wedge（8 顶点 6 面，start_height/end_height，无 sign 分支——斜顶法线公式自动 Y+）+ `PathGenerator._compute_seg_heights` 纯函数（弧长基础，rise 符号分支：上升 0→rise / 下降 |rise|→0 递减）+ `asset_factory` ramp 分流（params 含 start_height/end_height → 手写，否则 PrismMesh 零回归）+ placement continuous 注入（`_total_length(points)` + 循环外算 heights）。

**Tech Stack:** GDScript（Godot 4.6 `@tool`，Tab 缩进）/ Python 3（`tools/forge_client.py` selftest）/ WebSocket JSON。

## Global Constraints

- Godot 4.6.3 Forward+，GDScript，**缩进 = Tab**，注释简体中文，保留 `IMPORTANT-N` / `Q-N` / `A-N` / `I-3` / `A3` 标记
- **make_ramp 仍烘焙单 ArrayMesh（单 surface）**——CLAUDE.md 不变量 7 / A3。6 面进同一 SurfaceTool 再 `commit()`
- **单件/discrete ramp 字节级零回归**——params 不含 start_height/end_height → PrismMesh 完全不动
- **`_compute_seg_heights` 用弧长**（`samples[i]["distance"]` + `samples[i+1]["distance"]` 衔接，末段 total_len），**不用 `seg["length"]` 弦长**（CRITICAL 2）
- **斜顶 set_normal `(sh − eh, length, 0).normalized()`** Y 分量恒 +length > 0（朝上），无论上升（sh<eh）/下降（sh>eh）——无 sign 分支
- **6 面绕序统一 _add_box 约定**（几何法线朝楔形内，set_normal 朝外），F5 实测验证可见性（完成后手测段）
- **make_ramp start_height/end_height ≥ 0**（placement 保证，rise<0 下降时 |rise| 递减注入正高度，楔形朝上——§2 物理修正）
- `_EPS = 1e-4`，`BATCH_LIMIT = 64`
- 当前分支 `feature/ramp-height-continuity`（spec `303995c`，从 master `66a21db` 分出）。本仓库无 remote（纯本地）

## File Structure

| 文件 | 改动 | 责任 |
|------|------|------|
| `addons/asset_forge/path_generator.gd` | 新增 `_compute_seg_heights` 纯函数 | 弧长高度分配（rise 符号分支） |
| `addons/asset_forge/custom_meshes.gd` | 新增 `make_ramp` | wedge 几何（8 顶点 6 面，start_height/end_height） |
| `addons/asset_forge/asset_factory.gd:40-48` | ramp 分流 | params 含 start_height/end_height → make_ramp，否则 PrismMesh |
| `addons/asset_forge/asset_forge_plugin.gd:289-314` | continuous 分支加 `elif shape == "ramp"` | 高度注入（`_total_length` + `_compute_seg_heights`） |
| `tests/test_path_generator.gd` | 4 例 `_compute_seg_heights` 单测 | 弧长衔接/首尾/下降/折线弦长<弧长 |
| `tests/test_custom_meshes.gd` | make_ramp A3 + 斜顶法线单测 | 结构 + 法线方向 |
| `tests/test_asset_factory.gd` | ramp 分流 2 例 | ArrayMesh vs PrismMesh |
| `tools/forge_client.py` | selftest 加 v6 continuous ramp L 路径 | 端到端折线 visual |
| `docs/protocol.md` / `README.md` / `docs/shapes-reference.md` | ramp 接缝 v5 局限 → v6 已解 + 补参数 | 文档同步 |

---

### Task 1: `_compute_seg_heights` 纯函数 + 4 例单测

**Files:**
- Modify: `addons/asset_forge/path_generator.gd`（新增 `_compute_seg_heights`，放 `_total_length` 附近）
- Test: `tests/test_path_generator.gd`（`run(runner)` 末尾追加 4 例）

**Interfaces:**
- Produces: `PathGenerator._compute_seg_heights(samples: Array, total_len: float, rise: float) -> Array`（返 `[{start_h: float, end_h: float}, ...]`，段 i end_h == 段 i+1 start_h）

- [ ] **Step 1: 加 4 例单测（RED）**

在 `tests/test_path_generator.gd` 的 `run(runner)` 末尾（`validate spacing=_EPS 合法` 那条 `runner.check(...)` 之后）追加：

```gdscript
	# === v6 _compute_seg_heights（continuous ramp 高度衔接，弧长基础）===
	# #1 等长 3 段上升（d: 0/3/6/9，rise=3）→ [{0,1},{1,2},{2,3}]
	var hs1 := PathGenerator._compute_seg_heights(
		[{"distance": 0.0, "length": 3.0}, {"distance": 3.0, "length": 3.0}, {"distance": 6.0, "length": 3.0}],
		9.0, 3.0
	)
	runner.check(hs1.size() == 3, "_compute_seg_heights #1 等长 3 段 → 3 项")
	runner.check(abs(float(hs1[0]["start_h"]) - 0.0) < 0.001, "_compute_seg_heights #1 首段 start=0")
	runner.check(abs(float(hs1[0]["end_h"]) - 1.0) < 0.001, "_compute_seg_heights #1 段0 end=1（rise×d/total）")
	runner.check(abs(float(hs1[2]["end_h"]) - 3.0) < 0.001, "_compute_seg_heights #1 末段 end=rise=3")
	runner.check(abs(float(hs1[1]["start_h"]) - float(hs1[0]["end_h"])) < 0.001, "_compute_seg_heights #1 段 i end = 段 i+1 start（衔接）")
	# #2 折线弦长<弧长（length 1.8/2.7/3.6 < 弧长差 2/3/4，模拟跨顶点；CRITICAL 2）
	var hs2 := PathGenerator._compute_seg_heights(
		[{"distance": 0.0, "length": 1.8}, {"distance": 2.0, "length": 2.7}, {"distance": 5.0, "length": 3.6}],
		9.0, 5.0
	)
	runner.check(abs(float(hs2[0]["end_h"]) - (5.0 * 2.0 / 9.0)) < 0.001, "_compute_seg_heights #2 段0 end=5×2/9≈1.111（用 distance 弧长，非 length 弦长得 5×1.8/9=1.0）")
	runner.check(abs(float(hs2[1]["start_h"]) - float(hs2[0]["end_h"])) < 0.001, "_compute_seg_heights #2 折线衔接（段 i end = 段 i+1 start，弧长）")
	runner.check(abs(float(hs2[2]["end_h"]) - 5.0) < 0.001, "_compute_seg_heights #2 末段 end=rise=5")
	# #3 下降（rise<0，等长 3 段）→ [{3,2},{2,1},{1,0}]（递减，正高度，楔形朝上）
	var hs3 := PathGenerator._compute_seg_heights(
		[{"distance": 0.0, "length": 3.0}, {"distance": 3.0, "length": 3.0}, {"distance": 6.0, "length": 3.0}],
		9.0, -3.0
	)
	runner.check(abs(float(hs3[0]["start_h"]) - 3.0) < 0.001, "_compute_seg_heights #3 下降首段 start=|rise|=3")
	runner.check(abs(float(hs3[2]["end_h"]) - 0.0) < 0.001, "_compute_seg_heights #3 下降末段 end=0")
	runner.check(abs(float(hs3[0]["end_h"]) - 2.0) < 0.001, "_compute_seg_heights #3 下降段0 end=2（递减）")
	runner.check(float(hs3[0]["start_h"]) > float(hs3[0]["end_h"]), "_compute_seg_heights #3 下降 start>end（Δh<0）")
	# #4 单段（count=1，total=5，rise=2）→ [{0,2}]
	var hs4 := PathGenerator._compute_seg_heights([{"distance": 0.0, "length": 5.0}], 5.0, 2.0)
	runner.check(hs4.size() == 1, "_compute_seg_heights #4 单段 → 1 项")
	runner.check(abs(float(hs4[0]["start_h"]) - 0.0) < 0.001, "_compute_seg_heights #4 单段 start=0")
	runner.check(abs(float(hs4[0]["end_h"]) - 2.0) < 0.001, "_compute_seg_heights #4 单段 end=rise=2")
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: PathGenerator suite 出现 FAIL（`_compute_seg_heights` 不存在 / Nonexistent function），Results: failed ≥ 14（4 例 × 多条断言）。其他 4 suite 仍 pass。

- [ ] **Step 3: 实现 `_compute_seg_heights`**

在 `addons/asset_forge/path_generator.gd` 的 `_total_length` 函数**之后**新增：

```gdscript
# v6 continuous ramp 高度分配：rise 按累计弧长比例分到各段端点（恒定坡度）
# 段 i 的 d_end = 段 i+1 的 d_start（弧长衔接，boundaries 连续）；末段 d_end = total_len
# 注意：seg["length"] 是弦长（p_start.distance_to(p_end)），跨折线顶点时 < 弧长，不能用（CRITICAL 2）
# rise 符号：≥0 上升（0→rise 递增）；<0 下降（|rise|→0 递减，正高度，楔形朝上）
static func _compute_seg_heights(samples: Array, total_len: float, rise: float) -> Array:
	assert(samples.size() > 0, "_compute_seg_heights: samples 空")
	assert(total_len > 0.0, "_compute_seg_heights: total_len 非正")
	var abs_rise: float = absf(rise)
	var heights: Array = []
	var n: int = samples.size()
	for i in n:
		var d_start: float = float(samples[i]["distance"])
		var d_end: float = float(samples[i + 1]["distance"]) if i + 1 < n else total_len
		if rise >= 0.0:
			# 上升：0 → rise（递增）
			heights.append({"start_h": abs_rise * d_start / total_len, "end_h": abs_rise * d_end / total_len})
		else:
			# 下降：abs_rise → 0（递减，正高度）
			heights.append({"start_h": abs_rise * (total_len - d_start) / total_len, "end_h": abs_rise * (total_len - d_end) / total_len})
	return heights
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: PathGenerator suite 14 条 `_compute_seg_heights` 断言 PASS。Results: 0 failed。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/path_generator.gd tests/test_path_generator.gd
git commit -m "feat: _compute_seg_heights 弧长高度分配纯函数（v6 Task 1）

- _compute_seg_heights(samples, total_len, rise) 用 distance 弧长衔接（非 length 弦长，CRITICAL 2）
- rise 符号分支：≥0 上升 / <0 下降（|rise| 递减，正高度）
- 4 例单测含折线弦长<弧长覆盖

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: `make_ramp` 手写 wedge + A3/法线单测

**Files:**
- Modify: `addons/asset_forge/custom_meshes.gd`（新增 `make_ramp`，放 `make_fence` 之后）
- Test: `tests/test_custom_meshes.gd`（`run(runner)` 末尾追加）

**Interfaces:**
- Produces: `CustomMeshes.make_ramp(params: Dictionary) -> ArrayMesh`（8 顶点 6 面 wedge，start_height/end_height ≥ 0，单 surface）

- [ ] **Step 1: 加 make_ramp A3 + 斜顶法线单测（RED）**

在 `tests/test_custom_meshes.gd` 的 `run(runner)` 末尾（v5 `_post_xs` 9 例之后）追加：

```gdscript
	# v6 make_ramp 手写 wedge（A3 + 斜顶法线 Y>0）
	var ramps := {
		"上升默认": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.0, "end_height": 1.0}),
		"上升自定义": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.2, "end_height": 0.8}),
		"水平退化": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 0.0, "end_height": 0.0}),
		"下降": CustomMeshes.make_ramp({"length": 2.0, "width": 1.0, "start_height": 1.0, "end_height": 0.5}),
	}
	for label in ramps:
		var rm: ArrayMesh = ramps[label]
		runner.check(rm != null and rm is ArrayMesh, "make_ramp %s 返回 ArrayMesh" % label)
		runner.check(rm.get_surface_count() == 1, "make_ramp %s 单 surface（A3）" % label)
		var rvlen: int = rm.surface_get_array_len(0)
		runner.check(rvlen > 0, "make_ramp %s 顶点数 > 0（实际 %d）" % [label, rvlen])
		# 斜顶法线断言：所有法线模长≈1（归一化）+ 存在朝上法线 Y>0.5（斜顶/水平顶朝上）
		var rarrays: Array = rm.surface_get_arrays(0)
		var rnormals: PackedVector3Array = rarrays[Mesh.ARRAY_NORMAL]
		var all_unit: bool = true
		var has_up_facing: bool = false  # 朝上法线（斜顶/水平顶 Y>0.5）
		for nv in rnormals:
			if absf(nv.length() - 1.0) > 0.01:
				all_unit = false
			if nv.y > 0.5:
				has_up_facing = true  # 斜顶（上升/下降 Y>0）或水平顶（start==end 时 (0,1,0)）
		runner.check(all_unit, "make_ramp %s 法线全归一化（模长≈1）" % label)
		runner.check(has_up_facing, "make_ramp %s 存在朝上法线 Y>0.5（斜顶/水平顶）" % label)
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: CustomMeshes suite FAIL（`make_ramp` 不存在）。

- [ ] **Step 3: 实现 `make_ramp`**

在 `addons/asset_forge/custom_meshes.gd` 的 `make_fence` 函数**之后**（`_add_box` 之前）新增：

```gdscript
# --- ramp 坡道（两端独立高度 wedge → 单 ArrayMesh，A3）---
# v6 continuous 高度衔接：start_height/end_height ≥ 0（placement 保证），Δh 任意（上升 sh<eh / 下降 sh>eh）
# 6 面绕序统一 _add_box 约定（几何法线朝楔形内，set_normal 朝外）；斜顶 set_normal (sh-eh, length, 0).normalized() Y 恒朝上
static func make_ramp(params: Dictionary) -> ArrayMesh:
	var length: float = float(params.get("length", 2.0))
	var width: float = float(params.get("width", 1.0))
	var sh: float = float(params.get("start_height", 0.0))
	var eh: float = float(params.get("end_height", float(params.get("height", 1.0))))
	var hl := length / 2.0
	var hw := width / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 8 顶点
	var d0 := Vector3(-hl, 0.0, -hw)  # 底面后左
	var d1 := Vector3(-hl, 0.0, hw)   # 底面前左
	var d2 := Vector3(hl, 0.0, hw)    # 底面前右
	var d3 := Vector3(hl, 0.0, -hw)   # 底面后右
	var t0 := Vector3(-hl, sh, -hw)   # 顶面后左
	var t1 := Vector3(-hl, sh, hw)    # 顶面前左
	var t2 := Vector3(hl, eh, hw)     # 顶面前右
	var t3 := Vector3(hl, eh, -hw)    # 顶面后右
	# 6 面（_add_box 约定：顶点顺序让几何法线朝楔形内，set_normal 朝外）
	_add_face(st, d1, d2, d3, d0, Vector3(0.0, -1.0, 0.0))  # 底面（内侧 +Y）
	_add_face(st, t0, t3, t2, t1, Vector3(sh - eh, length, 0.0).normalized())  # 斜顶（法线 Y 恒 +length 朝上）
	_add_face(st, d1, t1, t2, d2, Vector3(0.0, 0.0, 1.0))  # 前面 Z+（内侧 -Z）
	_add_face(st, d0, d3, t3, t0, Vector3(0.0, 0.0, -1.0))  # 后面 Z-（内侧 +Z）
	_add_face(st, d0, t0, t1, d1, Vector3(-1.0, 0.0, 0.0))  # 左端 X-（内侧 +X）
	_add_face(st, d2, t2, t3, d3, Vector3(1.0, 0.0, 0.0))  # 右端 X+（内侧 -X）
	# I-3：每面 set_normal 手设法线，不调 index()/generate_normals()（与 _add_box 一致，避免平滑）
	return st.commit()
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: CustomMeshes suite make_ramp 4 用例全 PASS（A3 + 归一化 + 斜顶 Y>0）。Results: 0 failed。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/custom_meshes.gd tests/test_custom_meshes.gd
git commit -m "feat: make_ramp 手写 wedge（v6 Task 2）

- 8 顶点 6 面 wedge，start_height/end_height（≥0，Δh 任意）
- 6 面绕序统一 _add_box 约定（几何朝内 set_normal 朝外）
- 斜顶法线 (sh-eh, length, 0).normalized() Y 恒朝上（无 sign 分支）
- 单 ArrayMesh（A3）
- A3 + 斜顶法线归一化/Y>0 断言（4 用例：上升默认/自定义/水平退化/下降）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: `asset_factory` ramp 分流

**Files:**
- Modify: `addons/asset_forge/asset_factory.gd:40-48`（ramp 分支加分流）
- Test: `tests/test_asset_factory.gd`（`run(runner)` 末尾追加 2 例）

**Interfaces:**
- Consumes: Task 2 的 `CustomMeshes.make_ramp`
- Produces: `create_mesh("ramp", params)` params 含 start_height/end_height 时返 ArrayMesh（make_ramp），否则 PrismMesh（现状）

- [ ] **Step 1: 加分流单测（RED）**

在 `tests/test_asset_factory.gd` 的 `run(runner)` 末尾（非法 hex 断言之后）追加：

```gdscript
	# v6 ramp 分流（params 含 start_height/end_height → make_ramp ArrayMesh，否则 PrismMesh）
	var ramp_handmade = AssetFactory.create_mesh("ramp", {"start_height": 0.5, "end_height": 1.0, "length": 2.0, "width": 1.0})
	runner.check(ramp_handmade is ArrayMesh, "create_mesh('ramp', {start_height}) → ArrayMesh（make_ramp 手写）")
	var ramp_default = AssetFactory.create_mesh("ramp", {"length": 2.0, "height": 1.0, "width": 1.0})
	runner.check(ramp_default is PrismMesh, "create_mesh('ramp', {}) → PrismMesh（现状零回归）")
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: AssetFactory suite FAIL（`create_mesh('ramp', {start_height})` 返 PrismMesh 非 ArrayMesh）。

- [ ] **Step 3: 实现 ramp 分流**

把 `addons/asset_forge/asset_factory.gd:40-48` 的 ramp 分支：

```gdscript
		"ramp":  # 语义化 prism：坡道
			var m := PrismMesh.new()
			m.size = Vector3(
				float(params.get("length", 2.0)),
				float(params.get("height", 1.0)),
				float(params.get("width", 1.0))
			)
			m.left_to_right = 0.0
			return m
```

替换为：

```gdscript
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
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: AssetFactory suite 分流 2 例 PASS。Results: 0 failed。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/asset_factory.gd tests/test_asset_factory.gd
git commit -m "feat: asset_factory ramp 分流（v6 Task 3）

- params 含 start_height/end_height → CustomMeshes.make_ramp（手写 wedge）
- 否则 PrismMesh（单件/discrete 零回归）
- 分流 2 例单测（ArrayMesh vs PrismMesh）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: placement continuous ramp 注入 + selftest

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd:289-314`（continuous 分支加 `elif shape == "ramp"`）
- Modify: `tools/forge_client.py:run_selftest`（加 v6 continuous ramp L 路径）

**Interfaces:**
- Consumes: Task 1 的 `_compute_seg_heights` + Task 3 的分流（make_ramp）
- Produces: continuous ramp 各段注入 start_height/end_height（高度衔接）

**注**：`_handle_generate_path` 是 EditorPlugin 逻辑，headless 不加载 → 本任务 plugin 改动无 headless 单测，靠 selftest 端到端 + code review（v4/v5 模式）。

- [ ] **Step 1: continuous 分支加 ramp 高度注入**

把 `addons/asset_forge/asset_forge_plugin.gd:289-314` 的 continuous 分支：

```gdscript
	else:  # continuous：每段独立 create_mesh（length + fence 端柱注入）
		var seg_count: int = samples.size()
		for i in seg_count:
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
			if shape == "fence":
				# v5 端柱共享：所有段保首柱（=接缝柱），仅末段保末柱（=终点柱），
				# 其他段去末柱（避免与下段首柱重叠 z-fighting）。discrete/单件不注入，零回归。
				seg_params["start_post"] = true
				seg_params["end_post"] = i == seg_count - 1
			var seg_mesh := AssetFactory.create_mesh(shape, seg_params)
			_place_one(
				root,
				seg_mesh,
				material,
				base_name,
				i,
				seg["position"],
				seg["rotation_deg"],
				payload,
				batch_id,
				seg_count,  # v3：total
				req_id,
				ws
			)
```

替换为：

```gdscript
	else:  # continuous：每段独立 create_mesh（length + fence 端柱 / ramp 高度注入）
		var seg_count: int = samples.size()
		# v6：ramp 高度衔接，循环外算一次（仅 ramp 用，弧长基础非弦长）
		var ramp_heights: Array = []
		if shape == "ramp":
			var rise: float = float(base_params.get("height", 1.0))
			var total_len: float = PathGenerator._total_length(points)
			ramp_heights = PathGenerator._compute_seg_heights(samples, total_len, rise)
		for i in seg_count:
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
			if shape == "fence":
				# v5 端柱共享：所有段保首柱（=接缝柱），仅末段保末柱（=终点柱），
				# 其他段去末柱（避免与下段首柱重叠 z-fighting）。discrete/单件不注入，零回归。
				seg_params["start_post"] = true
				seg_params["end_post"] = i == seg_count - 1
			elif shape == "ramp":
				# v6 高度衔接（_compute_seg_heights 循环外预算，弧长比例，恒定坡度）
				seg_params["start_height"] = float(ramp_heights[i]["start_h"])
				seg_params["end_height"] = float(ramp_heights[i]["end_h"])
			var seg_mesh := AssetFactory.create_mesh(shape, seg_params)
			_place_one(
				root,
				seg_mesh,
				material,
				base_name,
				i,
				seg["position"],
				seg["rotation_deg"],
				payload,
				batch_id,
				seg_count,  # v3：total
				req_id,
				ws
			)
```

- [ ] **Step 2: 跑 headless 确认零回归（plugin 不被加载，确认语法 + 其他 suite）**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: 全部 5 suite pass（plugin 改动不被 headless 加载，但 GDScript 语法无误 + 其他 suite 零回归）。Results: 0 failed。

- [ ] **Step 3: 加 selftest v6 continuous ramp L 路径**

在 `tools/forge_client.py` 的 `run_selftest` 函数里，v5 continuous ramp undo（`generate_path continuous ramp undo（freed 3）`）那块之后、`await ws.close()` 之前，插入：

```python
    # v6 generate_path continuous + ramp（L 路径 count=3，高度衔接，验证折线弧长分配）
    ramp_v6_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v6_ramp",
            "payload": {
                "shape": "ramp",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "height": 2,
                "material": "stone",
                "name": "st_v6_ramp",
            },
        },
        3,
    )
    ok = len(ramp_v6_results) == 3 and all(bool(r.get("success")) for r in ramp_v6_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp v6（{len(ramp_v6_results)}/3 result，L 路径高度衔接）")
    # undo continuous ramp v6
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v6_ramp_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp v6 undo（freed 3）")
```

- [ ] **Step 4: ast 语法检查 + pytest 零回归**

Run: `python -c "import ast; ast.parse(open('tools/forge_client.py', encoding='utf-8').read()); print('syntax OK')"`
Expected: `syntax OK`

Run: `python -m pytest tests/test_forge_client_predict.py -q 2>&1 | tail -2`
Expected: 17 passed（零回归）。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd tools/forge_client.py
git commit -m "feat: continuous ramp 高度衔接注入 + selftest（v6 Task 4）

- _handle_generate_path continuous 分支加 elif shape=='ramp'
- _total_length(points) 弧长 + _compute_seg_heights 循环外算
- selftest v6 continuous ramp L 路径（折线高度衔接 visual）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: 文档同步

**Files:**
- Modify: `docs/protocol.md`（`:83` continuous 段）
- Modify: `README.md`（`:115` continuous 段 + `:88` ramp 参数表）
- Modify: `docs/shapes-reference.md`（`:12` ramp 注记 + 参数表）

**注**：`defects.md` 纠偏在另一仓库（`D:\workspace\review\`），不进本 commit，见 plan 末尾"完成后跨仓库操作"。

- [ ] **Step 1: `docs/shapes-reference.md:12` ramp 加 continuous 注记 + 参数**

把 `docs/shapes-reference.md:12`：

```
| `ramp` | `length 2` / `height 1` / `width 1`（语义化 prism，坡道，`left_to_right=0`；v5 起支持 continuous 模式，接缝高度台阶为已知局限） |
```

替换为：

```
| `ramp` | `length 2` / `height 1` / `width 1` / `start_height 0` / `end_height 1`（语义化 prism，坡道，`left_to_right=0`；v6 起 continuous 模式 height 作总升高，各段按累计弧长比例衔接恒定坡度，支持下降 height 负；单件/discrete 用 PrismMesh，continuous 用手写 wedge） |
```

- [ ] **Step 2: `README.md:88` ramp 参数表加 start_height/end_height**

把 `README.md:88`：

```
| `ramp` | PrismMesh 语义化 | `length 2` / `height 1` / `width 1` |
```

替换为：

```
| `ramp` | PrismMesh 语义化 | `length 2` / `height 1` / `width 1` / `start_height 0` / `end_height 1`（continuous 自动衔接） |
```

- [ ] **Step 3: `README.md:115` continuous 段改 ramp 注记**

把 `README.md:115`：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径首尾相连铺满，length 自适应段长，仅支持 wall/fence/ramp（length 沿 X）。fence 段接缝端柱由 v5 去重（放置层注入 start_post/end_post，端柱共享：所有段保首柱 + 仅末段保末柱）。ramp 接缝高度台阶为已知局限（留后续）。
```

替换为：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径首尾相连铺满，length 自适应段长，仅支持 wall/fence/ramp（length 沿 X）。fence 段接缝端柱由 v5 去重（端柱共享）。ramp 接缝高度台阶由 v6 解（height 作总升高，各段按累计弧长比例衔接恒定坡度，支持下降 height 负）。
```

- [ ] **Step 4: `docs/protocol.md:83` continuous 段改 ramp 注记**

把 `docs/protocol.md:83`：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱由 v5 放置层按段索引注入 `start_post`/`end_post` 去重（所有段保首柱 = 接缝柱，仅末段保末柱 = 终点柱，端柱共享零 z-fighting）；ramp 接缝高度台阶为已知局限（PrismMesh 斜面在 Y 不沿路径，留后续）。
```

替换为：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱由 v5 放置层按段索引注入 `start_post`/`end_post` 去重（端柱共享零 z-fighting）；ramp 接缝高度由 v6 放置层注入 `start_height`/`end_height` 衔接（`_compute_seg_heights` 按累计弧长比例分配 height 总升高，恒定坡度，折线/直线都成立；支持下降 height 负）。
```

- [ ] **Step 5: Commit**

```bash
git add docs/protocol.md README.md docs/shapes-reference.md
git commit -m "docs: v6 ramp continuous 高度衔接文档同步（v6 Task 5）

- shapes-reference ramp 加 start_height/end_height + continuous 衔接注记
- README/protocol continuous 段 ramp 注记从 v5 已知局限改为 v6 已解
- ramp 参数表补 start_height/end_height

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 完成后跨仓库操作（不进 feature/ramp-height-continuity commit）

### defects.md note 纠偏（另一仓库）

`D:\workspace\review\.claude\knowledge\projects\godot-asset-forge\defects.md` `shared-vertex-box-smooth-normals` 条目两字段纠偏：
- **:41 fix-forward**：「24 顶点 + generate_normals() 自然得轴对齐」→ 改为「`_add_face` + `set_normal` 手设面法线 + 不调 `index()`/`generate_normals()`」
- **:44 note**：「test_custom_meshes.gd 未查法线（测试盲区）」→ 改为「I-3 已补 box 法线轴对齐断言（`test_custom_meshes.gd:56-78`），v6 make_ramp 斜顶法线断言扩展之」

此文件在 `D:\workspace\review\` 仓库（godot-asset-forge 之外），v6 实现 commit 后单独编辑（不进 feature 分支 commit）。

## 完成后验证（Step 6 编辑器手测，补 v6 闭环）

全部 5 task 完成后，在 Godot 编辑器（启插件 + 打开场景）验证：

```bash
# F5 验证 make_ramp 6 面可见（CRITICAL 1 绕序最终判据）
# 在编辑器内跑 make_ramp({"start_height":0,"end_height":1}) 肉眼确认 6 面全可见（无 cull 缺面）
# 若某面被 cull，反转 make_ramp 全部 6 面顶点顺序（相反约定），以 F5 可见性为准

# selftest 全 PASS（含 v6 新增 continuous ramp L 路径）
python tools/forge_client.py --selftest

# 视觉验证：L 路径 continuous ramp，接缝处高度连续（v5 台阶消除）
python tools/forge_client.py path ramp --path '[[0,0,0],[3,0,0],[3,0,3]]' --count 3 --mode continuous --height 2 --mat stone

# 下降验证（height 负）
python tools/forge_client.py path ramp --path '[[0,0,0],[3,0,0]]' --count 3 --mode continuous --height -1 --mat stone
```

预期：selftest 全 PASS（含 `generate_path continuous ramp v6（3/3）` + `undo freed 3`）；编辑器视口 L 路径 ramp 接缝高度连续（无台阶）；下降 ramp 楔形朝上递减。
