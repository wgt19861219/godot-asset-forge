# claim 5：编排层可测性重构（Orchestrator 抽取）设计

- **日期**：2026-07-08
- **仓库**：`D:\GitHub\godot-asset-forge`（asset-forge 本仓库自身改造）
- **状态**：设计待审
- **出处**：claim 5 定义见 Obsidian `AssetForge/开发日志/2026-07-07 v11.5 全链代码审查.md`「剩余待办」首条 + 该日志 `[!bug] P2 测试缺口`条目。仓库内 `docs/` 无 claim 编号定义文档（已 grep 确认）。

## 1. 背景与问题

`addons/asset_forge/asset_forge_plugin.gd` 的编排层（`_on_command` :71-137 + `_handle_generate_path` :141-363 + `_place_one` :367-414，约 338 行含注释）是全仓最复杂、最易出错的一段（三分支路由、10 步校验链、段注入、竞态 mark），却**零 headless 测试覆盖**。

根因：编排层依赖 `EditorInterface` 单例（`get_edited_scene_root()` 取 root × 2 处 + 竞态校验内部再调 × 2、`mark_scene_as_unsaved()` × 2），而 `asset_forge_plugin.gd` 顶格 `@tool extends EditorPlugin`——在 `--headless --script`（SceneTree 项目运行时）下 preload/new 它会因 `EditorPlugin` + `EditorInterface` 失败。这是 v11.5 审查 claim 5「工作量大、待拍板」的技术卡点。

现有 5 suite 均不覆盖编排层：`test_command_server` 测协议层（handshake/token/分发），注释明说「不测编排」；`test_scene_placer` 测 ScenePlacer 静态方法（root 作参数传入，不碰 EditorInterface）；其余测纯函数。活体覆盖仅 `forge_client.py --selftest`（需手开编辑器，非 CI）。

## 2. 目标与非目标

**目标**：编排层 100% headless 可测，补齐 claim 5 的回归守护。

**非目标**：
- 不重测 mesh 几何（`custom_meshes` / `path_generator` 已有测试，编排层只验「段循环调 `_place_one` N 次 + send_result N 条 + any_success 累计」）。
- 不为 `godot-mcp-enhanced` 整合铺垫——两仓库几何体代码各自维护（既定取舍），mcp-enhanced 侧另写 `asset_commands.gd`，不复用本 Orchestrator。
- 不引第三方测试框架（保持自研 minimal `SceneTree` runner 范式）。

## 3. 方案：抽 Orchestrator 类

把编排层整段搬入新类 `Orchestrator`，所有 `EditorInterface` 调用上移到 `plugin.gd` 薄胶水层（通过 `Callable` 注入）。Orchestrator 内部**零 EditorInterface 依赖**，纯 `RefCounted` 可 headless 测。

### 3.1 新文件 `addons/asset_forge/orchestrator.gd`

```gdscript
@tool
class_name Orchestrator extends RefCounted
# 编排层（claim 5）。从 asset_forge_plugin.gd 搬入 _on_command/_handle_generate_path/_place_one。
# EditorInterface 副作用（get_edited_scene_root / mark_scene_as_unsaved）通过 Callable 注入，
# 本类零 EditorInterface 依赖 → 可 headless 单测。

# R1（duck typing 换可测性）：_server 是唯一需 mock 的有状态依赖，去 AssetForgeServer 强类型注解。
# MockServer（inner class extends RefCounted）才注得进去。损失的类型安全由 22 case 补回。
var _server: RefCounted = null
# IMPORTANT-2（修订）：clear 责任单一 + 生命周期跟 plugin；Orchestrator 持【非所有者引用】。
# GDScript Array 引用语义：Orchestrator 存成员后 append/pop 直达 plugin 的栈；_exit_tree.clear() 仍由 plugin 执行。
var _undo_stack: Array = []
var _get_root: Callable       # 替 EditorInterface.get_edited_scene_root()
var _mark_unsaved: Callable   # 替 EditorInterface.mark_scene_as_unsaved()
var _dock_add: Callable       # 替 _dock.add_to_generated_list（plugin._dock_add 内部判 _dock null）

func _init(server: RefCounted, undo_stack: Array, get_root: Callable, mark_unsaved: Callable, dock_add: Callable) -> void:
	_server = server
	_undo_stack = undo_stack
	_get_root = get_root
	_mark_unsaved = mark_unsaved
	_dock_add = dock_add

# plugin._on_command 信号槽直接转调此方法（req_id 在此首行自提，消除胶水层冗余）。
func handle_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	var req_id := String(payload.get("__req_id", ""))
	# ... 三分支路由 + _handle_generate_path / _place_one（签名不变，作为内部方法）
```

