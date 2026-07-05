# 程序化场景生成 · MVP（路径阵列离散摆放）

- **日期**：2026-07-05
- **状态**：spec 审查通过（2026-07-05，F1-F5 已补），待 commit + writing-plans
- **关联**：[Asset Forge 首页](../../../README.md) · [协议](../../protocol.md) · [shape 参考](../../shapes-reference.md)

## 目标

为 Asset Forge 增加**程序化场景生成**能力的第一个生成器：**路径阵列离散摆放**。

> bash 命令提供一条折线 + shape + 采样规则 → 插件沿路径等间距或等数量摆放 N 个 shape 节点，自动朝向路径切线。

例：
```bash
python tools/forge_client.py path cylinder --path '[[0,0,0],[5,0,0],[5,0,5]]' --spacing 1 --mat metal
# → 沿 L 形路径每 1 米一根金属柱，自动朝向切线
```

**更高层目标**：建立可复用的「路径解析 → 采样 → 展开成 place 循环」框架，后续生成器（连续拼接、网格阵列、楼梯井、程序化建筑）复用同一套机制。

## 非目标（YAGNI，明确不做）

- **连续拼接**（fence/wall 栏板首尾相连填满路径）—— v2，需「长度对齐切线」语义
- **Path3D / Curve3D 节点输入** —— v2，需场景树读取
- **Catmull-Rom / 样条平滑曲线** —— v2，在折线点上插值
- **网格阵列 / 楼梯井 / 程序化建筑** —— 后续独立生成器
- **客户端展开**（方案 B，已否决）
- **服务端 fatal 时客户端优雅退出**（保持与 generate_batch 现有 30s 超时行为一致）

## 方案选型

三个候选（详见 brainstorming 记录）：

| | A. 服务端展开 + 新消息类型 | B. 客户端展开 + 复用 batch | C. 服务端 + 组合 shape |
|---|---|---|---|
| 协议改动 | 新增 `MSG_GENERATE_PATH` | 零 | `shape="path_array"` |
| 几何算法 | GDScript（plugin） | Python（client） | GDScript |
| 框架复用性 | **强** | 弱（每客户端重写） | 强 |
| 未来 Path3D 读取 | **天然支持** | 不支持 | 天然支持 |

**采用方案 A**：框架复用性 + 客户端简单 + 未来 Path3D 读取天然支持。代价是 GDScript 写几何（折线采样 + 切线计算，~80 行）和一个新协议类型。

## §1 架构 / 组件 / 数据流

### 新增 / 修改文件

```
addons/asset_forge/
  path_generator.gd        ← 新增：class_name PathGenerator extends RefCounted（纯几何静态类）
  command_server.gd        ← 接入：MSG_GENERATE_PATH 常量 + _handle_text 分支
  asset_forge_plugin.gd    ← 接入：_on_command path 分支
tools/forge_client.py      ← 接入：path 子命令 + n 预测
tests/test_path_generator.gd ← 新增：纯几何单测
tests/test_forge_client_predict.py ← 新增：客户端 n 预测 parity 单测（pytest）
```

遵循现有扁平结构 + 静态 class_name 模式（与 CustomMeshes 同）。

### PathGenerator 职责边界（纯几何，可独立单测）

三个静态方法，**不创建节点、不调 AssetFactory、不碰场景树**：

```gdscript
class_name PathGenerator extends RefCounted

# path 数组 [[x,y,z],...] → Array[Vector3]；非法 → {"points": [], "error": "..."}
static func parse_path(raw: Variant) -> Dictionary

# 输入退化校验 → 错误描述字符串（空串 = 合法）
static func validate(points: Array, spacing: float, count: int, align: String, include_endpoints: bool) -> String

# 已 valid 的输入 → 采样点列表 [{"position":Vector3,"rotation_deg":Vector3,"distance":float}, ...]
static func sample(points: Array, spacing: float, count: int, align: String, include_endpoints: bool) -> Array
```

### plugin 编排（复用现有 place + batch_id，零新机制）

