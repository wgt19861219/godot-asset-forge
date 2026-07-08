# claim 5 编排层可测性重构（Orchestrator 抽取）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `asset_forge_plugin.gd` 的 ~338 行编排逻辑（`_on_command`/`_handle_generate_path`/`_place_one`）抽到新类 `Orchestrator`（零 EditorInterface 依赖），补齐 22 case headless 测试（claim 5）。

**Architecture:** 编排逻辑搬入 `class_name Orchestrator extends RefCounted`，EditorInterface 调用（`get_edited_scene_root`/`mark_scene_as_unsaved`）通过 Callable 注入上移到 `plugin.gd` 薄胶水层。Orchestrator 纯 RefCounted 可 headless 测；plugin 退化为胶水（取 EditorInterface → 调 Orchestrator → 真发 mark）。

**Tech Stack:** Godot 4.6 / GDScript（`@tool`，Tab 缩进，中文注释）/ 自研 SceneTree 测试 runner / Python `forge_client.py` selftest

**Spec:** `D:\GitHub\godot-asset-forge\docs\superpowers\specs\2026-07-08-claim5-orchestrator-refactor-design.md`（commit df4dff5，已通过独立复审）

## Global Constraints

（从 spec §8/§11/§12 提取，每个 task 隐含遵守）

- Godot 4.6+，GDScript 顶格 `@tool`，缩进=Tab，注释简体中文，保留 `IMPORTANT-N`/`Q-N`/`A-N` 标记
- 全 `class_name` 全局注册（无 autoload）：`Orchestrator` 是 `class_name Orchestrator extends RefCounted`
- 测试用 `tests/test_runner.gd` 同款 SceneTree runner：`godot --headless --path . --script res://tests/test_runner.gd`（本机 godot 不在 PATH 时用 console 版绝对路径，见 `CLAUDE.md`）；**禁用 `mcp__godot__run_and_verify`**（class_name 跨文件假 not declared 坑）
- **R1**：`orchestrator.gd` 的 `var _server: RefCounted`（**非** `AssetForgeServer`，否则 MockServer 注不进）
- **R3**：`_undo_stack` 非所有者引用（Orchestrator 持引用，clear 责任在 `plugin._exit_tree`）
- **R6**：`orchestrator.gd` 顶格 `@tool`
- **R7**：undo 成功回执 message 保持 `"freed %d"`（selftest 6 处硬依赖，A.1/D.19 显式断言）
- GDScript lambda 捕获用数组（避值拷贝陷阱，见 `test_command_server.gd:3`）：`marked=[false]`、`added=[]`、`calls=[0]`
- 频繁 commit（每 task 末）

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `addons/asset_forge/orchestrator.gd` | 编排层（`handle_command` + `_handle_generate_path` + `_place_one`），零 EditorInterface 依赖 | Create |
| `tests/test_orchestrator.gd` | 第 6 suite，22 case + `MockServer` inner class + `_make_orch` helper | Create |
| `addons/asset_forge/asset_forge_plugin.gd` | 退化为胶水（`_orch` 装配 + `_on_command` 透传 + 3 包装方法 `_get_root`/`_mark_unsaved`/`_dock_add`，删 `_handle_generate_path`/`_place_one`） | Modify |
| `tests/test_runner.gd` | `_process` 加一行 `_run_suite("Orchestrator", ...)` 注册第 6 suite | Modify |

---

## Task 1: 创建 orchestrator.gd（复制编排逻辑，plugin 不切换）

**Files:**
- Create: `addons/asset_forge/orchestrator.gd`

**Interfaces:**
- Produces: `class_name Orchestrator extends RefCounted`
  - `func _init(server: RefCounted, undo_stack: Array, get_root: Callable, mark_unsaved: Callable, dock_add: Callable) -> void`
  - `func handle_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void`
  - 内部 `_handle_generate_path(payload, batch_id, req_id, ws)` / `_place_one(...)` 签名不变（从 plugin 原样搬）

- [ ] **Step 1: 创建 orchestrator.gd 骨架 + handle_command 三分支路由**

创建 `addons/asset_forge/orchestrator.gd`，写入骨架与 `handle_command` 的 undo/path 分支（generate 分支体从 plugin 复制，见 Step 2）：

```gdscript
# orchestrator.gd
# 编排层（claim 5）。从 asset_forge_plugin.gd 搬入 handle_command/_handle_generate_path/_place_one。
# EditorInterface 副作用（get_edited_scene_root / mark_scene_as_unsaved）通过 Callable 注入，
# 本类零 EditorInterface 依赖 → 可 headless 单测。
@tool
class_name Orchestrator
extends RefCounted

# R1（duck typing 换可测性）：_server 是唯一需 mock 的有状态依赖，去 AssetForgeServer 强类型注解。
# MockServer（inner class extends RefCounted）才注得进去。损失的类型安全由 22 case 补回。
var _server: RefCounted = null
# IMPORTANT-2（修订）：clear 责任单一 + 生命周期跟 plugin；Orchestrator 持【非所有者引用】。
# GDScript Array 引用语义：append/pop 直达 plugin 的栈；_exit_tree.clear() 仍由 plugin 执行。
var _undo_stack: Array = []
var _get_root: Callable       # 替 EditorInterface.get_edited_scene_root()
var _mark_unsaved: Callable   # 替 EditorInterface.mark_scene_as_unsaved()
var _dock_add: Callable       # 替 _dock.add_to_generated_list（plugin._dock_add 内部判 _dock null）


func _init(
	server: RefCounted,
	undo_stack: Array,
	get_root: Callable,
	mark_unsaved: Callable,
	dock_add: Callable
) -> void:
	_server = server
	_undo_stack = undo_stack
	_get_root = get_root
	_mark_unsaved = mark_unsaved
	_dock_add = dock_add


# plugin._on_command 信号槽直接转调此方法（req_id 在此首行自提，消除胶水层冗余）。
func handle_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	var req_id: String = String(payload.get("__req_id", ""))
	# undo（batch_id == -1）
	if bool(payload.get("__undo", false)):
		var ur := ScenePlacer.undo_last(_undo_stack)
		var ur_ok := bool(ur["success"])
		var undo_fields := {"error": String(ur["error"])}
		if ur_ok:
			undo_fields["message"] = "freed %d" % int(ur["freed"])  # P2#8：仅成功时塞 freed 文案（nothing_to_undo 不报 freed 0）
		_server.send_result(req_id, ur_ok, undo_fields, ws)
		return
	# generate_path（路径阵列）
	if payload.has("path") or payload.has("path_node"):
		_handle_generate_path(payload, batch_id, req_id, ws)
		return
	# generate（单件）—— 方法体从 asset_forge_plugin.gd:86-137 复制，应用 Step 2 替换表
	# [此处粘贴 plugin.gd:86-137 的 generate 分支体，按 Step 2 替换 EditorInterface/_dock 调用]
	pass


# _handle_generate_path —— 从 asset_forge_plugin.gd:141-363 复制方法体，应用 Step 2 替换表
# func _handle_generate_path(payload: Dictionary, batch_id: int, req_id: String, ws: WebSocketPeer) -> void:
# [粘贴 plugin.gd:141-363 方法体，按 Step 2 替换]


# _place_one —— 从 asset_forge_plugin.gd:367-414 原样复制（无 EditorInterface，仅 _dock_add 替换）
# func _place_one(root, mesh, material, base_name, i, pos_var, rot_var, payload, batch_id, total, req_id, ws) -> bool:
# [粘贴 plugin.gd:367-414 方法体，按 Step 2 替换 _dock.add_to_generated_list]
```

