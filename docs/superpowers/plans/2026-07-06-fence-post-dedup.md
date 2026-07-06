# v5 fence 端柱去重 + continuous 扩 ramp 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解 continuous 模式 fence 相邻段端柱重叠 z-fighting，顺带扩 continuous 白名单到 ramp。

**Architecture:** minimal-diff。提取 `_post_xs(length, posts, start_post, end_post)` 纯函数（可单测）→ `make_fence` 加 `start_post`/`end_post` 两 bool 参数（默认 true，单件/discrete 零回归）→ continuous 放置层按段索引注入（所有段首柱 + 仅末段末柱，仅 fence）→ 白名单 `:240` 加 ramp + 错误消息 `:247` 同步。

**Tech Stack:** GDScript（Godot 4.6 `@tool`，Tab 缩进）/ Python 3（`tools/forge_client.py` selftest）/ WebSocket JSON 协议。

## Global Constraints

- Godot 4.6.3 Forward+，GDScript，**缩进 = Tab**，注释简体中文，保留 `IMPORTANT-N` / `Q-N` / `A-N` 标记
- **make_fence 仍烘焙单 ArrayMesh（单 surface）**——CLAUDE.md 不变量 7 / A3。start_post/end_post 只控制柱循环，横档仍进同一个 SurfaceTool 再 `commit()`
- **start_post/end_post 默认 true**，params 不含时 make_fence 行为与 v4 字节一致（零回归）
- **continuous 端柱共享仅 fence 注入**——wall/ramp 无柱，seg_params 不加 start_post/end_post
- **`_post_xs` 是纯函数**——无副作用，不碰 SurfaceTool，可独立 headless 单测
- **v5 只保证端柱不重叠（消 z-fighting），不保证跨段等间距**——va 模式按顶点切分（`path_generator.gd:126-139`）各折线段长不等，段间柱间距会不同
- `_EPS = 1e-4`，`BATCH_LIMIT = 64`
- 本仓库无 remote（纯本地 git）；当前分支 `feature/fence-post-dedup`（spec 08c466f，从 master 3a20ba0 分出）

## File Structure

| 文件 | 改动 | 责任 |
|------|------|------|
| `addons/asset_forge/custom_meshes.gd` | 新增 `_post_xs` + 改 `make_fence` 循环 | fence 几何（柱 x 坐标纯函数 + 端柱参数） |
| `addons/asset_forge/asset_forge_plugin.gd` | `:240` 白名单 + `:247` 错误消息 + `:289-308` continuous 注入 | path 编排（ramp 放行 + fence 端柱共享） |
| `tests/test_custom_meshes.gd` | 加 `_check_xs` helper + 9 例 `_post_xs` 单测 | 纯函数几何单测 |
| `tools/forge_client.py` | `run_selftest` 加 2 条（continuous fence/ramp） | 端到端验证 |
| `docs/protocol.md` / `README.md` / `docs/shapes-reference.md` | 白名单 wall/fence→wall/fence/ramp + 端柱去重注记 + fence 参数 + ramp continuous 注记 | 协议/文档同步 |

---

### Task 1: `_post_xs` 纯函数 + `make_fence` 加 start_post/end_post + 9 例单测

**Files:**
- Modify: `addons/asset_forge/custom_meshes.gd`（新增 `_post_xs` + 改 `make_fence:136-153`）
- Test: `tests/test_custom_meshes.gd`（加 `_check_xs` helper + 9 例单测）

**Interfaces:**
- Produces: `CustomMeshes._post_xs(length: float, posts: int, start_post: bool, end_post: bool) -> Array`（纯函数，返回柱 x 坐标 Array[float]）；`make_fence` 从 params 读 `start_post`/`end_post`（默认 true）

- [ ] **Step 1: 加 `_check_xs` helper + 9 例 `_post_xs` 单测（RED）**

在 `tests/test_custom_meshes.gd` 的 `run(runner)` 方法**末尾**（`box 法线全轴对齐` 那条 `runner.check(...)` 之后）追加 9 例调用：