```
generate_path payload
  → parse_path(path) → points[]        # 失败 → invalid_params
  → validate(points, spacing, count, align, include_endpoints)  # 失败 → invalid_params
  → sample(...) → samples[]             # 失败 → invalid_params
  → samples.size() > BATCH_LIMIT?       # 是 → invalid_params
  → AssetFactory.create_mesh(shape, params)   # 失败 → unsupported_shape（复用）
  → AssetFactory.create_material(material)    # 一次创建，N 个采样点共享
  → EditorInterface.get_edited_scene_root()   # null → no_active_scene（复用）
  → for i in samples.size():
       place_payload = {name: "{base}_{i}", transform: {position, rotation_deg}, parent, save}
       ScenePlacer.place(root, mesh, material, place_payload, _undo_stack, batch_id)  # 复用
       _server.send_result(req_id, success, {node_path, resource_path}, ws)           # per-point 散
  → EditorInterface.mark_scene_as_unsaved()
```

### 不变量守护（复用现有 4 条，零新增）

- **batch 原子 undo**：所有采样点共享一个 batch_id（`command_server._handle_text` 一次 `_batch_counter += 1`），一条 `undo_last` 全删
- **per-item 散回执**：N 条 `generate_result` 共享同一 `req_id`（与 `generate_batch` 逐字同语义）
- **复用错误码**：`unsupported_shape` / `no_active_scene` / `parent_not_found` / `unauthorized`，新增校验失败一律归 `invalid_params`

## §2 采样算法

### 输入与退化校验

- `path: Array[Vector3]`（≥2 点）
- 二选一：`spacing: float`（>0）或 `count: int`（≥1）
- `align ∈ {"none", "path", "normal"}`，默认 `"path"`
- `include_endpoints: bool`，默认 `true`

退化 → `invalid_params`（message 承载细节，不新增错误码）：
- 所有点重合 → `total_len == 0`
- `spacing <= 0` / `count < 1` / 两者都给 / 两者都不给
- `align` 非法值
- `include_endpoints == true 且 count == 1`（含两端至少需 2 个采样点；count=1 时含两端语义无定义）

### 采样距离序列

弧长：`seg_len[i] = path[i].distance_to(path[i+1])`，`total_len = Σ seg_len[i]`。**ε 约定**：下方 `ε = 1e-4`（米），客户端 n 预测（§3.5）必须同值——不一致会让「total_len 恰为 spacing 整数倍」等边界情形采样数偏差 1，触发 30s 超时。

**spacing 模式**：
```
d = 0
while d <= total_len + ε:
    distances.append(d); d += spacing
if include_endpoints and (total_len - distances[-1]) > ε:
    distances.append(total_len)        # 补尾点；起点 d=0 恒在
```

**count 模式**：
```
count == 1（仅 include_endpoints=false 合法，见退化校验）: distances = [total_len/2]   # 单点居中，避开 /0
include_endpoints: step = total_len/(count-1); distances = [0, step, ..., total_len]  # 恰好 count 个
否则:              step = total_len/count;    distances = [step/2, 3*step/2, ...]      # 居中 count 个
```

### 弧长走查 → 位置（lerp，零长段安全）

```gdscript
static func _position_at(d: float, seg_len: Array, path: Array) -> Vector3:
    for i in seg_len.size():
        if d <= seg_len[i]:
            return path[i].lerp(path[i+1], d / seg_len[i] if seg_len[i] > 0 else 0.0)
        d -= seg_len[i]
    return path[-1]   # 钳到末点
```

### 切线与转角

- **段内点**（d 在 seg[i] 内部）：`tangent = (path[i+1] - path[i]).normalized()`
- **顶点落点**（d 恰为顶点累计弧长，含 include_endpoints 强制首尾）：
  - 入边 `a`、出边 `b`，默认角平分线 `tangent = (a+b).normalized()`（miter 风格）
  - 退化（`bisect.length_squared() < 1e-8`，即 `a ≈ -b` 的 180° 折返）→ 回退用入边 `a`
  - 首点取出边、末点取入边
- **不主动补点**：count 模式补点破坏「恰好 N 个」契约；spacing 模式补点会让用户预期外的额外物件出现

### 切线 → rotation_deg（align）

`yaw_deg = rad_to_deg(atan2(-tangent.x, -tangent.z))`

| align | rotation_deg |
|---|---|
| `"none"` | `Vector3.ZERO` |
| `"path"` | `Vector3(0, yaw_deg, 0)` |
| `"normal"` | `Vector3(0, yaw_deg + 90, 0)`（垂直路径，用于栅栏柱/路桩） |