- [ ] **Step 2: 复制 plugin.gd 三个方法体 + 应用替换表**

从 `addons/asset_forge/asset_forge_plugin.gd` 复制 `_on_command`/`_handle_generate_path`/`_place_one` 的方法体到 orchestrator.gd 对应位置，应用下表替换（用编辑器查找替换，逐处核对行号）：

| 原文（plugin.gd） | 替换为（orchestrator.gd） | 位置 |
|---|---|---|
| `EditorInterface.get_edited_scene_root()` | `_get_root.call()` | 原 :108（单件取 root）、:154（path 取 root）、:134（单件 mark 前 can_mark_scene 第二参数）、:362（path mark 前 can_mark_scene 第二参数） |
| `EditorInterface.mark_scene_as_unsaved()` | `_mark_unsaved.call()` | 原 :135（单件 mark）、:363（path mark） |
| `_dock.add_to_generated_list(NAME, PATH)` | `_dock_add.call(NAME, PATH)` | 原 :132（单件）、:402-405（`_place_one` 内，两行 `add_to_generated_list` 调用） |
| `_on_command(payload, batch_id, ws)` | `handle_command(payload, batch_id, ws)` | 方法名（原 :71） |
| `handle_command` 内首行 `var req_id: String = String(payload.get("__req_id", ""))` | 保留（已是首行，`_handle_generate_path`/`_place_one` 仍接收 `req_id` 参数） | 原 :72 |

**mark 段完整示例**（最易错处，替换后样子）——单件 generate mark 段（原 :131-137）：

```gdscript
		if _dock_add.is_valid():
			_dock_add.call(String(place_payload["name"]), String(r["node_path"]))
		# P1-5：mark 前校验 root 仍有效且是当前场景（防场景切换竞态操作失效场景）
		if ScenePlacer.can_mark_scene(root, _get_root.call()):
			_mark_unsaved.call()
	else:
		_server.send_result(req_id, false, {"error": String(r["error"]), "message": "place 失败"}, ws)
```

path mark 段（原 :360-363）同理：`if any_success:` 内 `if ScenePlacer.can_mark_scene(root, _get_root.call()): _mark_unsaved.call()`。

> **`_dock_add.is_valid()` 守卫**：plugin 运行时 `_dock_add` 总有效（`Callable(self, "_dock_add")`）；但为防御 `_dock_add` 未注入时崩溃，加 `is_valid()` 守卫。测试注入的 callable 总有效，不影响。

- [ ] **Step 3: 跑现有 5 suite 确认不破坏**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: `=== Results: N passed, 0 failed ===`（N 与重构前相同，5 suite 全 PASS；orchestrator.gd 仅加载未被调用，确认无语法错、`class_name Orchestrator` 注册成功）

- [ ] **Step 4: Commit**

```bash
git add addons/asset_forge/orchestrator.gd
git commit -m "feat(claim5): 新增 orchestrator.gd 编排层（从 plugin 复制逻辑 + Callable 注入 EditorInterface）"
```

---

## Task 2: test_orchestrator.gd 基础设施 + 注册第 6 suite + A.1

**Files:**
- Create: `tests/test_orchestrator.gd`
- Modify: `tests/test_runner.gd`（`_process` 加一行）

**Interfaces:**
- Consumes: `Orchestrator`（Task 1）、`ScenePlacer`（place 进栈供 undo）
- Produces: 第 6 suite 注册；`MockServer` inner class；`_make_orch` helper

- [ ] **Step 1: 创建 test_orchestrator.gd 骨架（MockServer + _make_orch + run 开头 + root fixture）**

