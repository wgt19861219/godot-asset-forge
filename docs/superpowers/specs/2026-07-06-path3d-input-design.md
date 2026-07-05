# Path3D 节点输入（v3）— 设计文档

- **日期**：2026-07-06
- **状态**：设计已确认，待写实施计划
- **关联**：[v1 discrete 设计](2026-07-05-procedural-path-array-design.md) · [v2 continuous 设计](2026-07-05-path-continuous-design.md)（Path3D 复用 v1/v2 框架，本文档只写差异 + 新增）

## 目标

为 `generate_path` 加 `path_node` 字段——bash 引用场景里的 Path3D 节点，plugin 读其 `curve.get_baked_points()` 作为 path，复用 v1/v2 采样与放置。「画曲线 → 沿路摆围栏」的 README 核心体验落地。

```bash
# discrete：沿 Path3D 曲线等数量摆灯柱
python tools/forge_client.py path cylinder --path-node /Root/MyPath --count 8 --mat metal
# continuous：沿 Path3D 曲线铺围栏（v2 continuous + v3 path_node 组合）
python tools/forge_client.py path fence --path-node /Root/FencePath --spacing 2 --mode continuous --mat wood
```

## 非目标（YAGNI）

- **Catmull-Rom 自实现平滑** —— 不做（Path3D 的 Curve3D 已是平滑曲线，get_baked_points 是 Godot tessellate 后的密集点，相当于免费获得平滑；用户要平滑就用 Path3D）
- **Path3D 节点名搜索 / 自动检测** —— 不做（用节点路径，明确无歧义）
- **path_node + parent≠root 坐标修正** —— 不做（文档说明，与 path JSON 既有行为一致）
- **控制点采样（非 baked_points）** —— 不做（baked_points 是标准 + 精确）

## 关联 v1/v2：复用面 vs 新增

**复用 v1/v2**（零改动或加默认参数）：
- `PathGenerator.validate/sample`（吃 `Array[Vector3]`，与 path 源无关，**零改动**）
- `_handle_generate_path` 编排框架（加 path 源分流）
- `mode`（discrete/continuous）+ batch_id + per-item 散回执 + `BATCH_LIMIT`
- `_place_one` helper（v2 抽出，加 total 参数）
- `command_server`（**零改动**，path_node 是 payload 字段透传，同 v2 mode）

**Path3D 新增**：
- `_on_command` 分流条件：`payload.has("path") or payload.has("path_node")`
- `_handle_generate_path` 入口 path 源分流（path JSON vs path_node）+ path/path_node 互斥校验
- `_resolve_path_node(root, path_node) -> Array` helper（读 Path3D + to_global）
- result 加 `"total"` 字段（解 predict_n path_node+spacing 阻塞 + 修 v1/v2 浮点隐患）
- `forge_client --path-node` 参数 + `send_and_recv_batch` 支持"收第一条读 total 再收齐"

## §1 架构（minimal-diff，3 文件改，PathGenerator + command_server 零改动）

```
addons/asset_forge/
  asset_forge_plugin.gd    ← 改：_on_command 分流条件 + _handle_generate_path 入口分流 + _resolve_path_node helper + _place_one 加 total 参数
tools/forge_client.py      ← 改：--path-node 参数 + build_path_payload path_node + send_and_recv_batch 支持 total 收齐 + predict_n 降级预校验
docs/protocol.md/README.md ← 改：path_node + total 字段 + 示例 + parent 坐标注记
```

**`_on_command` 分流条件改**（asset_forge_plugin.gd:83）：
```gdscript
# v2: if payload.has("path"):
# v3: path 或 path_node 都触发 path 分支
if payload.has("path") or payload.has("path_node"):
    _handle_generate_path(payload, batch_id, req_id, ws)
    return
```