```gdscript
	# v5 _post_xs 纯函数单测（fence 柱 x 坐标，端柱参数）
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, true, true), [-1.5, -0.5, 0.5, 1.5], "#1 默认满配")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, true, false), [-1.5, -0.5, 0.5], "#2 去末柱（continuous 非末段）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, false, true), [-0.5, 0.5, 1.5], "#3 去首柱")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 4, false, false), [-0.5, 0.5], "#4 去首末")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 1, true, true), [-1.5], "#5 posts=1 走 t=0.0 特例（左端，make_fence 既有行为）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 1, false, false), [], "#6 posts=1 全去 → 空列表（不崩）")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 2, true, true), [-1.5, 1.5], "#7 posts=2 两端柱")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 2, true, false), [-1.5], "#8 posts=2 去末")
	_check_xs(runner, CustomMeshes._post_xs(3.0, 0, true, true), [], "#9 posts<1 → 空列表（不崩，信任上层 max(posts,1)）")
```

在 `run(runner)` 方法**之后**（文件末尾）新增 helper：

```gdscript
# v5 _post_xs 单测辅助：逐元素 is_equal_approx 比较浮点数组（posts=4 含 t=1/3 → -0.5 浮点，不能直接 ==）
func _check_xs(runner, actual: Array, expected: Array, label: String) -> void:
	var ok: bool = actual.size() == expected.size()
	if ok:
		for i in actual.size():
			if not is_equal_approx(float(actual[i]), float(expected[i])):
				ok = false
				break
	runner.check(ok, "_post_xs %s：期望 %s，实际 %s" % [label, str(expected), str(actual)])
```

- [ ] **Step 2: 跑测试确认 RED（`_post_xs` 不存在）**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: CustomMeshes suite 出现 9 条 FAIL（`_post_xs` 不存在 / Nonexistent function），Results: failed ≥ 9。其余 4 suite（AssetFactory/PathGenerator/ScenePlacer/CommandServer）仍 pass。

- [ ] **Step 3: 实现 `_post_xs`**

在 `addons/asset_forge/custom_meshes.gd` 的 `make_fence` 函数**之前**新增纯函数：

```gdscript
# v5 fence 柱 x 坐标列表（纯函数，可单测）。posts = 满配柱数；
# start_post/end_post=false 时跳过首/末柱。剩余柱仍按 t=i/(posts-1) 取（跳过端点索引，柱间距不变）。
# posts=1 走 t=0.0 特例（避免 posts-1=0 除零），x=-length/2（左端，make_fence 既有行为，v5 保留）。
static func _post_xs(length: float, posts: int, start_post: bool, end_post: bool) -> Array:
	var xs: Array = []
	for i in posts:
		if i == 0 and not start_post:
			continue
		if i == posts - 1 and not end_post:
			continue
		var t: float = 0.0 if posts == 1 else float(i) / float(posts - 1)
		xs.append((t - 0.5) * length)
	return xs
```

- [ ] **Step 4: 跑测试确认 GREEN（9 例 pass）**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: CustomMeshes suite 9 条 `_post_xs` PASS。Results: 0 failed。

- [ ] **Step 5: 改 `make_fence` 调 `_post_xs` + 加 start_post/end_post 参数**

把 `addons/asset_forge/custom_meshes.gd:135-153`（含上方 `# --- fence 栅栏` 注释行 + `make_fence` 函数体）整体替换为：

```gdscript
# --- fence 栅栏（柱 + 横档 → 单 ArrayMesh，A3）---
# v5：柱循环改为调 _post_xs 纯函数；start_post/end_post 控制首/末柱（continuous 端柱共享，默认 true 零回归）
static func make_fence(params: Dictionary) -> ArrayMesh:
	var length: float = float(params.get("length", 3.0))
	var height: float = float(params.get("height", 1.2))
	var posts: int = max(int(params.get("posts", 4)), 1)
	var pr: float = float(params.get("post_radius", 0.05))
	var rt: float = float(params.get("rail_thickness", 0.04))
	var start_post: bool = bool(params.get("start_post", true))
	var end_post: bool = bool(params.get("end_post", true))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 12
	for x in _post_xs(length, posts, start_post, end_post):
		_add_cylinder(st, Vector3(x, height / 2.0, 0.0), pr, height, seg)
	_add_box(st, Vector3(0.0, height * 0.8, 0.0), Vector3(length, rt, rt))  # 上横档
	_add_box(st, Vector3(0.0, height * 0.3, 0.0), Vector3(length, rt, rt))  # 下横档
	# I-3：_add_cylinder（径向法线，曲面 smooth）+ _add_box（面法线，轴对齐硬边）已各自 set_normal。
	# 不调 index()/generate_normals()：index() 按位置去重会合并 box 跨面角点 → 平滑法线（原 bug）。
	return st.commit()
```