```gdscript
extends RefCounted
## orchestrator 编排层测试（claim 5，22 case）。覆盖 handle_command 三分支 + _handle_generate_path 校验链 + _place_one。
## MockServer inner class 记 send_result 调用；_get_root/_mark_unsaved/_dock_add 注入 Callable。
## 沿用 test_scene_placer 范式：Node3D root 入 runner.root 树使 ScenePlacer.place 的 NodePath 解析生效。


# MockServer：记录 send_result 调用（不调真实 ws send）。无 class_name（仅本文件用，避跨文件解析疑虑）。
class MockServer:
	extends RefCounted
	var sent: Array = []
	func send_result(req_id, ok, fields, ws) -> void:
		sent.append({"req_id": req_id, "ok": ok, "fields": fields})


# 常规 case 的 Orchestrator 工厂：_get_root 恒返 root、_mark_unsaved 捕获到 marked_arr[0]、_dock_add 捕获到 added_arr。
# P1-5 竞态 case（C 组）的 _get_root 是双值的，不 用此 helper，单独构造。
func _make_orch(
	mock: MockServer, stack: Array, root: Node, marked_arr: Array, added_arr: Array
) -> Orchestrator:
	return Orchestrator.new(
		mock,
		stack,
		func() -> Node: return root,
		func() -> void: marked_arr[0] = true,
		func(n: String, p: String) -> void: added_arr.append({"name": n, "path": p}),
	)


func run(runner) -> void:
	var root := Node3D.new()
	root.name = "Root"
	runner.root.add_child(root)
	var ws := WebSocketPeer.new()  # 未连接，纯透传（Orchestrator 不调 ws 方法，只转给 send_result）

	# === A.1 undo 成功（R7：message "freed %d" 契约）===
	# 前置：stack 先 place 1 节点（undo 才有东西弹）
	var stack_a1: Array = []
	ScenePlacer.place(root, BoxMesh.new(), null, {"name": "a1"}, stack_a1, 100)
	var mock_a1 := MockServer.new()
	var marked_a1 := [false]
	var orch_a1 := _make_orch(mock_a1, stack_a1, root, marked_a1, [])
	orch_a1.handle_command({"__req_id": "r1", "__undo": true}, -1, ws)
	runner.check(mock_a1.sent.size() == 1, "A.1 undo 发 1 条 result")
	if mock_a1.sent.size() == 1:
		runner.check(bool(mock_a1.sent[0]["ok"]), "A.1 undo success=true")
		runner.check(String(mock_a1.sent[0]["fields"].get("error", "")) == "", "A.1 undo 无 error")
		# R7：成功 message 必须为 "freed N"（selftest 6 处 msg.split()[-1] 硬依赖）
		var msg_a1 := String(mock_a1.sent[0]["fields"].get("message", ""))
		runner.check(
			msg_a1.begins_with("freed ") and msg_a1.split(" ")[-1].is_valid_int(),
			"A.1 R7：undo message='%s' 必须为 'freed N'（selftest 硬依赖，不得改文案）" % msg_a1
		)
		runner.check(msg_a1 == "freed 1", "A.1 undo freed=1（栈内 1 节点）")

	# [后续 case 在此处追加]

	# 清理 root
	runner.root.remove_child(root)
	root.free()
```

- [ ] **Step 2: 注册第 6 suite（test_runner.gd）**

Modify `tests/test_runner.gd:27`（`_run_suite("CommandServer", ...)` 之后加一行）：

```gdscript
	_run_suite("ScenePlacer", preload("res://tests/test_scene_placer.gd").new())
	_run_suite("CommandServer", preload("res://tests/test_command_server.gd").new())
	_run_suite("Orchestrator", preload("res://tests/test_orchestrator.gd").new())  # claim 5 第 6 suite
```

同步改 `test_runner.gd:4` 注释「注册 5 个 suite」→「注册 6 个 suite」。

- [ ] **Step 3: 跑 test_orchestrator，A.1 PASS**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: `--- Suite: Orchestrator ---` 下 `A.1` 三四条 PASS，`=== Results: N passed, 0 failed ===`（其余 5 suite 不受影响）

- [ ] **Step 4: Commit**

```bash
git add tests/test_orchestrator.gd tests/test_runner.gd
git commit -m "test(claim5): test_orchestrator 第6 suite 基础设施 + A.1 undo 成功（R7 freed 契约）"
```

---

## Task 3: A 组剩余 14 case（错误码，每 case 一个 step）

**Files:**
- Modify: `tests/test_orchestrator.gd`（`run()` 内「后续 case」处追加）

**约束（spec §7 步骤 2）**：error case 的断言依据 grep 旧 plugin 精确行为（error 码 + message 文案），不是凭设计意图——22 case 同时承担「旧行为回归测试」角色（selftest 不覆盖这些分支）。每 case 给出旧 plugin 行号指引。

- [ ] **Step 1: A.2 undo nothing_to_undo（空栈）**

```gdscript
	# === A.2 undo nothing_to_undo（空栈 → error；P2#8：不报 freed 0，无 message）===
	var mock_a2 := MockServer.new()
	var orch_a2 := _make_orch(mock_a2, [], root, [false], [])  # 空 stack
	orch_a2.handle_command({"__req_id": "r2", "__undo": true}, -1, ws)
	runner.check(mock_a2.sent.size() == 1, "A.2 undo 发 1 条 result")
	if mock_a2.sent.size() == 1:
		runner.check(not bool(mock_a2.sent[0]["ok"]), "A.2 nothing_to_undo success=false")
		runner.check(
			String(mock_a2.sent[0]["fields"].get("error")) == "nothing_to_undo",
			"A.2 error='nothing_to_undo'"
		)
		runner.check(
			not mock_a2.sent[0]["fields"].has("message"),
			"A.2 P2#8：nothing_to_undo 不塞 message（不报 freed 0）"
		)
```

- [ ] **Step 2: A.3a unsupported_shape 单件（:88-89 create_mesh null）**

```gdscript
	# === A.3a unsupported_shape 单件（create_mesh 未知 shape 返 null，旧 :88-89）===
	var mock_a3a := MockServer.new()
	var orch_a3a := _make_orch(mock_a3a, [], root, [false], [])
	orch_a3a.handle_command({"__req_id": "r3a", "shape": "badshape"}, 1, ws)
	runner.check(mock_a3a.sent.size() == 1, "A.3a 发 1 条 result")
	if mock_a3a.sent.size() == 1:
		runner.check(not bool(mock_a3a.sent[0]["ok"]), "A.3a success=false")
		runner.check(
			String(mock_a3a.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.3a error='unsupported_shape'"
		)
		# grep 旧 plugin:92-105 message 文案（含支持列表）
		runner.check(
			String(mock_a3a.sent[0]["fields"].get("message", "")).find("未知 shape: badshape") >= 0,
			"A.3a message 含 '未知 shape: badshape'"
		)
```

- [ ] **Step 3: A.3b unsupported_shape path（:282-296 probe_mesh null）**

```gdscript
	# === A.3b unsupported_shape path（discrete + badshape → :280 create_mesh null → :282-296）===
	# 注：continuous 白名单 :263-274 会先拦非 wall/fence/ramp shape，到不了 :282-296，故用 discrete
	var mock_a3b := MockServer.new()
	var orch_a3b := _make_orch(mock_a3b, [], root, [false], [])
	orch_a3b.handle_command(
		{"__req_id": "r3b", "shape": "badshape", "path": [[0, 0, 0], [3, 0, 0]], "count": 2}, 2, ws
	)
	runner.check(mock_a3b.sent.size() == 1, "A.3b 发 1 条 result")
	if mock_a3b.sent.size() == 1:
		runner.check(
			String(mock_a3b.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.3b path 分支 error='unsupported_shape'（:282-296 probe_mesh null）"
		)
```