**`_handle_generate_path` 入口加 path 源分流**（**A1：root 提前到分流之前**——v2 的 root 在 sample 之后取，path_node 模式 `_resolve_path_node(root,...)` 会因 root 未初始化崩；parse_path 之前）：
```gdscript
# A1：root 提前取（path_node 解析 + 后续 place 都需 root；v2 的 root 取值从 sample 之后提到最前）
var root: Node = EditorInterface.get_edited_scene_root()
if root == null:
    send_result(req_id, false, {"error":"no_active_scene","message":"无活动场景"}, ws); return

# path/path_node 互斥
if payload.has("path") and payload.has("path_node"):
    send_result(req_id, false, {"error":"invalid_params","message":"path 与 path_node 互斥"}, ws); return
if not payload.has("path") and not payload.has("path_node"):
    send_result(req_id, false, {"error":"invalid_params","message":"必须提供 path 或 path_node 之一"}, ws); return

# path 源统一为 Array[Vector3]（root 已就绪）
var points: Array
if payload.has("path_node"):
    var resolved: Dictionary = _resolve_path_node(root, String(payload["path_node"]))
    if resolved.has("error"):
        send_result(req_id, false, {"error":"invalid_params","message":resolved["error"]}, ws); return
    points = resolved["points"]
else:
    var parsed: Dictionary = PathGenerator.parse_path(payload["path"])
    if parsed["error"] != "":
        send_result(req_id, false, {"error":"invalid_params","message":parsed["error"]}, ws); return
    points = parsed["points"]

# 以下复用 v1/v2：validate/sample（含 mode）/ BATCH_LIMIT / shape/material / place 循环
# A7：sample 后必须加 `if samples.is_empty(): invalid_params` 守卫（见 §2.1 #7）
# 仅 _place_one 加 total 参数（= samples.size()），result 加 "total" 字段
# root 已在入口取（A1），后续不再重复取（v2 的 root 取值 + no_active_scene 校验删除，已提前）
```

**`_resolve_path_node(root, path_node) -> Dictionary`（新增 helper，返 {points, error}）**：
```gdscript
func _resolve_path_node(root: Node, path_node: String) -> Dictionary:
    var node: Node = ScenePlacer._resolve_parent(root, path_node)  # 复用 v1 路径解析（剥 root.name）
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
        points.append(path3d.to_global(v))  # ★ 局部→世界坐标
    return {"points": points, "error": ""}
```

**关键设计点**：
1. **局部→世界坐标**：Path3D 的 `curve.get_baked_points()` 返回**局部坐标**（相对 Path3D 节点）。`to_global(v)` 转世界，否则用户移动/旋转 Path3D 时物件生成在错误位置。这是 Path3D 输入的关键陷阱。
2. **绕过 parse_path**：path_node 解析得到 `Array[Vector3]`（不是 JSON），直接喂 validate/sample，跳过 parse_path（parse_path 为 JSON `[[x,y,z],...]` 设计）。
3. **复用 `_resolve_parent`**：path_node 的节点路径解析复用 v1 ScenePlacer._resolve_parent（绝对路径剥 root.name / 相对路径），与 parent 字段同语义。
4. **PathGenerator 零改动**：validate/sample 吃 `Array[Vector3]`，与 path 源无关——path_node 解析后产物与 path JSON 经 parse_path 后完全相同。

## §2 协议 / 错误处理 / 测试

### 2.1 错误处理（6 个新 invalid_params 分支）

| # | 条件 | message |
|---|---|---|
| 1 | path 与 path_node 同时出现 | path 与 path_node 互斥 |
| 2 | 两者都不出现 | 必须提供 path 或 path_node 之一 |
| 3 | path_node 节点未找到 | path_node 节点未找到: {path_node} |
| 4 | path_node 非 Path3D | path_node 必须是 Path3D 节点，实际类型: {get_class()} |
| 5 | Path3D.curve == null | Path3D curve 未设置（请在编辑器绘制曲线） |
| 6 | baked_points.size() < 2 | Path3D curve baked points < 2 |
| 7 | sample 后 samples 为空（A7） | 采样点为 0（continuous + spacing>0 + 路径总长 < spacing 时 0 段；或 discrete 异常），无法生成 |

后续复用 v1/v2：mode / align / spacing-count 互斥 / BATCH_LIMIT / continuous shape 白名单 / no_active_scene。
**A7 守卫（#7）修复 v2 既有隐患**（continuous 0 段 → server 发 0 条 result → client 等第一条 total 卡死 30s）+ v3 path_node 短曲线放大它（Path3D 0.5m 装饰路径 + spacing=2 即触发）。

### 2.2 payload（path_node 字段，与 path 互斥）

```jsonc
{
  "type": "generate_path",
  "id": "<req_id>",
  "payload": {
    "shape": "cylinder",
    "path_node": "/Root3D/MyPath",   // 新字段，与 path 互斥；NodePath 字符串
    "count": 5,                       // spacing/count 二选一
    "mode": "discrete",               // 默认 discrete，复用 v2
    "material": "metal",
    "name": "lamp", "parent": "", "save": false
  }
}
```

path_node 值 = NodePath 字符串，复用 `_resolve_parent` 解析规则（"MyPath" 相对 root，或 "/Root/MyPath" 绝对剥 root.name）。

### 2.3 result 加 total 字段（决策 D，解 predict_n 阻塞 + 修 v1/v2 浮点隐患）

