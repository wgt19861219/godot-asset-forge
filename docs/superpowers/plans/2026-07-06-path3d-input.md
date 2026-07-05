# Path3D 节点输入（v3）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `generate_path` 加 `path_node` 字段——bash 引用场景里的 Path3D 节点，plugin 读 `curve.get_baked_points()` + `to_global` 作为 path，复用 v1/v2 采样与放置；result 加 `total` 字段解 predict_n path_node+spacing 阻塞 + 修 v1/v2 浮点隐患。

**Architecture:** minimal-diff。新增 `ScenePlacer.resolve_path3d` 静态（path_node → Array[Vector3]，可单测）+ plugin `_on_command` 分流 + `_handle_generate_path` 入口 path 源分流（A1 root 提前 + A7 samples 空守卫）+ `_place_one` 加 total 参数（result 带 total）+ forge_client `--path-node` + `send_and_recv_batch` 支持 total 收齐。PathGenerator + command_server 零改动。

**Tech Stack:** GDScript（Godot 4.6，@tool）/ Python 3（forge_client.py + pytest）/ WebSocket JSON。

## Global Constraints

- Godot 4.6.3 Forward+；缩进 = **Tab**；注释一律简体中文
- `ε = 1e-4`（v1 F1，沿用）；`BATCH_LIMIT = 64`；错误码归并 `invalid_params` + message
- Path3D 输入：`curve.get_baked_points()` 返**局部坐标**，必须 `path3d.to_global(v)` 转世界（关键陷阱）
- `path` / `path_node` **互斥**（同时或都无 → invalid_params）
- result 加 `"total": int` 字段（D 方案，所有 generate_path result 都带）
- A1：root + no_active_scene 校验提前到 path 源分流之前（v2 的 root 在 sample 之后，path_node 会崩）
- A7：sample 后 `if samples.is_empty(): invalid_params`（continuous 短曲线 0 段 + client 卡死隐患）
- 静态类 `class_name X extends RefCounted`，全局注册不 preload
- 跑测试：`D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
- pytest：`python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`

## 实施细化（spec → plan）

spec §1 的 `_resolve_path_node`（plugin helper）抽到 **`ScenePlacer.resolve_path3d(root, path_node)` 静态方法**——plugin 是 EditorPlugin headless 加载不了，抽到 ScenePlacer 静态可独立单测（spec §2.6 测试矩阵 #1-8 才能跑）。设计不变（plugin 调 `ScenePlacer.resolve_path3d`，与 `_resolve_parent` 并列）。

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `addons/asset_forge/scene_placer.gd` | 新增 `resolve_path3d(root, path_node)` 静态（Path3D → Array[Vector3] + to_global）| Task 1 |
| `tests/test_scene_placer.gd` | 加 path3d 用例（to_global + 6 错误分支）| Task 1 |
| `addons/asset_forge/asset_forge_plugin.gd` | `_on_command` 分流 + `_handle_generate_path` 入口（A1 root 提前 + path 源分流 + A7 守卫）+ `_place_one` 加 total | Task 2 |
| `tools/forge_client.py` | `--path-node` + `build_path_payload` + `send_and_recv_batch` total 收齐 + `run_path` 降级 | Task 3 |
| `tests/test_forge_client_predict.py` | pytest total 收齐用例（T1）| Task 3 |
| `tests/test_command_server.gd` | path_node 透传 + result total 集成测试 | Task 4 |
| `docs/protocol.md` / `README.md` | path_node + total 字段 + 示例 + parent/跨场景/baked_points 注记 | Task 4 |
| `tools/forge_client.py`（`run_selftest`）| path_node 集成自检 | Task 4 |

---

## Task 1: ScenePlacer.resolve_path3d + 单测

**Files:**
- Modify: `addons/asset_forge/scene_placer.gd`（新增 `resolve_path3d` 静态）
- Modify: `tests/test_scene_placer.gd`（追加 path3d 用例）

**Interfaces:**
- Consumes: v1 `ScenePlacer._resolve_parent(root, path)`（路径解析，复用）
- Produces: `ScenePlacer.resolve_path3d(root: Node, path_node: String) -> Dictionary{points: Array, error: String}`（points = baked_points 经 to_global；error 空 = 成功）

- [ ] **Step 1: 追加失败测试到 `tests/test_scene_placer.gd` 的 `run()` 末尾**

```gdscript
	# === ScenePlacer.resolve_path3d（v3 path_node）===
	# 构造 root + Path3D + Curve3D
	var r3 := Node3D.new()
	r3.name = "Root"
	runner.root.add_child(r3)
	# #1 Path3D 在原点 → points == baked_points（局部=世界）
	var p0 := Path3D.new()
	p0.name = "Path0"
	r3.add_child(p0)
	p0.curve = Curve3D.new()
	p0.curve.add_point(Vector3(0, 0, 0))
	p0.curve.add_point(Vector3(2, 0, 0))
	p0.curve.add_point(Vector3(4, 0, 0))
	var res0 := ScenePlacer.resolve_path3d(r3, "Path0")
	runner.check(res0["error"] == "", "resolve_path3d 原点 Path3D 无 error")
	runner.check(res0["points"].size() >= 2, "resolve_path3d 返回 baked_points（>=2 点）")
	runner.check(
		(res0["points"][0] as Vector3).is_equal_approx(Vector3(0, 0, 0)),
		"resolve_path3d 原点首点 = (0,0,0)"
	)
	# #2 Path3D 在 (10,0,0) → to_global 含位移
	var p1 := Path3D.new()
	p1.name = "Path1"
	p1.position = Vector3(10, 0, 0)
	r3.add_child(p1)
	p1.curve = Curve3D.new()
	p1.curve.add_point(Vector3(0, 0, 0))
	p1.curve.add_point(Vector3(2, 0, 0))
	var res1 := ScenePlacer.resolve_path3d(r3, "Path1")
	runner.check(
		(res1["points"][0] as Vector3).is_equal_approx(Vector3(10, 0, 0)),
		"resolve_path3d to_global 含位移（首点 0,0,0 → 10,0,0）"
	)
	# #3 Path3D 旋转 90°（绕 Y）→ to_global 含旋转
	var p2 := Path3D.new()
	p2.name = "Path2"
	p2.rotation = Vector3(0, deg_to_rad(90), 0)
	r3.add_child(p2)
	p2.curve = Curve3D.new()
	p2.curve.add_point(Vector3(0, 0, 0))
	p2.curve.add_point(Vector3(2, 0, 0))  # 局部 +X → 世界 +Z（旋转 90°）
	var res2 := ScenePlacer.resolve_path3d(r3, "Path2")
	runner.check(
		abs((res2["points"][1] as Vector3).z - 2.0) < 0.001,
		"resolve_path3d to_global 含旋转（局部 +X → 世界 +Z）"
	)
	# #4 curve == null
	var p3 := Path3D.new()
	p3.name = "Path3"
	r3.add_child(p3)
	# p3.curve 默认 null（不设）
	var res3 := ScenePlacer.resolve_path3d(r3, "Path3")
	runner.check(res3["error"] != "", "resolve_path3d curve 未设置 → error")
	# #5 baked_points < 2（单点曲线）
	var p4 := Path3D.new()
	p4.name = "Path4"
	r3.add_child(p4)
	p4.curve = Curve3D.new()
	p4.curve.add_point(Vector3(0, 0, 0))  # 仅 1 点
	var res4 := ScenePlacer.resolve_path3d(r3, "Path4")
	runner.check(res4["error"] != "", "resolve_path3d baked_points < 2 → error")
	# #6 path_node 非 Path3D（MeshInstance3D）
	var m := MeshInstance3D.new()
	m.name = "NotPath"
	r3.add_child(m)
	var res5 := ScenePlacer.resolve_path3d(r3, "NotPath")
	runner.check(
		String(res5["error"]).find("必须是 Path3D") >= 0,
		"resolve_path3d 非 Path3D → error 含「必须是 Path3D」"
	)
	# #7 节点名不存在
	var res6 := ScenePlacer.resolve_path3d(r3, "NotExist")
	runner.check(
		String(res6["error"]).find("未找到") >= 0, "resolve_path3d 节点不存在 → error 含「未找到」"
	)
	# 清理
	r3.queue_free()