- [ ] **Step 4: A.4a no_active_scene 单件（_get_root null；:113 长文案）**

```gdscript
	# === A.4a no_active_scene 单件（_get_root 返 null；:113 message 长文案）===
	var mock_a4a := MockServer.new()
	# _get_root 返 null（不用 _make_orch，单独构造 callable）
	var orch_a4a := Orchestrator.new(
		mock_a4a, [],
		func() -> Node: return null,
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a4a.handle_command({"__req_id": "r4a", "shape": "box"}, 1, ws)
	runner.check(mock_a4a.sent.size() == 1, "A.4a 发 1 条 result")
	if mock_a4a.sent.size() == 1:
		runner.check(
			String(mock_a4a.sent[0]["fields"].get("error")) == "no_active_scene",
			"A.4a error='no_active_scene'"
		)
		# grep 旧 plugin:113 —— 单件长文案（与 :157 path 短文案不同，已实证）
		runner.check(
			String(mock_a4a.sent[0]["fields"].get("message")) == "无活动场景，请先在编辑器新建或打开场景再 generate",
			"A.4a message='无活动场景，请先在编辑器新建或打开场景再 generate'（:113 长文案）"
		)
```

- [ ] **Step 5: A.4b no_active_scene path（_get_root null；:157 短文案）**

```gdscript
	# === A.4b no_active_scene path（_get_root 返 null；:157 message 短文案，与 A.4a 不同）===
	var mock_a4b := MockServer.new()
	var orch_a4b := Orchestrator.new(
		mock_a4b, [],
		func() -> Node: return null,
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a4b.handle_command(
		{"__req_id": "r4b", "shape": "cylinder", "path": [[0, 0, 0], [3, 0, 0]], "count": 2}, 2, ws
	)
	runner.check(mock_a4b.sent.size() == 1, "A.4b 发 1 条 result")
	if mock_a4b.sent.size() == 1:
		runner.check(
			String(mock_a4b.sent[0]["fields"].get("error")) == "no_active_scene",
			"A.4b path 分支 error='no_active_scene'"
		)
		# grep 旧 plugin:157 —— path 短文案
		runner.check(
			String(mock_a4b.sent[0]["fields"].get("message")) == "无活动场景",
			"A.4b message='无活动场景'（:157 短文案，与 A.4a 长文案不同）"
		)
```

- [ ] **Step 6: A.5 path↔path_node 互斥（同时有 → :161-168）**

```gdscript
	# === A.5 path↔path_node 互斥（同时提供 → :161-168 invalid_params）===
	# 注：旧 :169-176「都无」分支不可达（_on_command:83 进 _handle_generate_path 需 has path or path_node），
	# 故只测「同时有」互斥分支。
	var mock_a5 := MockServer.new()
	var orch_a5 := _make_orch(mock_a5, [], root, [false], [])
	orch_a5.handle_command(
		{
			"__req_id": "r5", "shape": "wall", "count": 2,
			"path": [[0, 0, 0], [3, 0, 0]], "path_node": "/Root/Path0"
		},
		5, ws
	)
	runner.check(mock_a5.sent.size() == 1, "A.5 发 1 条 result")
	if mock_a5.sent.size() == 1:
		runner.check(
			String(mock_a5.sent[0]["fields"].get("error")) == "invalid_params",
			"A.5 互斥 → invalid_params"
		)
		runner.check(
			String(mock_a5.sent[0]["fields"].get("message")).find("互斥") >= 0,
			"A.5 message 含 '互斥'"
		)
```

- [ ] **Step 7: A.6 mode 非 discrete/continuous（:146-152，root 取之前，不触发 _get_root）**

```gdscript
	# === A.6 mode 非法（:146-152 invalid_params；mode 校验在 :154 取 root 之前）===
	var mock_a6 := MockServer.new()
	var get_root_calls_a6 := [0]
	var orch_a6 := Orchestrator.new(
		mock_a6, [],
		func() -> Node: get_root_calls_a6[0] += 1; return root,  # 计数，验证 mode 先返不取 root
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	orch_a6.handle_command(
		{"__req_id": "r6", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "mode": "bad"},
		6, ws
	)
	runner.check(mock_a6.sent.size() == 1, "A.6 发 1 条 result")
	if mock_a6.sent.size() == 1:
		runner.check(
			String(mock_a6.sent[0]["fields"].get("error")) == "invalid_params",
			"A.6 mode 非法 → invalid_params"
		)
		runner.check(
			String(mock_a6.sent[0]["fields"].get("message")).find("mode 必须") >= 0,
			"A.6 message 含 'mode 必须'"
		)
	runner.check(get_root_calls_a6[0] == 0, "A.6 mode 校验在取 root 之前（_get_root 未被调）")
```

- [ ] **Step 8: A.7 continuous 白名单（shape 非 wall/fence/ramp → :263-274）**

```gdscript
	# === A.7 continuous 白名单（box 非 wall/fence/ramp → :263-274 unsupported_shape）===
	var mock_a7 := MockServer.new()
	var orch_a7 := _make_orch(mock_a7, [], root, [false], [])
	orch_a7.handle_command(
		{"__req_id": "r7", "shape": "box", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "mode": "continuous"},
		7, ws
	)
	runner.check(mock_a7.sent.size() == 1, "A.7 发 1 条 result")
	if mock_a7.sent.size() == 1:
		runner.check(
			String(mock_a7.sent[0]["fields"].get("error")) == "unsupported_shape",
			"A.7 continuous box → unsupported_shape（白名单）"
		)
		# grep 旧 plugin:263-274
		runner.check(
			String(mock_a7.sent[0]["fields"].get("message")).find("continuous 模式仅支持") >= 0,
			"A.7 message 含 'continuous 模式仅支持'"
		)
```

- [ ] **Step 9: A.8 samples 空（continuous 短路径 + include_endpoints=false → :235-246）**