**输出**：`[{"position": Vector3, "rotation_deg": Vector3, "distance": float}, ...]`（distance 仅调试/排序用，不进协议必填字段）。

## §3 协议层

### 常量（`command_server.gd`）

```gdscript
const MSG_GENERATE_PATH := "generate_path"
```

### `_handle_text` 新分支（逐字镜像 `MSG_GENERATE`）

```gdscript
MSG_GENERATE_PATH:
    if not client.get("authed", false):
        send_unauthorized_and_close(ws); return
    _batch_counter += 1                       # 一次 path 请求 = 一个 batch_id
    var payload: Dictionary = obj.get("payload", {})
    payload["__req_id"] = req_id
    command_received.emit(payload, _batch_counter, ws)
```

### `_on_command` 新分支（plugin，undo 之后、单件 generate 之前）

`if payload.has("path"):` 分支，编排见 §1 plugin 编排伪代码。要点：
- `parse_path` / `validate` / `sample` 任一失败 → `send_result(req_id, false, {"error":"invalid_params","message":...}, ws); return`
- `samples.size() > _Server.BATCH_LIMIT` → `invalid_params`
- mesh/material 创建一次，N 采样点共享
- 每采样点：构造 `place_payload`（name=`{base}_{i}`、transform、parent、save）→ `ScenePlacer.place(..., _undo_stack, batch_id)` → `send_result`
- mesh == null → `unsupported_shape`；root == null → `no_active_scene`；place 失败 → 复用 `r["error"]`

### payload schema（wire）

```jsonc
{
  "type": "generate_path",
  "id": "<req_id>",
  "payload": {
    "shape": "cylinder",
    "params": { "height": 1.0, "radius": 0.2 },   // 可选，所有采样点共用
    "material": "metal",                           // 可选
    "path": [[0,0,0],[5,0,0],[5,0,5]],             // 必填，≥2 点
    "spacing": 2.0,                                // spacing/count 二选一
    "count": null,
    "align": "path",                               // 可选，默认 "path"
    "include_endpoints": true,                     // 可选，默认 true
    "name": "lamp",                                // 可选，→ lamp_0 lamp_1 ...
    "parent": "",                                  // 可选
    "save": false                                  // 可选
  }
}
```

### 客户端（`forge_client.py`，path 子命令，与 batch 平级）

参数：`path <shape>` + `--path '[[x,y,z],...]'`（或 `--path-file <file>`）+ `--spacing` XOR `--count` + `--align` + `--no-endpoints` + 通用 `--name/--mat/--parent/--save/--size/--radius/...`。

**n 预测**（决定 `send_and_recv_batch` 接收数，与 §2 距离序列规则镜像）：
```
count 模式:  n = count
spacing 模式: total_len = Σ dist(path[i], path[i+1])
              n = floor(total_len/spacing) + 1
              if include_endpoints and (total_len - (n-1)*spacing) > 1e-4: n += 1   # ε=1e-4，与 §2 同值（同步约定）
n > 64 → 客户端预判 fail，不发包
```
收发：`send_and_recv_batch(ws, {"type":"generate_path","id":"r_path","payload":{...}}, n)`（复用现有函数零改动）；输出 `{"success": all_ok, "results": [...], "count": n}`。

### 回执语义

- 每采样点 1 条 `generate_result`，全部共享同一 `req_id`（与 `generate_batch` 同语义）
- envelope `{type, id, success, node_path?, resource_path?, error?, message?}`，**不加 `sample_index`**（WebSocket 有序 + server 顺序发送 → `results[i]` 即第 i 个采样点）
- batch_id：一次 `_batch_counter += 1` → loop 内对每个 `ScenePlacer.place` 传同一 batch_id → 一条 `undo_last` 全删

### 错误码

path 模式所有输入校验失败（path<2 点 / total_len=0 / spacing/count 缺失·非正·互斥违反 / samples>BATCH_LIMIT）→ 一律 `invalid_params` + 详细 message，不新增码。复用 `unsupported_shape` / `no_active_scene` / `parent_not_found` / `unauthorized`。

**已知行为**：服务端 fatal 校验失败只发 1 条 error → 客户端等不到 n 条 → 30s 超时退出（与 `generate_batch` 现有行为一致，doc 写明）。

## 朝向约定注记（重要，写进 docs）