每条 generate_path 的 result 携带 `samples.size()`：
```json
{"type":"generate_result","id":"r_path","success":true,"node_path":"/Root/lamp_0","total":5}
```

**为什么**：path_node + spacing 模式 client 不知道 Path3D 曲线总长，predict_n 算不出 n（v1/v2 的 spacing 模式靠 client 算 total_len）。result 带 total 后，client 收第一条即知要收几条——predict_n 退化为**纯预校验**（n>64 提前 exit 不发请求），实际收齐以 server total 为准。**顺带修复** v1/v2 final review 提的"predict_n 浮点边界差 1 → send_and_recv_batch 等不存在的第 N 条 → 30s 超时"隐患。

**改动面（D）**：
- `asset_forge_plugin.gd`：`_place_one` 加 `total: int` 参数 → result dict 加 `"total": total`；`_handle_generate_path` 两处循环（discrete/continuous）传 `samples.size()`
- `forge_client.py`：`send_and_recv_batch` 支持 `n=None`（收第一条读 total，再收齐 total 条）；`run_path` path_node 模式 `predict_n` 仅作预校验（n>64 提前 exit），实际收齐以 total 为准
- `command_server` 零改动（send_result 原样转发 fields，加字段即透传）

**backward compat**：v1/v2 result 不带 total 时，旧 client 按预测 n 收齐仍工作（send_and_recv_batch 兼容：收 total 失败则按 n 收齐兜底）。

### 2.4 CLI（--path-node，与 --path/--path-file 三互斥）

```bash
python tools/forge_client.py path cylinder --path-node /Root/MyPath --count 8 --mat metal
python tools/forge_client.py path fence --path-node /Root/FencePath --spacing 2 --mode continuous --mat wood
```

`build_path_payload`：`--path` / `--path-file` / `--path-node` 三互斥（同时出现 → argparse error 或 client 校验）。

### 2.5 path_node + parent 坐标策略（决策：文档说明）

文档说明 + 不强制互斥（与 path JSON 既有行为一致）：

> path_node 模式建议 parent 留空（默认 root）；指定非 root parent 时，物件位置 = Path3D 世界坐标（to_global 后）被当 parent 局部坐标，parent 非原点会错位。这与 path JSON 既有行为一致（path 坐标也是 parent 局部）。

### 2.6 测试（3 层，PathGenerator 零改动）

path_node 核心逻辑在 plugin（读 Path3D + to_global），不在 PathGenerator。

**Layer 0**：PathGenerator 不动（parse_path/validate/sample 全吃 points 数组，现有 test_path_generator.gd 全覆盖）。

**Layer 1 — `_resolve_path_node` 单测**（加到 test_command_server.gd 或新 test_plugin_path_node.gd）：构造 Path3D + Curve3D.add_point → 断言返回世界坐标数组。

**Layer 2 — 集成测试**（test_command_server.gd，走 _on_command 端到端）：path_node + count/spacing × discrete/continuous → 断言生成节点数 = total。

**测试矩阵（10 例）**：

| # | 场景 | 期望 |
|---|---|---|
| 1 | Path3D 在原点 + count discrete | points == baked_points（局部=世界）|
| 2 | Path3D 在 (10,0,0) + count | 返回点 x 偏移 +10（验 to_global 含位移）|
| 3 | Path3D 旋转 90° + count | 返回点绕 Y 旋转（验 to_global 含旋转）|
| 4 | curve == null | invalid_params「未设置」|
| 5 | baked_points < 2 | invalid_params「< 2」|
| 6 | path_node 是 MeshInstance3D | invalid_params「必须是 Path3D」|
| 7 | path_node 节点名不存在 | invalid_params「未找到」|
| 8 | path + path_node 同时 | invalid_params「互斥」|
| 9 | path_node + spacing continuous（wall）| N 段，total 字段正确 |
| 10 | path_node + count discrete（cylinder）| N 个，total 字段正确 |

#1-3 验坐标语义（to_global 正确性），#4-8 验错误分支，#9-10 验 total + 端到端。

## 实施顺序提示（详细计划由 writing-plans 出）

1. `asset_forge_plugin.gd`：`_on_command` 分流条件 + `_handle_generate_path` 入口分流 + `_resolve_path_node` + `_place_one` 加 total → Layer 1/2 测试
2. `tools/forge_client.py`：`--path-node` + `build_path_payload` + `send_and_recv_batch` 支持 total + `predict_n` 降级 → pytest 补 total 收齐
3. `test_command_server.gd` / 新 test_plugin_path_node.gd：10 例测试矩阵
4. 文档（protocol.md path_node + total + README 示例 + parent 坐标注记）+ selftest path_node 集成