```

- [ ] **Step 2: 跑测试确认失败（resolve_path3d 不存在）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: ScenePlacer suite FAIL（"Function 'resolve_path3d()' not found"）。

- [ ] **Step 3: 新增 `resolve_path3d` 到 `scene_placer.gd`（在 `_resolve_parent` 之后）**

```gdscript
# v3 path_node：读 Path3D 节点 → curve.baked_points → to_global（局部→世界）→ Array[Vector3]
# 失败返 {"points": [], "error": "..."}；成功返 {"points": Array[Vector3], "error": ""}
static func resolve_path3d(root: Node, path_node: String) -> Dictionary:
	var node: Node = _resolve_parent(root, path_node)
	if node == null:
		return {"points": [], "error": "path_node 节点未找到: " + path_node}
	if not (node is Path3D):
		return {"points": [], "error": "path_node 必须是 Path3D 节点，实际类型: " + node.get_class()}
	var path3d: Path3D = node as Path3D
	if path3d.curve == null:
		return {"points": [], "error": "Path3D curve 未设置（请在编辑器绘制曲线）"}
	var baked: PackedVector3Array = path3d.curve.get_baked_points()
	if baked.size() < 2:
		return {"points": [], "error": "Path3D curve baked points < 2（需至少 2 点定义路径）"}
	var points: Array = []
	for v in baked:
		points.append(path3d.to_global(v))  # 局部→世界坐标
	return {"points": points, "error": ""}