`align="path"` 公式 `yaw = atan2(-tangent.x, -tangent.z)` 基于 Godot 惯例：XZ 地平面、Y up、物件 forward = -Z、保持直立（忽略路径 Y 分量的俯仰）。`align="normal"` 取 `yaw + 90°`，即路径前进方向的**左侧法线**（XZ 平面）；需右侧法线者用 `align="none"` + 手动 `rotation_deg`，或留 v2 加 `side` 参数。

**适用范围**：
- ✅ **旋转对称物件**（box / cylinder / sphere / prism / cone / tube / torus）—— 视觉无朝向差异，路径阵列主力用例（灯柱=圆柱、装饰=球/锥、柱=管）
- ⚠️ **方向敏感物件**：`fence` 长度沿 **X**、`wall` 长度沿 **X**、`stairs` 上行沿 **+Z** —— 这些物件的「长度/上行」方向不是 -Z，用 `align="path"`（-Z 对齐切线）时视觉朝向会偏 90°。这是「通用 yaw 旋转」与「物件自身建模朝向」的解耦，非 bug。

**结论**：MVP 离散摆放适合旋转对称物件；方向敏感件的连续铺设（届时 align 改为「长度对齐切线」语义）留 v2。

## 测试策略

### `tests/test_path_generator.gd`（纯几何，headless，与 `test_custom_meshes.gd` 同模式）

- **parse_path**：合法点列表 / 非数组 / 元素非 3 元素数组 / <2 点
- **validate**：spacing 与 count 二选一（互斥）/ spacing>0 / count≥1 / total_len>0 / align 合法值
- **sample**：
  - spacing 模式采样点数 = `floor(total/spacing)+1`（+端点）
  - count 模式恰好 N 个、含两端等分
  - count=1 特例（不 /0）
  - 转角朝向 = 角平分线；180° 折返退化为入边
  - 零长段跳过（lerp 不 /0）
  - include_endpoints 真假两端行为
  - `sample().size()` 钉死用例（spacing/count 两模式 + include_endpoints 真假 + total_len 为 spacing 整数倍/非整数倍边界），作为客户端 `predict_n` 的 parity 基准（见下 Python 测试）
- **align 映射**：none=ZERO / path=yaw / normal=yaw+90

### `tests/test_command_server.gd` 扩展

- `generate_path` 分支：未鉴权 → unauthorized；鉴权后 emit `command_received` 共享同一 batch_id
- payload 透传 `__req_id`
- 与 `generate_batch` 的 batch_id 分配语义一致性

### `tests/test_forge_client_predict.py`（新增，Python pytest）

客户端 `predict_n(path, spacing, count, include_endpoints)` 必须与 GDScript `PathGenerator.sample().size()` 逐例相等（F1 ε 同步约定的钉死）：

- spacing 模式：`total_len` 为 `spacing` 整数倍 / 非整数倍 × `include_endpoints` 真假 = 4 组合
- count 模式：`count ≥ 2` 含两端等分；`count == 1`（仅 `include_endpoints=false` 合法）
- 边界用例：`total_len=10, spacing=2`（整数倍 → n=6）/ `spacing=3`（非整数倍 → n=4，`include_endpoints=true` → n=5）
- 断言：每个用例 `predict_n(...) == 期望 N`，且 N 与 GDScript 侧 `sample().size()` 一致

### 集成验证（编辑器 selftest）

`forge_client.py --selftest` 加一条：`generate_path` cylinder 沿 L 形路径，验证 N 条回执 + undo 原子删除。

### 文档测试（新增 shape 触点）

`docs/protocol.md` 加 `generate_path` 章节；`docs/shapes-reference.md` 不变（无新 shape）；`README.md` 加 path 子命令示例 + 朝向注记。

## 实施顺序提示（详细计划由 writing-plans 出）

1. `path_generator.gd`（parse_path + validate + sample）+ `test_path_generator.gd` —— 纯几何，headless 独立验
2. `command_server.gd`（MSG_GENERATE_PATH 常量 + `_handle_text` 分支）
3. `asset_forge_plugin.gd`（`_on_command` path 分支）
4. `forge_client.py`（path 子命令 + n 预测 + send_and_recv_batch 复用）+ `test_forge_client_predict.py`（parity 钉死）
5. 文档（protocol.md / README.md / 朝向注记）+ selftest 集成 + `test_command_server.gd` 扩展
