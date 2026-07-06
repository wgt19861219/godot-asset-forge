# v7 mesh 缓存 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AssetFactory.create_mesh 缓存相同 (shape, params) → 返同一 Mesh 资源，省重复创建（make_fence 重）+ GPU vertex buffer 复用（MI3D 共享）。

**Architecture:** 规范化 `_params_key`（排序 keys + 递归 `_variant_key`，顺序无关 + 零碰撞，非 hash）作 cache key；`static var _cache` 查存；既有 match body 提取 `_create_mesh_uncached`。

**Tech Stack:** GDScript（Godot 4.6 `@tool`，Tab 缩进）。

## Global Constraints

- Godot 4.6.3 Forward+，GDScript，**缩进 = Tab**，注释简体中文
- **create_mesh 返回语义不变**——缓存后返同一资源，调用方 `mi.mesh = mesh` 无感知（零回归）
- **未知 shape 返 null 不缓存**（避免 null 污染 _cache）
- **缓存 Mesh 不被下游 mutation**（已 grep 核实：`scene_placer.gd:25` `mi.mesh = mesh` 赋值 + `material_override` 各 MI3D 独立，无 surface_set/add_surface）
- **`_params_key` 顺序无关 + 零碰撞**（排序 keys + 完整内容序列化 `_variant_key`，**非 `Dictionary.hash()`**——后者顺序敏感 godot-proposals #9452 + 碰撞静默返错误 mesh）
- **material 不进 cache key**（`base_params = payload.get("params", {})` 只含几何参数子字典，material/name 等在 payload 顶层——跨请求同几何不同 material 仍命中）
- 当前分支 `feature/mesh-cache`（spec `a901dee`，从 master `1671b40` 分出）。本仓库无 remote
- godot 不在 PATH，全路径：`D:/godot/Godot_v4.6.3-stable_win64_console.exe`

## File Structure

| 文件 | 改动 | 责任 |
|------|------|------|
| `addons/asset_forge/asset_factory.gd` | 新增 `static var _cache` + `_params_key` + `_variant_key` + create_mesh 缓存逻辑 + 既有 body 提取 `_create_mesh_uncached` | mesh 缓存 |
| `tests/test_asset_factory.gd` | `run(runner)` 末尾追加缓存单测 | is_same 身份 + 顺序无关 + null + ramp 隔离 |
| `README.md` | 特性段加 1 句 mesh 缓存 | 文档 |

---

### Task 1: `_params_key` + `_variant_key` + create_mesh 缓存 + 单测 + README

**Files:**
- Modify: `addons/asset_forge/asset_factory.gd`（加 `static var _cache` + `_params_key` + `_variant_key` + create_mesh 缓存 + 提取 `_create_mesh_uncached`）
- Test: `tests/test_asset_factory.gd`（`run(runner)` 末尾追加缓存单测）
- Modify: `README.md`（特性段加 mesh 缓存 1 句）

**Interfaces:**
- Produces: `AssetFactory._cache: Dictionary`（static var，key = `shape.to_lower() + "|" + _params_key(params)`，值 = Mesh）；`AssetFactory._params_key(params) -> String`；`AssetFactory._variant_key(v: Variant) -> String`；`AssetFactory._create_mesh_uncached(shape, params) -> Mesh`（原 create_mesh body）

- [ ] **Step 1: 加缓存单测（RED）**

在 `tests/test_asset_factory.gd` 的 `run(runner)` 末尾（v6 ramp 分流单测 `:89-93` 之后）追加：