### 3.2 `asset_forge_plugin.gd` 退化为胶水

```gdscript
var _orch: Orchestrator

func _enter_tree() -> void:
	_server = _Server.new()
	_server.command_received.connect(_on_command)   # 仍信号槽，体内改 1 行透传
	_server.connection_status_changed.connect(_on_connection)
	_server.log_emitted.connect(_on_log)
	_dock = _Dock.new()
	_dock.name = "Asset Forge"
	_dock.start_server_pressed.connect(_on_start)
	_dock.stop_server_pressed.connect(_on_stop)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	_orch = Orchestrator.new(_server, _undo_stack, Callable(self, "_get_root"), Callable(self, "_mark_unsaved"), Callable(self, "_dock_add"))
	_on_start()

func _on_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	_orch.handle_command(payload, batch_id, ws)

func _get_root() -> Node:
	return EditorInterface.get_edited_scene_root()

func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()

func _dock_add(name: String, node_path: String) -> void:
	if _dock:
		_dock.add_to_generated_list(name, node_path)
```

`_exit_tree`（`_undo_stack.clear()` + `AssetFactory.clear_cache()` 仍在 plugin，clear 责任不变）、`_process`（`_server.poll()`）、`_on_start`/`_on_stop`/`_on_connection`/`_on_log` 全部不变。

## 4. 搬迁映射

| plugin.gd 现状 | Orchestrator | EditorInterface 处理 |
|---|---|---|
| `_on_command` :71-137 | `handle_command(payload, batch_id, ws)`（首行提 req_id） | :108 `get_edited_scene_root()` → `_get_root.call()` |
| `_handle_generate_path` :141-363 | `_handle_generate_path(...)`（内部方法，签名同） | :154 同上 |
| `_place_one` :367-414 | `_place_one(...)`（内部方法，签名同） | 无 EditorInterface |
| :134-135 `can_mark_scene(root, EI.get_edited_scene_root())` + `mark_scene_as_unsaved()` | `can_mark_scene(root, _get_root.call())` + `_mark_unsaved.call()` | Callable（P1-5 第二次取场景走 `_get_root`） |
| :362-363 同上 | 同上 | Callable |
| :132/402-405 `_dock.add_to_generated_list` | `_dock_add.call(name, node_path)` | Callable |
| `_server.send_result`（19 处：:80/92/110/125/137/146/156/162/170/183/193/207/220/236/247/263/282/392/408） | `_server.send_result(...)` 不变（持引用） | — |
| `_undo_stack`（经 ScenePlacer.place append） | 持非所有者引用 | — |

## 5. mock 设计

**4 依赖可空性**（headless 测也必须提供 mock，仅 `_dock_add` 的「无 dock」语义由 plugin 承担）：

| 依赖 | 必填 | 测试 mock |
|---|---|---|
| `_server` | 是 | `MockServer`（测试文件 inner class，无 class_name） |
| `_undo_stack` | 是 | 真实 `[]`（验 batch 原子 undo 引用语义） |
| `_get_root` | 是 | Callable，返 `Node3D.new()`；P1-5 竞态用双值 |
| `_mark_unsaved` | 是 | Callable，捕获到 `marked[0]` |
| `_dock_add` | 是（Orchestrator 总 `.call()`，不判空；「无 dock」由 plugin._dock_add 判） | Callable，捕获到 `added` 数组；或 no-op |