```gdscript
	# === A.8 samples 空（spacing>total + include_endpoints=false → boundaries=[0] → 0 段 → :235-246）===
	var mock_a8 := MockServer.new()
	var orch_a8 := _make_orch(mock_a8, [], root, [false], [])
	orch_a8.handle_command(
		{
			"__req_id": "r8", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"spacing": 10.0, "mode": "continuous", "include_endpoints": false
		},
		8, ws
	)
	runner.check(mock_a8.sent.size() == 1, "A.8 发 1 条 result")
	if mock_a8.sent.size() == 1:
		runner.check(
			String(mock_a8.sent[0]["fields"].get("error")) == "invalid_params",
			"A.8 samples 空 → invalid_params"
		)
		runner.check(
			String(mock_a8.sent[0]["fields"].get("message")).find("采样点为 0") >= 0,
			"A.8 message 含 '采样点为 0'"
		)
```

- [ ] **Step 10: A.9 spacing 路径 pre_est 拦截（:220-230 via :215 分支）**

```gdscript
	# === A.9 pre_est 超上限（spacing 路径 :215 → :220-230）===
	# 注：spec 标 :247-259（samples>BATCH_LIMIT），但 pre_est :210-230 是上界（spec §7:212 自述），
	# samples 永远 ≤ pre_est，:247-259 是不可达死防线。A.9 改测 spacing 路径的 pre_est 拦截（:215 分支），
	# 与 A.10（count 路径 :217 分支）互补，覆盖 pre_est 两个计算分支。
	var mock_a9 := MockServer.new()
	var orch_a9 := _make_orch(mock_a9, [], root, [false], [])
	orch_a9.handle_command(
		{
			"__req_id": "r9", "shape": "wall", "path": [[0, 0, 0], [100, 0, 0]],
			"spacing": 1.0, "mode": "continuous"  # total=100 → pre_est=100/1+2=102 > 64
		},
		9, ws
	)
	runner.check(mock_a9.sent.size() == 1, "A.9 发 1 条 result")
	if mock_a9.sent.size() == 1:
		runner.check(
			String(mock_a9.sent[0]["fields"].get("error")) == "invalid_params",
			"A.9 pre_est 超上限 → invalid_params"
		)
		runner.check(
			String(mock_a9.sent[0]["fields"].get("message")).find("采样点预估") >= 0,
			"A.9 message 含 '采样点预估'"
		)
```

- [ ] **Step 11: A.10 count 路径 pre_est 拦截（:220-230 via :217 分支）**

```gdscript
	# === A.10 pre_est 超上限（count 路径 :217 → :220-230）===
	var mock_a10 := MockServer.new()
	var orch_a10 := _make_orch(mock_a10, [], root, [false], [])
	orch_a10.handle_command(
		{"__req_id": "r10", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]], "count": 64, "mode": "continuous"},
		# count=64 → pre_est=64+1=65 > 64
		10, ws
	)
	runner.check(mock_a10.sent.size() == 1, "A.10 发 1 条 result")
	if mock_a10.sent.size() == 1:
		runner.check(
			String(mock_a10.sent[0]["fields"].get("error")) == "invalid_params",
			"A.10 pre_est 超上限 → invalid_params"
		)
```

- [ ] **Step 12: A.11 path parse 错（parse_path 非 Array → :192-197）**

```gdscript
	# === A.11 path parse 错（path 非 Array → parse_path :12-14 error → :192-197）===
	var mock_a11 := MockServer.new()
	var orch_a11 := _make_orch(mock_a11, [], root, [false], [])
	orch_a11.handle_command(
		{"__req_id": "r11", "shape": "wall", "path": "not_array", "count": 2, "mode": "continuous"},
		11, ws
	)
	runner.check(mock_a11.sent.size() == 1, "A.11 发 1 条 result")
	if mock_a11.sent.size() == 1:
		runner.check(
			String(mock_a11.sent[0]["fields"].get("error")) == "invalid_params",
			"A.11 path 非 Array → invalid_params"
		)
		# grep PathGenerator.parse_path:14
		runner.check(
			String(mock_a11.sent[0]["fields"].get("message")).find("path 必须是数组") >= 0,
			"A.11 message 含 'path 必须是数组'"
		)
```

- [ ] **Step 13: A.12 path_node 解析错（resolve_path3d 节点不存在 → :179-189）**

```gdscript
	# === A.12 path_node 解析错（节点不存在 → ScenePlacer.resolve_path3d error → :179-189）===
	var mock_a12 := MockServer.new()
	var orch_a12 := _make_orch(mock_a12, [], root, [false], [])
	orch_a12.handle_command(
		{"__req_id": "r12", "shape": "wall", "path_node": "/Root/NotExist", "count": 2, "mode": "continuous"},
		12, ws
	)
	runner.check(mock_a12.sent.size() == 1, "A.12 发 1 条 result")
	if mock_a12.sent.size() == 1:
		runner.check(
			String(mock_a12.sent[0]["fields"].get("error")) == "invalid_params",
			"A.12 path_node 不存在 → invalid_params"
		)
		# grep ScenePlacer.resolve_path3d「未找到」
		runner.check(
			String(mock_a12.sent[0]["fields"].get("message")).find("未找到") >= 0,
			"A.12 message 含 '未找到'"
		)
```

- [ ] **Step 14: A.13 validate 错（spacing+count 都有 → validate :47-48 → :204-209）**

```gdscript
	# === A.13 validate 错（spacing 与 count 都有 → validate 'spacing 与 count 只能二选一' → :204-209）===
	var mock_a13 := MockServer.new()
	var orch_a13 := _make_orch(mock_a13, [], root, [false], [])
	orch_a13.handle_command(
		{
			"__req_id": "r13", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "spacing": 1.0, "mode": "continuous"
		},
		13, ws
	)
	runner.check(mock_a13.sent.size() == 1, "A.13 发 1 条 result")
	if mock_a13.sent.size() == 1:
		runner.check(
			String(mock_a13.sent[0]["fields"].get("error")) == "invalid_params",
			"A.13 validate 错 → invalid_params"
		)
		runner.check(
			String(mock_a13.sent[0]["fields"].get("message")).find("只能二选一") >= 0,
			"A.13 message 含 '只能二选一'"
		)
```

- [ ] **Step 15: 跑全 suite，确认 A 组 15 case（A.1-A.13 含 3a/3b/4a/4b）全 PASS**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: Orchestrator suite 下 A.1-A.13 全 PASS，`0 failed`

- [ ] **Step 16: Commit**