```

- [ ] **Step 4: 跑全套 headless 确认绿（含 v1/v2 零回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`（v1/v2 不回归 + path3d 新增约 10 用例）。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/scene_placer.gd tests/test_scene_placer.gd
git commit -m "feat: ScenePlacer.resolve_path3d 静态 + 单测（v3 Task 1）

Path3D 节点 → curve.baked_points → to_global → Array[Vector3]。
7 个测试用例：原点/位移/旋转 to_global + 4 个错误分支。
spec: docs/superpowers/specs/2026-07-06-path3d-input-design.md"
```

---

## Task 2: plugin 分流 + A1 root 提前 + A7 samples 空守卫 + _place_one total

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd`（`_on_command` + `_handle_generate_path` + `_place_one`）

**Interfaces:**
- Consumes: Task 1 `ScenePlacer.resolve_path3d(root, path_node)`；v1/v2 `PathGenerator.validate/sample/parse_path`；`_place_one`（v2）
- Produces: `_on_command` 分流（path or path_node）；`_handle_generate_path` 入口 path 源分流 + A1 root 提前 + A7 samples 空；`_place_one` 加 `total` 参数（result 带 `"total"`）

**注意**：plugin 是 EditorPlugin，headless 不加载。Task 2 验证 = 编译通过（headless 全套不回归）+ 端到端集成在 Task 4。

- [ ] **Step 1: 改 `_on_command` 分流条件（asset_forge_plugin.gd，`if payload.has("path"):` 那行）**

```gdscript
	# v3：path 或 path_node 都触发 path 分支（v2 仅 path）
	if payload.has("path") or payload.has("path_node"):
		_handle_generate_path(payload, batch_id, req_id, ws)
		return
```

- [ ] **Step 2: 改 `_handle_generate_path` 入口（A1 root 提前 + path 源分流 + A7 samples 空）**

在现有 `_handle_generate_path` 最前面（mode 校验之后、parse_path 之前）插入 path 源分流，并把 root 取值提前。具体：