- [ ] **Step 6: 跑全部 headless 确认零回归**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: 全部 5 suite pass。CustomMeshes suite 的既有 `fence` 用例（meshes dict 默认 params，断言 ArrayMesh / 单 surface / 顶点>0 / 索引合法）仍 pass（默认 start=end=true，与 v4 字节一致）+ 9 条 `_post_xs` pass。Results: 0 failed。

- [ ] **Step 7: Commit**

```bash
git add addons/asset_forge/custom_meshes.gd tests/test_custom_meshes.gd
git commit -m "feat: _post_xs 纯函数 + make_fence start_post/end_post 端柱参数（v5 Task 1）

- 提取 _post_xs(length,posts,start_post,end_post) 纯函数（柱 x 坐标，可单测）
- make_fence 加 start_post/end_post（默认 true，单件/discrete 零回归）
- 9 例 _post_xs 单测（含 posts=0/1 边界）
- make_fence 仍烘焙单 ArrayMesh（A3 不变量）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: continuous 放置层 fence 端柱注入 + ramp 白名单 + 错误消息同步

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd:240`（白名单）、`:247`（错误消息）、`:289-308`（continuous 注入）

**Interfaces:**
- Consumes: Task 1 的 `make_fence` 新参数 `start_post`/`end_post`
- Produces: continuous 模式 fence 段自动注入端柱；continuous 白名单放行 ramp

**注**：`_handle_generate_path` 是 EditorPlugin 逻辑，headless `--script` 不加载 EditorInterface → 本任务无 headless 单测，靠 Task 3 selftest 端到端 + code review（v4 验证过的模式）。

- [ ] **Step 1: 白名单 `:240` 加 ramp + 错误消息 `:247` 同步**

把 `addons/asset_forge/asset_forge_plugin.gd:240-250` 这段：

```gdscript
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
```

替换为：

```gdscript
	if mode == "continuous" and shape != "wall" and shape != "fence" and shape != "ramp":
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message":
				"continuous 模式仅支持 wall/fence/ramp（length 沿 X），当前 " + shape
			},
			ws
		)
		return
```

- [ ] **Step 2: continuous 分支 `:289-308` 加 fence 端柱注入**

把 `addons/asset_forge/asset_forge_plugin.gd:289-308` 这段：

```gdscript
	else:  # continuous：每段独立 create_mesh（length 注入）
		for i in samples.size():
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
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
				samples.size(),  # v3：total
				req_id,
				ws
			)
```

替换为：

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

- [ ] **Step 3: 跑全部 headless 确认未破坏其他 suite**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: 全部 5 suite pass（plugin 改动不被 headless 加载，但确认 GDScript 语法无误 + 其他 suite 零回归）。Results: 0 failed。

- [ ] **Step 4: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd
git commit -m "feat: continuous fence 端柱注入 + ramp 白名单（v5 Task 2）

- :240 白名单加 ramp + :247 错误消息同步 wall/fence→wall/fence/ramp
- :289 continuous 分支 fence 端柱注入（所有段首柱 + 仅末段末柱）
- 仅 fence 注入（wall/ramp 无柱），discrete 不进此分支零回归

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: selftest 2 条（continuous fence + continuous ramp）

**Files:**
- Modify: `tools/forge_client.py:run_selftest`（在 va undo 块 `:454-459`（到 `print(...)` 行）之后、`await ws.close()` `:460` 之前插入 2 条）