```gdscript
# test_orchestrator.gd 内
class MockServer extends RefCounted:
	var sent: Array = []
	func send_result(req_id, ok, fields, ws):
		sent.append({"req_id": req_id, "ok": ok, "fields": fields})
```

- **ws**：`WebSocketPeer.new()`（未连接，`get_ready_state()==STATE_CLOSED`）。Orchestrator 不调 ws 任何方法，只透传给 `send_result`；MockServer 不碰 ws。传 null 亦可但不符强类型签名，统一传 `WebSocketPeer.new()`。
- **root**：`Node3D.new()` + `runner.root.add_child(root)`（沿用 test_scene_placer 范式，使 ScenePlacer.place 的绝对 NodePath 解析生效）。
- **P1-5 竞态 mock**：`var n=[0]; _get_root = func(): n[0]+=1; return root if n[0]==1 else null` —— 第一次 place 取到 root、第二次 mark 前取到 null，断言 `_mark_unsaved` 未被调。

## 6. 测试范围（22 case，`test_orchestrator.gd` 注册第 6 suite）

**A. 分支路由 + 错误码**（v11.5 核心 6 + 扩展）
1. undo 成功（`__undo=true` → undo_last + send_result；**R7：成功 message 必须为 `"freed %d"`**）
2. undo nothing_to_undo（空栈 → error）
3a. unsupported_shape 单件（`:88-89` create_mesh 返 null）
3b. unsupported_shape path（`:282-296` create_mesh_uncached 返 null）
4a. no_active_scene 单件（`_get_root` 返 null；`:113` message = "无活动场景，请先在编辑器新建或打开场景再 generate"）
4b. no_active_scene path（`_get_root` 返 null；`:157` message = "无活动场景"——**两处文案不同**，已 grep 实证 `addons/asset_forge/asset_forge_plugin.gd:113/157`，与 A.3 同理拆 2 case）
5. path↔path_node 互斥（同时有 `:161-168` + 都无 `:169-176`）
6. mode 非 discrete/continuous（`:146-152`）
7. continuous 白名单（shape 非 wall/fence/ramp，`:263-274`）
8. samples 空（continuous 短曲线 / spacing 过大，`:235-246`）
9. BATCH_LIMIT（samples > 64，`:247-259`）
10. 预估上限（pre_est > BATCH_LIMIT，spacing 极小，`:210-230`）
11. path parse 错（PathGenerator.parse_path error，`:192-197`）
12. path_node 解析错（resolve_path3d error，`:179-189`）
13. validate 错（spacing/count 非法，`:204-209`）

**B. 成功路径**
14. 单件 generate 成功（send_result ok + node_path + resource_path + _dock_add 被调 + _mark_unsaved 被调；**含 save=true 断言 resource_path 非空**，覆盖 :122/:388 透传）
15. discrete path count=2（2 条 result + _dock_add×2 + any_success + mark）
16. continuous wall 2 段（2 条 result）

**C. P1-5 竞态**（重点）
17. 场景切走 → place 成功但 `_mark_unsaved` **不**触发（mock _get_root 第一次返 root、第二次返 null）
18. root 失效同上

**D. batch 原子 undo 经编排层**
19. 同 batch_id 连续 2 次 `handle_command` → undo → send_result freed=2（编排层透传 ScenePlacer batch 原子语义；**R7：message `"freed 2"`**）

**E. _place_one 失败**
20. parent_not_found → send_result error + any_success 不累加 + mark 不触发

> **段注入（fence 端柱 / ramp 高度衔接）测试分层**：编排层只验段循环正确（B.16 + selftest 的 fence/ramp path case），不重验 mesh 几何（custom_meshes/path_generator 已测）。