```bash
git add tests/test_orchestrator.gd
git commit -m "test(claim5): A 组 14 case（错误码分支，grep 旧 plugin 精确文案）"
```

---

## Task 4: B 组 3 case（成功路径）

**Files:**
- Modify: `tests/test_orchestrator.gd`

- [ ] **Step 1: B.14 单件 generate 成功（含 save=true，覆盖 :122 透传）**

```gdscript
	# === B.14 单件 generate 成功（save=true → resource_path 非空 + _dock_add + _mark_unsaved）===
	var mock_b14 := MockServer.new()
	var marked_b14 := [false]
	var added_b14: Array = []
	var orch_b14 := _make_orch(mock_b14, [], root, marked_b14, added_b14)
	orch_b14.handle_command(
		{"__req_id": "r14", "shape": "box", "name": "b14", "save": true}, 14, ws
	)
	runner.check(mock_b14.sent.size() == 1, "B.14 发 1 条 result")
	if mock_b14.sent.size() == 1:
		runner.check(bool(mock_b14.sent[0]["ok"]), "B.14 success=true")
		var f14: Dictionary = mock_b14.sent[0]["fields"]
		runner.check(String(f14.get("node_path", "")) != "", "B.14 node_path 非空")
		# save=true → resource_path 非空（覆盖 :122 place_payload save 透传）
		var rp14 := String(f14.get("resource_path", ""))
		runner.check(rp14 != "", "B.14 save=true → resource_path 非空（:122 透传）")
		runner.check(bool(marked_b14[0]), "B.14 _mark_unsaved 被调")
		runner.check(added_b14.size() == 1, "B.14 _dock_add 被调 1 次")
		# 清理 save 的 .tscn
		if rp14 != "" and FileAccess.file_exists(rp14):
			DirAccess.remove_absolute(rp14)
```

- [ ] **Step 2: B.15 discrete path count=2（2 条 result + _dock_add×2 + mark）**

```gdscript
	# === B.15 discrete path count=2（2 条 per-point result + _dock_add×2 + mark）===
	var mock_b15 := MockServer.new()
	var marked_b15 := [false]
	var added_b15: Array = []
	var orch_b15 := _make_orch(mock_b15, [], root, marked_b15, added_b15)
	orch_b15.handle_command(
		{"__req_id": "r15", "shape": "cylinder", "path": [[0, 0, 0], [3, 0, 0]], "count": 2, "name": "b15"},
		15, ws
	)
	runner.check(mock_b15.sent.size() == 2, "B.15 discrete count=2 → 2 条 result")
	var ok_count_b15 := 0
	for r15 in mock_b15.sent:
		if bool(r15["ok"]):
			ok_count_b15 += 1
	runner.check(ok_count_b15 == 2, "B.15 2 条都 success=true")
	runner.check(added_b15.size() == 2, "B.15 _dock_add 被调 2 次")
	runner.check(bool(marked_b15[0]), "B.15 any_success → _mark_unsaved 被调")
```

- [ ] **Step 3: B.16 continuous wall 2 段（2 条 result）**

```gdscript
	# === B.16 continuous wall 2 段（count=2 → 2 段 → 2 条 result）===
	var mock_b16 := MockServer.new()
	var marked_b16 := [false]
	var orch_b16 := _make_orch(mock_b16, [], root, marked_b16, [])
	orch_b16.handle_command(
		{
			"__req_id": "r16", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "mode": "continuous", "name": "b16"
		},
		16, ws
	)
	runner.check(mock_b16.sent.size() == 2, "B.16 continuous count=2 → 2 条 result")
	runner.check(bool(marked_b16[0]), "B.16 any_success → _mark_unsaved 被调")
```

- [ ] **Step 4: 跑全 suite，B 组 PASS**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: B.14-16 全 PASS，`0 failed`

- [ ] **Step 5: Commit**

```bash
git add tests/test_orchestrator.gd
git commit -m "test(claim5): B 组 3 case（成功路径，含 save=true 透传）"
```

---

## Task 5: C + D + E 组 4 case（竞态 + batch undo + 失败）

**Files:**
- Modify: `tests/test_orchestrator.gd`

- [ ] **Step 1: C.17 单件 generate 场景切走（_get_root 双值 → mark 不触发）**

```gdscript
	# === C.17 单件 generate 场景切走（place 成功但 mark 前 root 失效 → _mark_unsaved 不调）===
	# _get_root 第一次（:108 取 root place）返 root，第二次（:134 mark 前 can_mark_scene 第二参数）返 null
	var mock_c17 := MockServer.new()
	var marked_c17 := [false]
	var calls_c17 := [0]
	var orch_c17 := Orchestrator.new(
		mock_c17, [],
		func() -> Node:
			calls_c17[0] += 1
			return root if calls_c17[0] == 1 else null,  # 第 1 次 root、第 2 次 null
		func() -> void: marked_c17[0] = true,
		func(_n, _p) -> void: pass
	)
	orch_c17.handle_command({"__req_id": "r17", "shape": "box", "name": "c17"}, 17, ws)
	runner.check(mock_c17.sent.size() == 1, "C.17 发 1 条 result")
	if mock_c17.sent.size() == 1:
		runner.check(bool(mock_c17.sent[0]["ok"]), "C.17 place 成功（success=true）")
		# P1-5 核心：place 成功但场景切走 → mark 不触发
		runner.check(not bool(marked_c17[0]), "C.17 P1-5：场景切走 → _mark_unsaved 不触发（can_mark_scene 守住）")
```

- [ ] **Step 2: C.18 continuous path 场景切走（_get_root 双值 → :362 mark 不触发）**

```gdscript
	# === C.18 continuous path 场景切走（段 place 成功但 :362 mark 前 root 失效 → mark 不触发）===
	# 覆盖 path 分支的 mark 校验点 :362（与 C.17 单件 :134 互补）
	var mock_c18 := MockServer.new()
	var marked_c18 := [false]
	var calls_c18 := [0]
	var orch_c18 := Orchestrator.new(
		mock_c18, [],
		func() -> Node:
			calls_c18[0] += 1
			return root if calls_c18[0] == 1 else null,
		func() -> void: marked_c18[0] = true,
		func(_n, _p) -> void: pass
	)
	orch_c18.handle_command(
		{
			"__req_id": "r18", "shape": "wall", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "mode": "continuous", "name": "c18"
		},
		18, ws
	)
	runner.check(mock_c18.sent.size() == 2, "C.18 2 段 place 成功（2 条 result）")
	runner.check(not bool(marked_c18[0]), "C.18 P1-5：path 场景切走 → _mark_unsaved 不触发（:362 can_mark_scene 守住）")
```