```gdscript
	# === v7 mesh 缓存 ===
	AssetFactory._cache.clear()  # ADVISORY2：测试 setup 隔离，避免跨测试缓存污染
	# 相同 params 返同一 Mesh（is_same 身份比较）
	var cp1 := {"length": 3.0, "height": 1.2, "posts": 4}
	var cf1 := AssetFactory.create_mesh("fence", cp1)
	var cf2 := AssetFactory.create_mesh("fence", cp1.duplicate())
	runner.check(is_same(cf1, cf2), "v7 缓存：相同 params 返同一 Mesh（is_same 身份）")
	# 不同 params 返不同 Mesh
	var cf3 := AssetFactory.create_mesh("fence", {"length": 4.0, "height": 1.2, "posts": 4})
	runner.check(not is_same(cf1, cf3), "v7 缓存：不同 params 返不同 Mesh")
	# 顶层 dict 顺序无关（_params_key 排序 keys）
	var fp_ord1 := {"length": 3.0, "height": 1.2, "posts": 4}
	var fp_ord2 := {"posts": 4, "height": 1.2, "length": 3.0}
	runner.check(
		is_same(AssetFactory.create_mesh("fence", fp_ord1), AssetFactory.create_mesh("fence", fp_ord2)),
		"v7 缓存：顶层 dict 顺序无关（_params_key 排序）"
	)
	# 嵌套 dict 顺序无关（ADVISORY1：直接测 _params_key 覆盖 _variant_key 嵌套分支，shape params 当前扁平无触发）
	runner.check(
		AssetFactory._params_key({"outer": {"a": 1, "b": 2}}) == AssetFactory._params_key({"outer": {"b": 2, "a": 1}}),
		"v7 _params_key 嵌套 dict 顺序无关（_variant_key 递归排序）"
	)
	# null 不缓存（未知 shape）
	AssetFactory._cache.clear()
	runner.check(AssetFactory.create_mesh("pyramid", {}) == null, "未知 shape 返 null")
	runner.check(AssetFactory._cache.size() == 0, "v7 缓存：null 不污染 _cache")
	# ramp 分流隔离（手写 wedge vs PrismMesh 不同 key 不互染）
	var cr_hand := AssetFactory.create_mesh("ramp", {"start_height": 0.5, "end_height": 1.0, "length": 2.0, "width": 1.0})
	var cr_def := AssetFactory.create_mesh("ramp", {"length": 2.0, "height": 1.0, "width": 1.0})
	runner.check(cr_hand is ArrayMesh and cr_def is PrismMesh, "v7 缓存：ramp 分流隔离（手写 vs PrismMesh）")
	runner.check(not is_same(cr_hand, cr_def), "v7 缓存：ramp 不同 params 不同 mesh")
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: AssetFactory suite FAIL（`_cache` / `_params_key` 不存在 / Nonexistent identifier）。Results: failed ≥ 7（v7 缓存 7 条断言）。其他 4 suite 仍 pass。

- [ ] **Step 3: 实现 `_params_key` + `_variant_key` + `_cache` + create_mesh 缓存 + 提取 `_create_mesh_uncached`**

把 `addons/asset_forge/asset_factory.gd:8-63` 的 `create_mesh`（整个 match body）：

```gdscript
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
```

替换为（create_mesh 缓存 + _create_mesh_uncached 提取 + _params_key + _variant_key）：

```gdscript

# v7 mesh 缓存（static var 持 Mesh 引用，常驻 plugin session；@tool 热重载偶发清空无害）
static var _cache: Dictionary = {}


# v7 缓存：相同 (shape, params) 返同一 Mesh 资源（MeshInstance3D 共享 → GPU vertex buffer 复用）
# 未知 shape 返 null 不缓存。material 不进 key（base_params 只含几何参数子字典）
static func create_mesh(shape: String, params: Dictionary) -> Mesh:
	var key: String = shape.to_lower() + "|" + _params_key(params)
	if _cache.has(key):
		return _cache[key]
	var mesh: Mesh = _create_mesh_uncached(shape, params)
	if mesh != null:
		_cache[key] = mesh  # null（未知 shape）不缓存
	return mesh


# 既有创建逻辑（create_mesh 缓存未命中时调，原 create_mesh body 逐字提取）
static func _create_mesh_uncached(shape: String, params: Dictionary) -> Mesh:
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


# v7 缓存 key：顺序无关（Dictionary key 排序）+ 零碰撞（完整内容序列化，非 hash）
# 不用 Dictionary.hash()（顺序敏感 godot-proposals #9452 + 碰撞静默返错误 mesh）
static func _params_key(params: Dictionary) -> String:
	var keys: Array = params.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append(str(k) + ":" + _variant_key(params[k]))
	return "{" + ",".join(parts) + "}"


# v7 _params_key 的 Variant 值序列化（递归 Dictionary 排序 / Array 有序 / PackedFloat64Array / 标量 str）
static func _variant_key(v: Variant) -> String:
	if v is Dictionary:
		return _params_key(v)  # 嵌套 dict 递归 + 排序
	if v is Array:
		var parts: PackedStringArray = []
		for x in (v as Array):
			parts.append(_variant_key(x))  # 数组有序（正确，数组本有序）
		return "[" + ",".join(parts) + "]"
	if v is PackedFloat64Array:  # _vec3 兼容（asset_factory.gd _vec3 接受 Array 或 PackedFloat64Array）
		var parts: PackedStringArray = []
		for x in (v as PackedFloat64Array):
			parts.append(str(x))
		return "[" + ",".join(parts) + "]"
	return str(v)