把 mode 校验之后原本直接 `parse_path` 的部分，改为：
```gdscript
	# A1：root 提前取（path_node 解析 + 后续 place 都需 root；v2 的 root 取值从 sample 之后提到最前）
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_server.send_result(
			req_id, false, {"error": "no_active_scene", "message": "无活动场景"}, ws
		)
		return
	# v3：path/path_node 互斥 + path 源分流
	if payload.has("path") and payload.has("path_node"):
		_server.send_result(
			req_id,
			false,
			{"error": "invalid_params", "message": "path 与 path_node 互斥"},
			ws
		)
		return
	if not payload.has("path") and not payload.has("path_node"):
		_server.send_result(
			req_id,
			false,
			{"error": "invalid_params", "message": "必须提供 path 或 path_node 之一"},
			ws
		)
		return
	var points: Array
	if payload.has("path_node"):
		var resolved: Dictionary = ScenePlacer.resolve_path3d(root, String(payload["path_node"]))
		if String(resolved["error"]) != "":
			_server.send_result(
				req_id, false, {"error": "invalid_params", "message": String(resolved["error"])}, ws
			)
			return
		points = resolved["points"]
	else:
		var parsed: Dictionary = PathGenerator.parse_path(payload.get("path", []))
		if String(parsed["error"]) != "":
			_server.send_result(
				req_id, false, {"error": "invalid_params", "message": String(parsed["error"])}, ws
			)
			return
		points = parsed["points"]
	# 以下复用 v1/v2：validate/sample（含 mode）/ BATCH_LIMIT / shape/material / place 循环
	var spacing: float = float(payload.get("spacing", 0.0))
	var count: int = int(payload.get("count", 0))
	var align: String = String(payload.get("align", "path"))
	var include_endpoints: bool = bool(payload.get("include_endpoints", true))
	var verr: String = PathGenerator.validate(points, spacing, count, align, include_endpoints, mode)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	var samples: Array = PathGenerator.sample(points, spacing, count, align, include_endpoints, mode)
	# A7：samples 空（continuous 短曲线 0 段）→ invalid_params（防 client 卡死）
	if samples.is_empty():
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				"采样点为 0（路径太短 / spacing 过大 / continuous + total<spacing），无法生成"
			},
			ws
		)
		return
	if samples.size() > _Server.BATCH_LIMIT:
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				"samples 上限 %d，实际 %d" % [_Server.BATCH_LIMIT, samples.size()]
			},
			ws
		)
		return
	# shape/material/base_name（v1/v2 逻辑保留，但 root 已在入口取，删除 v2 后续的 root 取值 + no_active_scene 重复校验）
```

**关键**：删除 v2 在 sample 之后那段 `var root: Node = EditorInterface.get_edited_scene_root(); if root == null: ...`（已提前到入口 A1）。后续 probe_mesh/material/base_name/mode 分流逻辑保留，但 `_place_one` 调用要传 `samples.size()`（见 Step 3）。

- [ ] **Step 3: 改 `_place_one` 加 total 参数 + result 加 total 字段**

`_place_one` 签名加 `total: int` 参数（在 `batch_id` 之后或末尾），result dict 加 `"total": total`：
```gdscript
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
	total: int,  # v3 新增
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
			{
				"node_path": String(r["node_path"]),
				"resource_path": String(r["resource_path"]),
				"total": total  # v3 新增（D 方案：client 收第一条读 total 收齐）
			},
			ws
		)
		if _dock:
			_dock.add_to_generated_list(String(place_payload["name"]), String(r["node_path"]))
	else:
		_server.send_result(
			req_id,
			false,
			{"error": String(r["error"]), "message": "place 失败", "total": total},
			ws
		)
```

并更新 `_handle_generate_path` 两处循环调用 `_place_one` 传 `samples.size()` 作为 total（discrete 和 continuous 分支都加 `samples.size()` 实参）。