- [ ] **Step 3: D.19 batch 原子 undo 经编排层（同 batch_id 连续 2 次 → undo freed=2，R7）**

```gdscript
	# === D.19 batch 原子 undo 经编排层（同 batch_id=200 连续 2 次 generate → undo 一次弹 2，R7 freed 2）===
	# 验编排层透传 batch_id 给 ScenePlacer（batch 原子语义在 ScenePlacer 已测，此处验编排层透传对）
	var stack_d19: Array = []
	var mock_d19 := MockServer.new()
	var orch_d19 := Orchestrator.new(
		mock_d19, stack_d19,
		func() -> Node: return root,
		func() -> void: pass,
		func(_n, _p) -> void: pass
	)
	# 连续 2 次 generate（同 batch_id=200，模拟 server 层把 batch items 拆 emit 成单件）
	orch_d19.handle_command({"__req_id": "d19a", "shape": "box", "name": "d19a"}, 200, ws)
	orch_d19.handle_command({"__req_id": "d19b", "shape": "box", "name": "d19b"}, 200, ws)
	runner.check(stack_d19.size() == 2, "D.19 前置：2 次 generate 入栈 2 条")
	# undo（batch_id=-1 标记，__undo=true）→ 弹 batch_id=200 全部
	mock_d19.sent.clear()
	orch_d19.handle_command({"__req_id": "d19u", "__undo": true}, -1, ws)
	runner.check(mock_d19.sent.size() == 1, "D.19 undo 发 1 条 result")
	if mock_d19.sent.size() == 1:
		runner.check(bool(mock_d19.sent[0]["ok"]), "D.19 undo success=true")
		# R7：message "freed 2"（编排层透传 ScenePlacer batch 原子 freed 计数）
		runner.check(
			String(mock_d19.sent[0]["fields"].get("message")) == "freed 2",
			"D.19 R7：undo message='freed 2'（batch 原子弹 2，selftest 硬依赖）"
		)
		runner.check(stack_d19.is_empty(), "D.19 undo 后栈清空（batch=200 全弹）")
```

- [ ] **Step 4: E.20 _place_one 失败（discrete path parent_not_found → any_success 不累加 → mark 不触发）**

```gdscript
	# === E.20 _place_one 失败（discrete path count=2 + parent 不存在 → 2 条 error + any_success false → mark 不触发）===
	# 注：单件 generate 失败走 :137（不经 _place_one）；E.20 必须用 path 分支测 _place_one 失败
	var mock_e20 := MockServer.new()
	var marked_e20 := [false]
	var orch_e20 := _make_orch(mock_e20, [], root, marked_e20, [])
	orch_e20.handle_command(
		{
			"__req_id": "r20", "shape": "box", "path": [[0, 0, 0], [3, 0, 0]],
			"count": 2, "parent": "/Root/Nope"  # parent 不存在 → ScenePlacer.place parent_not_found
		},
		20, ws
	)
	runner.check(mock_e20.sent.size() == 2, "E.20 discrete count=2 → 2 条 result（_place_one 失败回执）")
	var err_count_e20 := 0
	for r20 in mock_e20.sent:
		if String(r20["fields"].get("error")) == "parent_not_found":
			err_count_e20 += 1
	runner.check(err_count_e20 == 2, "E.20 2 条都 parent_not_found")
	# P0-2：全失败 any_success false → mark 不触发
	runner.check(not bool(marked_e20[0]), "E.20 P0-2：全失败 → _mark_unsaved 不触发（any_success 不累加）")
```

- [ ] **Step 5: 跑全 suite，C+D+E 组 PASS（22 case 全绿）**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: Orchestrator suite 22 case 全 PASS，`=== Results: N passed, 0 failed ===`

- [ ] **Step 6: Commit**

```bash
git add tests/test_orchestrator.gd
git commit -m "test(claim5): C+D+E 组 4 case（P1-5 竞态 + batch 原子 undo + _place_one 失败）→ 22 case 全绿"
```

---

## Task 6: 切换 plugin（_on_command 透传 + 删旧方法 + 3 包装方法）

**Files:**
- Modify: `addons/asset_forge/asset_forge_plugin.gd`

**Interfaces:**
- Consumes: `Orchestrator`（Task 1）
- **R5**：切换后 grep 确认 `_handle_generate_path`/`_place_one` 在 plugin 无残留调用点

- [ ] **Step 1: 加 _orch 成员 + _enter_tree 装配**

Modify `addons/asset_forge/asset_forge_plugin.gd`：

在 `var _undo_stack: Array = []`（:11）后加成员：

```gdscript
var _undo_stack: Array = []  # IMPORTANT-2：registry 持有者，_exit_tree 清空
var _orch: Orchestrator = null  # claim 5：编排层（EditorInterface 副作用经 Callable 注入）
```

在 `_enter_tree` 的 `add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)`（:23）之后、`_on_start()`（:24）之前插入：

```gdscript
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	# claim 5：装配 Orchestrator（_server/_undo_stack 就绪 + dock 就绪后，server 启动前）
	_orch = Orchestrator.new(
		_server,
		_undo_stack,
		Callable(self, "_get_root"),
		Callable(self, "_mark_unsaved"),
		Callable(self, "_dock_add")
	)
	_on_start()  # 自动启动 server
```

- [ ] **Step 2: _on_command 改 1 行透传 + 删旧 _handle_generate_path/_place_one**

把 `_on_command`（:71-137）整个方法体替换为 1 行透传：

```gdscript
func _on_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	_orch.handle_command(payload, batch_id, ws)
```

**删除** plugin 里旧的 `_handle_generate_path`（:141-363）和 `_place_one`（:367-414）整段（逻辑已搬到 orchestrator.gd）。

- [ ] **Step 3: 加 3 个包装方法（_get_root/_mark_unsaved/_dock_add）**

在 `_on_log` 方法之后（或文件末尾 `_on_command` 附近）加：