**Interfaces:**
- Consumes: Task 2 的 plugin 端柱注入 + ramp 白名单
- Produces: 端到端验证（continuous fence 3 段 + continuous ramp 3 段，含 undo freed 3）

**注**：selftest 需 Godot 编辑器运行（headless 无法跑）。本任务用 `python ast.parse` 验证语法，功能验证靠后续编辑器手测（v4 模式）。

- [ ] **Step 1: 加 continuous fence + ramp 两条 selftest**

在 `tools/forge_client.py` 的 `run_selftest` 函数里，`generate_path va undo（freed 4）` 那块（`:454-459`，到 `print(...)` 行）之后、`await ws.close()`（`:460`）之前，插入：

```python
    # v5 generate_path continuous + fence（L 路径 count=3，端柱共享注入 start_post/end_post）
    fence_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v5_fence",
            "payload": {
                "shape": "fence",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "material": "wood",
                "name": "st_v5_fence",
            },
        },
        3,
    )
    ok = len(fence_results) == 3 and all(bool(r.get("success")) for r in fence_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous fence（{len(fence_results)}/3 result）")
    # undo continuous fence（同 batch_id 原子弹 3 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v5_fence_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous fence undo（freed 3）")
    # v5 generate_path continuous + ramp（直线 count=3，验证白名单放行；接缝高度台阶属已知局限不断言）
    ramp_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v5_ramp",
            "payload": {
                "shape": "ramp",
                "path": [[0, 0, 0], [3, 0, 0]],
                "count": 3,
                "mode": "continuous",
                "material": "stone",
                "name": "st_v5_ramp",
            },
        },
        3,
    )
    ok = len(ramp_results) == 3 and all(bool(r.get("success")) for r in ramp_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp（{len(ramp_results)}/3 result）")
    # undo continuous ramp
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v5_ramp_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp undo（freed 3）")
```

- [ ] **Step 2: 语法检查（headless 可跑）**

Run: `python -c "import ast; ast.parse(open('tools/forge_client.py', encoding='utf-8').read()); print('syntax OK')"`
Expected: `syntax OK`（ast.parse 无异常）

- [ ] **Step 3: 跑 pytest 确认 forge_client 单测零回归**

Run: `python -m pytest tests/test_forge_client_predict.py -v`
Expected: 全部 pass（17 例，含 v4 predict_n va 用例）。forge_client 单测不覆盖 selftest（selftest 需编辑器），但确认 predict_n 等纯函数零回归。

- [ ] **Step 4: Commit**

```bash
git add tools/forge_client.py
git commit -m "feat: selftest continuous fence 端柱 + continuous ramp（v5 Task 3）

- continuous fence L 路径 count=3 + undo freed 3（验证端柱注入链路）
- continuous ramp 直线 count=3 + undo freed 3（验证白名单放行）
- 与现有 continuous wall/va selftest 对称

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 文档（protocol.md / README.md / shapes-reference.md）

**Files:**
- Modify: `docs/protocol.md`（`:75` mode 描述 + `:83` continuous 段）、`README.md`（`:115` continuous 段 + `:93` fence 参数表）、`docs/shapes-reference.md`（`:12` ramp + `:22` fence 参数表）

**注**：三处文档都有 "fence 端柱 z-fighting 待 v3 去重" 的遗留注记（v3 做了 Path3D 没做端柱，v5 才做），本任务改为"v5 已去重"。

- [ ] **Step 1: `docs/protocol.md` — mode 描述 `:75` 加 ramp**

把 `docs/protocol.md:75`：

```
- `mode`：`"discrete"`（默认，v1 等间距独立物件）或 `"continuous"`（栏板首尾相连铺满，仅 wall/fence，length 自适应段长，align 强制 path）
```

替换为：

```
- `mode`：`"discrete"`（默认，v1 等间距独立物件）或 `"continuous"`（栏板首尾相连铺满，仅 wall/fence/ramp，length 自适应段长，align 强制 path）
```

- [ ] **Step 2: `docs/protocol.md` — continuous 段 `:83` 改白名单 + 端柱去重注记**

把 `docs/protocol.md:83`：

```
**continuous 模式**：栏板（wall/fence）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱重合 z-fighting 为 preview 级瑕疵（v3 去重）。
```

替换为：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱由 v5 放置层按段索引注入 `start_post`/`end_post` 去重（所有段保首柱 = 接缝柱，仅末段保末柱 = 终点柱，端柱共享零 z-fighting）；ramp 接缝高度台阶为已知局限（PrismMesh 斜面在 Y 不沿路径，留后续）。
```