## 7. TDD 搬迁顺序（4 步）

| 步 | 动作 | 验证 |
|---|---|---|
| 1 | 创建 `orchestrator.gd` 骨架 + 从 plugin **复制** `_on_command`/`_handle_generate_path`/`_place_one`（最小改动：EditorInterface → Callable，`_server`/`_undo_stack`/`_dock` → 成员）。**plugin 暂不切换**（旧逻辑原地，selftest 仍走旧路） | 现有 5 suite 跑通（搬迁只动新文件，不碰旧类） |
| 2 | 注册 `test_orchestrator.gd` 第 6 suite，**逐 case TDD**：写测（红）→ 调 Orchestrator → 修搬迁小错 → 绿。22 case 全绿 = 新类被钉死 | 22 case PASS |
| 3 | **切换 plugin**：`_on_command` 改 1 行透传 `_orch.handle_command`，**删除** plugin 旧 `_handle_generate_path`/`_place_one`，加 3 个包装方法 `_get_root`/`_mark_unsaved`/`_dock_add` | grep 确认旧方法无残留调用点 |
| 4 | 跑全 6 suite + `forge_client.py --selftest` | 6 suite 全 PASS + selftest 24 项全 PASS = 零回归 |

**步骤 2 关键约束（补 selftest 盲区）**：selftest 只覆盖成功路径 + batch 原子 undo，error/竞态/边界零覆盖。故写每个 error/竞态 case 时，**断言依据必须 grep 旧 plugin 精确行为**（error code 字符串、message 文案、send_result 字段名），不是凭设计意图写——22 case 同时承担「旧行为回归测试」角色。行号指引：
- A.3a/3b（unsupported_shape）：读 `:92-105`（单件 message 文案）+ `:282-296`（path message 文案）
- A.4a/A.4b（no_active_scene）：读 `:113`（单件长文案）+ `:157`（path 短文案），**两处文案不同**（已 grep 实证），分别断言各自 message
- A.6（mode）/ A.7（continuous 白名单）：读 `:146-152` + `:263-274`
- A.1/D.19（undo 成功）：**message 必须为 `"freed %d"`**（R7 selftest 硬依赖）

## 8. 风险清单

- **R1** `_server` 类型注解：`AssetForgeServer` → `RefCounted`（duck typing 换可测性，MockServer 才注得进）。损失的类型安全由 22 case 补回。
- **R2** 搬迁 ~338 行等价性：22 case + selftest 双重验证；逐分支保留 `IMPORTANT-N`/`Q-N`/`A-N` 标记。
- **R3** `_undo_stack` 非所有者引用：注释改「clear 责任单一 + 非所有者引用」，`_exit_tree` 清空仍由 plugin。
- **R4** P1-5 竞态双调 `_get_root`：mock 双值（C.17/C.18）。
- **R5** 切换后确认 plugin 旧 `_handle_generate_path`/`_place_one` 无其它调用点（grep）。
- **R6** `@tool` + `class_name Orchestrator` 编辑器内实例化：顶格 `@tool`（全仓一致）。
- **R7** **undo 成功回执 message 必须保持 `"freed %d"` 格式**（来源 plugin.gd:79 `"freed %d" % int(ur["freed"])`）。`forge_client.py` selftest 6 处 path undo case（:651/678/706/733/760/788）用 `msg.split()[-1]` 解析 freed 数，文案一改（如 `"freed: N"` / `"已释放 N"`）6 项全 FAIL（freed_n 变 -1）。A.1/D.19 显式断言此文案契约。

## 9. 不变量守护对照