- [ ] **Step 4: 跑 headless 确认 plugin.gd 编译无错（全套不回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`（与 Task 1 一致，无回归 = plugin.gd 编译通过）。

- [ ] **Step 5: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd
git commit -m "feat: plugin path_node 分流 + A1 root 提前 + A7 samples 空守卫 + _place_one total（v3 Task 2）

_on_command: path or path_node 分流；
_handle_generate_path: A1 root 提前到 path 源分流之前 + path/path_node 互斥 +
  ScenePlacer.resolve_path3d 调用 + A7 samples 空 invalid_params；
_place_one: 加 total 参数，result 带 total（D 方案）。
集成验证在 Task 4 selftest。"
```

---

## Task 3: forge_client --path-node + send_and_recv_batch total 收齐

**Files:**
- Modify: `tools/forge_client.py`（`--path-node` argparse + `build_path_payload` + `send_and_recv_batch` + `run_path`）
- Modify: `tests/test_forge_client_predict.py`（pytest total 用例，T1）

**Interfaces:**
- Consumes: Task 2 result `"total"` 字段
- Produces: `--path-node` 参数；`send_and_recv_batch(ws, msg, n=None)` 支持 total 收齐；`run_path` D 方案（predict_n 降级预校验）

- [ ] **Step 1: 追加 pytest 到 `tests/test_forge_client_predict.py`（T1：send_and_recv_batch total 收齐）**

```python
import asyncio
from forge_client import send_and_recv_batch


class _FakeWS:
    """模拟 WebSocketPeer：按预置消息序列返回，记录 send 的消息。"""
    def __init__(self, responses):
        self._responses = list(responses)
        self.sent = []

    async def send(self, raw):
        self.sent.append(raw)

    async def recv(self):
        await asyncio.sleep(0)
        return self._responses.pop(0)


def test_send_and_recv_batch_by_total():
    """n=None：靠 result 第一条的 total 收齐（D 方案，path_node 模式）。"""
    msgs = [
        '{"type":"generate_result","id":"r","success":true,"node_path":"/a","total":3}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/b","total":3}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/c","total":3}',
    ]
    ws = _FakeWS([m.encode() for m in msgs])
    results = asyncio.run(send_and_recv_batch(ws, {"type": "generate_path", "id": "r"}, n=None))
    assert len(results) == 3
    assert all(r["success"] for r in results)


def test_send_and_recv_batch_n_compatible():
    """n 传了：按 n 收齐（v1/v2 batch 兼容，result 不带 total）。"""
    msgs = [
        '{"type":"generate_result","id":"r","success":true,"node_path":"/a"}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/b"}',
    ]
    ws = _FakeWS([m.encode() for m in msgs])
    results = asyncio.run(send_and_recv_batch(ws, {"type": "generate_batch", "id": "r"}, n=2))
    assert len(results) == 2
```

- [ ] **Step 2: 跑 pytest 确认失败（send_and_recv_batch 不接 n=None / 不读 total）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 2 个新 test FAIL（send_and_recv_batch 当前按 n 收齐，n=None 死循环或报错）。

- [ ] **Step 3: 改 `send_and_recv_batch` 支持 total 收齐**

把现有 `send_and_recv_batch` 改为：
```python
async def send_and_recv_batch(ws, msg, n=None):
    """发 1 条，收齐 per-item result。
    n=None（D 方案，generate_path）：靠 result 第一条的 total 收齐。
    n 给定（v1/v2 batch 兼容）：按 n 收齐。
    success=false（fatal error）：立即退出。
    """
    await ws.send(json.dumps(msg, ensure_ascii=False))
    req_id = msg.get("id")
    results = []
    total = n  # caller 传 n 则用 n（batch 兼容）；None 则靠 server total
    while True:
        try:
            data = json.loads(await asyncio.wait_for(ws.recv(), timeout=30.0))
        except asyncio.TimeoutError:
            print(
                f"等待 server 响应超时（30s 无消息），已收 {len(results)}/{total}",
                file=sys.stderr,
            )
            sys.exit(5)
        if (
            data.get("type") == "generate_result"
            and data.get("id") == req_id
        ):
            results.append(data)
            # fatal error（success=false）→ 立即退出（不等 total/n）
            if data.get("success") is False:
                break
            # 第一条读 server total（D 方案）
            if total is None:
                total = data.get("total")
            if total is not None and len(results) >= int(total):
                break
    return results
```