```

- [ ] **Step 4: 跑测试确认 GREEN + 零回归**

Run: `"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --script res://tests/test_runner.gd 2>&1 | tail -3`
Expected: AssetFactory suite v7 缓存 7 条断言 PASS + 既有测试（shape != null / box size / pyramid null / ramp 分流）零回归（缓存透明，返同一 mesh 但断言不查 identity）。Results: 0 failed（247 v6 基线 + v7 新 = 254 左右）。

- [ ] **Step 5: README 特性段加 mesh 缓存 1 句**

把 `README.md` 特性段（`- **本地安全**：bind 127.0.0.1...` 那行之前或之后）加一行。在 `## 特性` 段的 `- **本地安全**：...` 这行**之后**追加：

```markdown
- **mesh 缓存**：重复 shape / continuous count 模式自动缓存 mesh 资源（相同 params 共享，GPU vertex buffer 复用）
```

具体：把 README.md 的：
```
- **本地安全**：bind `127.0.0.1` + handshake token 鉴权
```

替换为：
```
- **本地安全**：bind `127.0.0.1` + handshake token 鉴权
- **mesh 缓存**：重复 shape / continuous count 模式自动缓存 mesh 资源（相同 params 共享，GPU vertex buffer 复用）
```

- [ ] **Step 6: Commit**

```bash
git add addons/asset_forge/asset_factory.gd tests/test_asset_factory.gd README.md
git commit -m "feat: AssetFactory.create_mesh 缓存（v7）

- _params_key（排序 keys）+ _variant_key（递归 Dictionary/Array/PackedFloat64Array/str）规范化 key
  顺序无关 + 零碰撞（非 Dictionary.hash，后者顺序敏感+碰撞静默返错误 mesh）
- static var _cache 查存，相同 (shape, params) 返同一 Mesh（is_same 身份）
- 既有 body 提取 _create_mesh_uncached，null 不缓存
- 命中 continuous fence count 中间段 N-1 + wall count + 单件重复
- 单测：is_same + 顺序无关（顶层+嵌套 dict）+ null 不缓存 + ramp 分流隔离
- README 特性段加 1 句

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 完成后验证（Step 6 编辑器 + headless 手动 benchmark，补 v7 闭环）

mesh 缓存的**功能性**已由 Task 1 headless 单测验证（is_same + 顺序无关 + 隔离）。**性能收益**需 benchmark 两层确认（CLAUDE.md 目标驱动 + verification，不凭假设优化）：

### 收益层（headless 可测，验证缓存命中收益数值）

临时 timing 脚本（不进 test suite，避免 CI 不稳定），测 `create_mesh("fence", same_params)` N=100 次（缓存命中 99 次）vs `_create_mesh_uncached("fence", same_params)` N=100 次（无缓存）总时间对比：

```bash
# 临时 timing（headless，godot 全路径）—— 用 --script 跑一个临时 .gd 测 timing，benchmark 后删
# 预期：缓存命中后总时间显著低于无缓存（make_fence SurfaceTool 360 顶点重）
```

### 占比层（编辑器手测，确认 create_mesh 是 generate_path 瓶颈）

continuous fence count N=64，profile `generate_path` 总时间中 `create_mesh` 占比（用编辑器 Profiler，或临时在 `_handle_generate_path` 加 `Time.get_ticks_usec()` timing print 测各阶段：sample / create_mesh × N / place × N / send_result × N）：

- 若 create_mesh 占比 >30%：缓存收益显著（v7 对症）
- 若 create_mesh 占比 <10%：瓶颈在 ScenePlacer/node/WS（缓存是"感觉快了"的安慰剂）→ 需优化别处（后续 v8）

### 视觉验证（编辑器体感）

编辑器跑 `path fence --count 64 --mode continuous`（continuous fence count N=64，命中 N-1 次），体感改造前后生成速度（应更快）+ 生成结果视觉一致（缓存返同一 mesh，几何不变）。

**预期**：收益层 create_mesh 总时间显著下降（缓存命中省 make_fence）；占比层 create_mesh 占 generate_path 比例若 >30% 则 v7 对症；视觉生成一致（缓存透明）。