| 不变量 | 守护点 | 验证 |
|---|---|---|
| 不变量 3 batch 原子 undo（Q4） | 编排层透传 batch_id | D.19 |
| 不变量 1 undo 不删 `.tscn`（IMPORTANT-2） | ScenePlacer.undo_last 不变 | **test_scene_placer.gd:57-67 已覆盖，编排层不重测** |
| 不变量 4 BATCH_LIMIT=64（IMPORTANT-4） | pre_est + samples 两道拦截 | A.9/A.10 |
| no_active_scene | `_get_root` 返 null 拦截 | A.4a/A.4b |
| `_resolve_parent` 不建中间节点 | ScenePlacer.place 不变 | E.20 |
| continuous 白名单 wall/fence/ramp | 校验链不变 | A.7 |
| P1-5 竞态 mark | `_get_root` Callable 双调 + can_mark_scene | C.17/C.18 |
| P0-2 全失败不 mark dirty | any_success 累计 + mark 抑制 | E.20 |
| stairs/fence 单 surface（A3） | CustomMeshes 不变，编排层不碰 | test_custom_meshes 已覆盖 |

**batch 不经编排层聚合**（spec 注明）：`command_server.gd:285-288` 显示 server 层把 `generate_batch` items 循环拆 emit 成多个单件 generate（共享同 `_batch_counter`），编排层 `handle_command` 收到的永远是单件，**编排层无 batch 聚合逻辑**。D.19 用「连续 2 次 `handle_command` 传同 batch_id」正确模拟此（编排层视角等同 server 层拆 emit 的两个单件）。

## 10. 测试覆盖互补（selftest ↔ 22 case）

selftest（24 项）与 22 case **互补非重叠**：

| 覆盖维度 | selftest 24 项 | 22 case |
|---|---|---|
| 真实 EditorInterface 端到端 | ✅（最高风险：Callable 注入在真实编辑器工作） | ❌（mock _get_root） |
| 成功路径（11 shape + 6 path） | ✅ | ✅（B.14-16） |
| batch 原子 undo | ✅（6 path undo） | ✅（D.19） |
| error code 各子类 | ❌ | ✅（A 组） |
| P1-5 竞态 | ❌ | ✅（C 组） |
| P0-2 全失败不 mark | ❌ | ✅（E 组） |
| undo nothing_to_undo | ❌ | ✅（A.2） |
| save=true 存 `.tscn` | ❌（selftest 无 save case） | ✅（B.14；test_scene_placer 测 ScenePlacer 层） |

结论：搬迁 error/竞态分支时 selftest 提供不了行为基线，**22 case 是唯一防线**（→ 步骤 2 grep 旧 plugin 约束）；搬迁成功路径 + callable 注入时 selftest 是端到端真相（→ 步骤 4 selftest 24 项是切换后回归闸）。

## 11. 验收标准（对齐 asset-forge v11.5 claim 5）

1. `test_orchestrator.gd` **22 case 全 PASS**（A.3 拆单件/path两处）
2. 全 **6 suite** headless 跑通：`godot --headless --path . --script res://tests/test_runner.gd`（Godot 4.6+；本机 godot 不在 PATH 时用 console 版绝对路径，见 `CLAUDE.md`）
3. `forge_client.py --selftest` **24 项全 PASS**（活体验证搬迁零回归 + callable 注入在真实编辑器工作）
4. `plugin.gd` 编排逻辑迁出，退化为胶水（~30 行）；`orchestrator.gd` 新增 `class_name Orchestrator extends RefCounted`
5. `IMPORTANT-N`/`Q-N`/`A-N` 标记全部保留；IMPORTANT-2 注释按 R3 修正；undo message 保持 `"freed %d"`（R7）

## 12. SceneTree runner 约束

- 测试用 `tests/test_runner.gd` 同款 `extends SceneTree` runner（命令见 §11）。
- **禁用 `mcp__godot__run_and_verify`**：该环境对 `class_name` 跨文件解析有限制，会报假 "not declared"（autoload-classname-headless-pitfall，曾踩 6+ 轮）。`test_scene_placer.gd:13` 无 preload 直接用 `ScenePlacer` class_name 跑通，证明 SceneTree runner 路径可靠。