```gdscript
# claim 5：EditorInterface/UI 副作用包装，经 Callable 注入 Orchestrator（解耦编排层）
func _get_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()


func _dock_add(node_name: String, node_path: String) -> void:
	if _dock:
		_dock.add_to_generated_list(node_name, node_path)
```

- [ ] **Step 4: grep 确认旧方法无残留调用点（R5）**

Run: `grep -n "_handle_generate_path\|_place_one" addons/asset_forge/asset_forge_plugin.gd`
Expected: **0 命中**（这两个方法已删，plugin 内无调用）。若命中，说明有遗漏调用点，修复后再继续。

Run: `grep -n "EditorInterface" addons/asset_forge/asset_forge_plugin.gd`
Expected: 仅 `_get_root`/`_mark_unsaved` 两个包装方法内 2 处（编排层 EditorInterface 已全部上移）。

- [ ] **Step 5: 跑全 6 suite，确认切换零回归**

Run: `godot --headless --path . --script res://tests/test_runner.gd`
Expected: 6 suite 全 PASS，`=== Results: N passed, 0 failed ===`（Orchestrator 22 case 仍全 PASS——切换后 handle_command 走 Orchestrator，plugin 仅透传）

- [ ] **Step 6: Commit**

```bash
git add addons/asset_forge/asset_forge_plugin.gd
git commit -m "refactor(claim5): plugin 切换为胶水（_on_command 透传 + 删旧编排方法 + 3 包装方法）"
```

---

## Task 7: selftest 零回归验证（活体闸）

**Files:** 无（验证 only）

**说明**：selftest 是活体（需 Godot 编辑器运行 + 场景打开），不是 headless。它是 callable 注入在真实编辑器工作的端到端真相（spec §10：selftest 兜真实 EditorInterface 端到端，22 case 兜 error/竞态/边界盲区）。这步是切换后的最终回归闸。

- [ ] **Step 1: 在 Godot 编辑器启用插件 + 打开一个场景**

手动：打开 Godot 编辑器加载本项目 → Project Settings → Plugins 确认 Asset Forge 已启用 → 新建/打开一个 3D 场景（selftest 需要 `get_edited_scene_root()` 非 null）。

- [ ] **Step 2: 跑 forge_client.py --selftest，确认 24 项全 PASS**

Run: `python tools/forge_client.py --selftest`
Expected: 24 行 `PASS`（11 shape + 1 单件 undo + 6 path 生成 + 6 path undo），exit code 0。

**关键断言**（R7）：6 个 path undo case 的 `freed N` 解析正确（:651/678/706/733/760/788）。若 undo case 报 `freed -1` 或 FAIL，说明搬迁改了 undo message 文案（违反 R7），回查 `orchestrator.gd` 的 undo 分支 message 必须为 `"freed %d"`。

- [ ] **Step 3: 若全 PASS，claim 5 完成**

24 项 selftest 全 PASS = callable 注入在真实编辑器工作 + 搬迁零回归。结合 Task 6 的 6 suite（22 case + 5 旧 suite）全 PASS，claim 5 验收标准（spec §11）全部达成。

- [ ] **Step 4: 更新 Obsidian 日志 + MEMORY（claim 5 闭环）**

记录 claim 5 完成到 Obsidian `AssetForge/开发日志/2026-07-08 claim 5 编排层可测性重构.md` + 更新 `AssetForge 首页.md` 阻塞项（claim 5 划掉）+ 更新 memory `assetforge-resume-point.md`。

---

## Self-Review（写计划后自查）

**1. Spec coverage**（spec §1-12 逐节）：
- §3 方案 → Task 1（Orchestrator 骨架）+ Task 6（plugin 胶水）✓
- §4 搬迁映射 → Task 1 Step 2 替换表 ✓
- §5 mock 设计 → Task 2 Step 1（MockServer + _make_orch + ws + root + P1-5 双值）✓
- §6 22 case → Task 2-5（A.1 + A.2-A.13×14 + B.14-16 + C.17-18 + D.19 + E.20 = 22）✓
- §7 4 步搬迁 → Task 1（步1）/ Task 2-5（步2）/ Task 6（步3）/ Task 7（步4）✓
- §7 步骤 2 grep 约束 → 每个 error case 给旧 plugin 行号 + 文案断言 ✓
- §8 R1-R7 → Global Constraints（R1/R3/R6/R7）+ Task 1（R1）+ Task 6 Step 4（R5）+ Task 7（R7 selftest 验证）+ R2（22 case 验搬迁）✓
- §9 不变量守护 → D.19（不变量3）/ A.4a/4b（no_active_scene）/ E.20（P0-2）/ C.17-18（P1-5）/ A.7（白名单）✓
- §10 互补 → Task 7 说明 ✓
- §11 验收 5 条 → Task 5 Step 5（22 case）+ Task 6 Step 5（6 suite）+ Task 7（selftest 24）+ Task 6（plugin 胶水）+ Global Constraints（标记保留/R7）✓
- §12 SceneTree runner → Global Constraints ✓

**2. Placeholder scan**：Task 1 Step 2 的「粘贴 plugin.gd:X-Y 方法体」是精确复制指令（带行号 + 替换表 + mark 段完整示例），非占位；handle_command 骨架的 generate 分支体同理。其余 step 均含完整代码。✓

**3. Type consistency**：`Orchestrator._init(server: RefCounted, ...)` 与 Task 6 `Orchestrator.new(_server, ...)`、Task 2 `_make_orch` 返回 `Orchestrator` 一致；`handle_command(payload, batch_id, ws)` 与 plugin `_on_command` 透传、test 调用一致；`MockServer.send_result(req_id, ok, fields, ws)` 与 `AssetForgeServer.send_result` 签名一致（duck typing）。✓

**4. case 计数自洽**：A 组 15（1,2,3a,3b,4a,4b,5,6,7,8,9,10,11,12,13）+ B 3 + C 2 + D 1 + E 1 = 22 ✓

**计划对 spec 的 3 处基于代码现实的细化**（已在对应 step 注明）：
- A.3b 用 discrete（continuous 白名单先拦非白名单 shape，到不了 :282-296）
- A.5 只测互斥（:169-176「都无」不可达，_on_command:83 进入条件矛盾）
- A.9 改测 spacing 路径 pre_est（:247-259 samples>BATCH_LIMIT 不可达，pre_est 是上界先拦）