- [ ] **Step 4: 加 `--path-node` argparse（在 `--no-endpoints` 之后）**

```python
    p.add_argument(
        "--path-node",
        default=None,
        help="path 模式：场景里 Path3D 节点路径（如 /Root/MyPath），与 --path/--path-file 三互斥",
    )
```

- [ ] **Step 5: 改 `build_path_payload` 加 path_node + 三互斥**

把现有 `build_path_payload` 开头（`payload = {"shape": args.shape}`）改为接收 path + path_node，加互斥校验：
```python
def build_path_payload(args, path):
    payload = {"shape": args.shape}
    if args.path_node is not None:
        payload["path_node"] = args.path_node
    elif path is not None:
        payload["path"] = path
    # path/path_file/path_node 三互斥在 run_path 已校验，这里只构造
    if args.name:
        payload["name"] = args.name
    # ...（其余 material/spacing/count/align/include_endpoints/parent/save/params 逻辑保留不变）
```

- [ ] **Step 6: 改 `run_path` 加 path_node 分流 + predict_n 降级（D 方案）**

把现有 `run_path` 改为：
```python
async def run_path(args):
    """path 阵列：path JSON 或 path_node（Path3D 节点）。
    D 方案：n=None 靠 server result 的 total 收齐（predict_n 仅 path 模式预校验）。"""
    # path 源解析 + 三互斥校验
    path_sources = [args.path, args.path_file, args.path_node]
    if sum(1 for s in path_sources if s is not None) > 1:
        print("--path / --path-file / --path-node 三互斥", file=sys.stderr)
        sys.exit(2)
    if args.path_node is not None:
        path = None  # path_node 模式，client 不知曲线长
    else:
        path = _parse_path_arg(args)
        if path is None:
            sys.exit(2)

    spacing = args.spacing if args.spacing is not None else 0.0
    count = args.count if args.count is not None else 0
    include_endpoints = not args.no_endpoints

    # predict_n 仅 path 模式预校验（path_node 模式 client 不知 total_len，跳过，靠 server total）
    if path is not None:
        n = predict_n(path, spacing, count, include_endpoints, args.mode)
        if n == 0:
            print(
                "path 参数错误：需 --spacing >0 或 --count >=1（且二选一）",
                file=sys.stderr,
            )
            sys.exit(2)
        if n > 64:
            print(
                f"采样点 {n} 超过 BATCH_LIMIT 64（缩短路径/增大 spacing/减少 count）",
                file=sys.stderr,
            )
            sys.exit(2)

    ws = await connect_and_handshake(args)
    payload = build_path_payload(args, path)
    # D 方案：n=None，靠 server result 的 total 字段收齐
    results = await send_and_recv_batch(
        ws, {"type": "generate_path", "id": "r_path", "payload": payload}, n=None
    )
    all_ok = all(bool(r.get("success")) for r in results)
    aggregated = {"success": all_ok, "results": results, "count": len(results)}
    print(json.dumps(aggregated, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if all_ok else 1)
```

并改 main() 的命令分发：当前 `if args.path is not None or args.path_file is not None:` 改为也含 `args.path_node`：
```python
    if args.path is not None or args.path_file is not None or args.path_node is not None:
        asyncio.run(run_path(args)); return
```

- [ ] **Step 7: 跑 pytest 确认绿（v1/v2 + v3 全过）**

Run: `python -m pytest D:\GitHub\godot-asset-forge\tests\test_forge_client_predict.py -v`
Expected: 13 passed（v1 6 + v2 5 + v3 2）。