- [ ] **Step 3: `README.md` — continuous 段 `:115` 改白名单 + 端柱去重注记**

把 `README.md:115`：

```
**continuous 模式**：栏板（wall/fence）沿路径首尾相连铺满，length 自适应段长，仅支持 wall/fence（length 沿 X）。fence 段接缝端柱重合会 z-fighting（preview 级，生产用 discrete 或待 v3 去重）。
```

替换为：

```
**continuous 模式**：栏板（wall/fence/ramp）沿路径首尾相连铺满，length 自适应段长，仅支持 wall/fence/ramp（length 沿 X）。fence 段接缝端柱由 v5 去重（放置层注入 start_post/end_post，端柱共享：所有段保首柱 + 仅末段保末柱）。ramp 接缝高度台阶为已知局限（留后续）。
```

- [ ] **Step 4: `README.md` — fence 参数表 `:93` 加 start_post/end_post**

把 `README.md:93`：

```
| `fence` | 手写 组合 | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04` |
```

替换为：

```
| `fence` | 手写 组合 | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04` / `start_post true` / `end_post true` |
```

- [ ] **Step 5: `docs/shapes-reference.md` — fence 参数表 `:22` 加 start_post/end_post**

把 `docs/shapes-reference.md:22`：

```
| `fence` | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04`（柱+横档） |
```

替换为：

```
| `fence` | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04` / `start_post true` / `end_post true`（柱+横档；continuous 模式放置层自动注入 start/end_post 端柱共享，单件/discrete 默认 true） |
```

- [ ] **Step 6: `docs/shapes-reference.md` — ramp `:12` 加 continuous 注记**

把 `docs/shapes-reference.md:12`：

```
| `ramp` | `length 2` / `height 1` / `width 1`（语义化 prism，坡道，`left_to_right=0`） |
```

替换为：

```
| `ramp` | `length 2` / `height 1` / `width 1`（语义化 prism，坡道，`left_to_right=0`；v5 起支持 continuous 模式，接缝高度台阶为已知局限） |
```

- [ ] **Step 7: Commit**

```bash
git add docs/protocol.md README.md docs/shapes-reference.md
git commit -m "docs: v5 fence 端柱去重 + continuous 扩 ramp 文档同步（v5 Task 4）

- protocol/README continuous 白名单 wall/fence→wall/fence/ramp
- 端柱 z-fighting 遗留注记（误标 v3）改为 v5 已去重
- fence 参数表加 start_post/end_post
- ramp 加 continuous 注记（含已知局限）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 完成后验证（Step 6 编辑器手测，补 v5 闭环）

全部 4 task 完成后，在 Godot 编辑器（启插件 + 打开场景）跑 selftest + 手测验证 z-fighting 消除：

```bash
# selftest 全 PASS（含 v5 新增 continuous fence/ramp 4 条）
python tools/forge_client.py --selftest

# 视觉验证：L 路径 continuous fence，转角处端柱单根（v4 va 下重叠更明显，v5 应消除）
python tools/forge_client.py path fence --path '[[0,0,0],[3,0,0],[3,0,3]]' --count 3 --mode continuous --mat wood

# continuous ramp 白名单放行
python tools/forge_client.py path ramp --path '[[0,0,0],[3,0,0]]' --count 3 --mode continuous --mat stone
```

预期：selftest 全 PASS（含 `generate_path continuous fence（3/3）` + `continuous fence undo（freed 3）` + `continuous ramp（3/3）` + `continuous ramp undo（freed 3）`）；编辑器视口 L 路径转角处 fence 端柱单根无重叠。