- [ ] **Step 8: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_predict.py
git commit -m "feat: forge_client --path-node + send_and_recv_batch total 收齐（v3 Task 3）

--path-node argparse + build_path_payload path_node + 三互斥；
send_and_recv_batch 支持 n=None（D 方案：靠 result total 收齐，path_node 模式可用）；
run_path: predict_n 降级为 path 模式预校验，path_node 模式靠 server total。
pytest 13 passed（v1 6 + v2 5 + v3 2）。"
```

---

## Task 4: command_server 集成测试 + 文档 + selftest + 端到端验证

**Files:**
- Modify: `tests/test_command_server.gd`（path_node 透传 + result total 集成检查）
- Modify: `docs/protocol.md`（path_node + total 字段）
- Modify: `README.md`（path_node 示例 + parent/跨场景/baked_points 注记）
- Modify: `tools/forge_client.py`（`run_selftest` 加 path_node 用例——需编辑器场景里有 Path3D，或跳过 selftest path_node 改文档说明）

**Interfaces:**
- Consumes: Task 1-3 全部产物

- [ ] **Step 1: 改 `tests/test_command_server.gd` 加 path_node 透传 + result total 检查**

在现有 generate_path mode 透传测试块之后追加：
```gdscript
	# === v3：path_node 字段透传 + result total 字段（command_server 零改动验证）===
	recv.clear()
	ws2.send_text(
		JSON.stringify(
			{
				"type": "generate_path",
				"id": "rpn",
				"payload":
					{"shape": "wall", "path_node": "/Root/NonExist", "count": 3, "mode": "continuous"}
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
		not recv.is_empty() and recv[0]["payload"].get("path_node") == "/Root/NonExist",
		"generate_path path_node 字段透传（command_server 零改动）"
	)
```

注意：command_server 测试只验证 payload 透传（不验证 plugin 处理，因 plugin 不在 test 环境）。result total 字段的端到端验证靠 Task 4 Step 4 selftest。

- [ ] **Step 2: 改 `docs/protocol.md` 的 generate_path 章节加 path_node + total 字段**

在 generate_path 章节的字段列表加（在 `path` 之后）：
```markdown
- `path_node`：可选，Path3D 节点路径（如 `/Root3D/MyPath`），与 `path` 互斥。plugin 读 `curve.get_baked_points()` + `to_global` 作为 path
```

在 result envelope 说明加：
```markdown
- `total`：int，采样点总数（discrete = 物件数 / continuous = 段数）。客户端可收第一条读 total 收齐（D 方案，path_node + spacing 模式必需）
```

并加 path_node 说明段：
```markdown
**path_node 模式**：引用场景里的 Path3D 节点，读其 curve 的 baked_points（Godot 已 tessellate 的密集点）+ to_global（局部→世界）作为 path。Path3D 节点必须在当前活动场景内（同 parent 约束）。建议 parent 留空（默认 root）；指定非 root parent 时，物件位置 = Path3D 世界坐标被当 parent 局部，parent 非原点会错位（与 path JSON 既有行为一致）。
```

- [ ] **Step 3: 改 `README.md` 加 path_node 示例 + 注记**

在「路径阵列」小节的示例代码块追加：
```markdown
# Path3D 节点输入（编辑器画曲线 → bash 引用）
python tools/forge_client.py path cylinder --path-node /Root/MyPath --count 8 --mat metal
python tools/forge_client.py path fence --path-node /Root/FencePath --spacing 2 --mode continuous --mat wood
```

在「朝向注记」段之后追加：
```markdown
**Path3D 节点输入（v3）**：`--path-node` 引用场景里的 Path3D 节点（curve 已平滑，baked_points 即密集折线，无需自实现 Catmull-Rom）。节点必须在当前活动场景；建议 parent 留空（非 root parent 会坐标错位）。超长曲线 baked_points 密度无上限（BATCH_LIMIT 只护物件数不护输入点数），极长路径建议先简化曲线。
```

- [ ] **Step 4: 端到端集成验证（编辑器 + Path3D + selftest 手测）**

`run_selftest` 不加 path_node 自动用例（selftest 依赖场景里已建 Path3D 节点，自动化建 Path3D 复杂；改为手测说明）。

启动编辑器（后台，`run_in_background: true`，**不要** `| tail`）：
```
D:\godot\Godot_v4.6.3-stable_win64.exe --editor --path D:\GitHub\godot-asset-forge "res://Demo.tscn" > /tmp/forge_v3.log 2>&1
```
等 15-20s，确认 60650 LISTENING + token。

**手测 path_node**（先在编辑器 Demo.tscn 里手动建一个 Path3D 节点，画一条曲线，命名 TestPath，保存场景）：
```
python tools/forge_client.py path cylinder --path-node /Root/TestPath --count 5 --mat metal
python tools/forge_client.py path fence --path-node /Root/TestPath --spacing 2 --mode continuous --mat wood
```
Expected: `{"success": true, "results": [...], "count": N}`，编辑器视口沿 TestPath 曲线生成灯柱/栅栏。

**手测 total 字段**（验证 D 方案）：跑 discrete path 命令，检查 result 第一条含 `"total": N`。

**手测 A7 守卫**：构造短路径 continuous + 大 spacing（如 path 长度 1 + spacing 5 + continuous），期望 `invalid_params`「采样点为 0」。

**手测 path_node 错误分支**：`--path-node /Root/NotExist` → invalid_params「未找到」；`--path-node /Root/Camera3D`（非 Path3D）→ invalid_params「必须是 Path3D」。

关编辑器：`taskkill //PID <PID> //F`。

- [ ] **Step 5: 跑 headless 全套确认绿（含 path_node 透传 check + v1/v2 零回归）**

Run: `D:\godot\Godot_v4.6.3-stable_win64.exe --headless --path D:\GitHub\godot-asset-forge --script res://tests/test_runner.gd`
Expected: 全套 `N passed, 0 failed`（v1/v2 不回归 + path_node 透传 check）。

- [ ] **Step 6: Commit**

```bash
git add tests/test_command_server.gd docs/protocol.md README.md
git commit -m "feat+docs: path_node 透传测试 + 文档 + total 字段（v3 Task 4）

command_server path_node 透传测试（零改动验证）；
protocol.md / README 加 path_node + total 字段 + 示例 + parent/跨场景/baked_points 注记。
端到端手测：path_node wall/fence + total + A7 守卫 + 错误分支全过。"
```

---

## 验收清单（全部 task 完成后）

- [ ] `tests/test_runner.gd` headless 全套 0 failed（v1/v2 + Task 1 path3d 约 10 + Task 4 透传 1）
- [ ] `pytest tests/test_forge_client_predict.py` 13 passed（v1 6 + v2 5 + v3 2）
- [ ] `path cylinder --path-node /Root/TestPath --count N` 在编辑器视口沿 Path3D 曲线生成灯柱
- [ ] `path fence --path-node /Root/TestPath --mode continuous` 沿曲线铺围栏
- [ ] result 第一条含 `"total": N`（D 方案验证）
- [ ] A7 守卫：短路径 continuous + 大 spacing → invalid_params「采样点为 0」
- [ ] path_node 错误分支：节点不存在 / 非 Path3D / curve null / baked<2 → invalid_params
- [ ] v1/v2 全部行为零回归（discrete/continuous + path JSON + v1/v2 selftest）

## 已知限制（写进文档，非阻塞）

- path_node + parent≠root 坐标错位（文档说明，与 path JSON 一致）
- baked_points 密度无上限（BATCH_LIMIT 只护物件数，超长曲线 note）
- selftest 不含 path_node 自动用例（依赖场景手动建 Path3D）
- F7 完整（_handle_generate_path + 单件 generate helper）仍待第三生成器
