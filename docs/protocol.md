# 协议

JSON over WebSocket，端口 `60650`，bind `127.0.0.1`（仅本机）。

## 消息类型

`handshake` / `handshake_ack` / `ping` / `pong` / `generate` / `generate_batch` / `generate_path` / `generate_result` / `undo_last`

## handshake（鉴权）

请求：
```json
{"type":"handshake","payload":{"client":"forge_client","version":"1.0.0","token":"<hex>"}}
```

token 不符 → server 返 `{"type":"generate_result","success":false,"error":"unauthorized","message":"token 不符"}` + 断连。

token 正确 → `{"type":"handshake_ack","payload":{"server":"asset_forge","godot_version":"4.6.x","protocol":"1.0.0"}}`。

## generate

```json
{"type":"generate","id":"req_1","payload":{
  "shape":"box",
  "name":"crate_01",
  "params":{"size":[2,1.5,1.2]},
  "material":"wood",
  "transform":{"position":[0,0,0],"rotation_deg":[0,0,0],"scale":[1,1,1]},
  "parent":"/Root3D/Decor",
  "save":true
}}
```

- `shape` 必填；`name` / `params` / `material` / `transform` / `parent` / `save` 全可选
- `material` 支持：预设名 / 自定义 dict / `"res://path.tres"` / null（默认）

回执：
```json
{"type":"generate_result","id":"req_1","success":true,
 "node_path":"/Root3D/Decor/crate_01","resource_path":"res://GeneratedAssets/crate_01.tscn"}
```

`resource_path` 仅 `save=true` 时非空（`.tscn` PackedScene 路径）。

## generate_batch（per-item 散回执）

```json
{"type":"generate_batch","id":"req_b","items":[{...},{...}]}
```

**回执 = N 条独立 `generate_result`**（共享同一 `req_id`），client 按 `id` 收齐 N 条后聚合（**不返单条 `results[]` 聚合体**）。`items` 上限 64，超出返 `invalid_params`。

> 设计选择：per-item 散回执而非聚合 `results[]`，简化 plugin 状态（无需维护待聚合 batch 缓冲），server 实现可预测。

## generate_path（路径阵列离散摆放，程序化生成 MVP）

请求：
```json
{"type":"generate_path","id":"p1","payload":{
  "shape":"cylinder",
  "params":{"height":1.5,"radius":0.1},
  "material":"metal",
  "path":[[0,0,0],[3,0,0],[3,0,5]],
  "spacing":2.0,
  "align":"path",
  "include_endpoints":true,
  "name":"lamp",
  "parent":"/Root3D/Decor",
  "save":false
}}
```

- `path` 必填（≥2 点，每点 `[x,y,z]`）；`spacing` / `count` 二选一；`align` 默认 `"path"`（none/path/normal）；`include_endpoints` 默认 `true`
- `path_node`：可选，Path3D 节点路径（如 `/Root3D/MyPath`），与 `path` 互斥。plugin 读 `curve.get_baked_points()` + `to_global` 作为 path
- `mode`：`"discrete"`（默认，v1 等间距独立物件）或 `"continuous"`（栏板首尾相连铺满，仅 wall/fence/ramp，length 自适应段长，align 强制 path）
- `align_vertices`：可选 bool（默认 false），仅 `mode=continuous` + `spacing>0` 生效。true 时折线每个顶点强制为段边界，栏板在转角处断开不再切角。`va+discrete` / `va+count` → invalid_params（count 等分边界不对齐顶点）。`include_endpoints` 在 va 下忽略（va 已保证顶点=边界）
- **采样规则**：`spacing` = 等间距（含端点补尾点）；`count` = 等数量（含两端 N-1 等分）；`count==1` 时 `include_endpoints` 必须为 `false`（单点居中）
- **朝向**：`yaw = atan2(-tangent.x, -tangent.z)`；`none`=不转、`path`=沿切线、`normal`=切线+90°（路径前进方向左侧法线）
- **回执**：N 条独立 `generate_result` 共享同一 `req_id`（与 `generate_batch` 同语义，per-point 散）
- **回执 total 字段**：每条 `generate_result` 的 result envelope 含 `total`：int，采样点总数（discrete = 物件数 / continuous = 段数）。客户端可收第一条读 total 收齐（D 方案，path_node + spacing 模式必需）
- **undo**：所有采样点共享一个 batch_id，一条 `undo_last` 全删

**continuous 模式**：栏板（wall/fence/ramp）沿路径铺满，每段 length = 弦长（自适应间距），朝向 +X 对齐段弦方向。spacing 模式段数 = v1 点数 − 1；count 模式段数 = N（独立等分，不复用 v1 边界）。fence 段接缝端柱由 v5 放置层按段索引注入 `start_post`/`end_post` 去重（端柱共享零 z-fighting）；ramp 接缝高度由 v6 放置层注入 `start_height`/`end_height` 衔接（`_compute_seg_heights` 按累计弧长比例分配 height 总升高，恒定坡度，折线/直线都成立；支持下降 height 负）。

**align_vertices 模式（v4）**：每个折线段 `[vertex_d[i], vertex_d[i+1]]` 独立按 spacing 切，段末顶点强制为边界（去重防御浮点）。栏板在转角顶点处自然断开，不横跨转角切角。短尾保留（丢短尾=丢顶点对齐）；va 的 while `_EPS` 阈值保证每段长 >_EPS，不产生极短段。

**path_node 模式（v3）**：引用场景里的 Path3D 节点，读其 curve 的 baked_points（Godot 已 tessellate 的密集点）+ to_global（局部→世界）作为 path。Path3D 节点必须在当前活动场景内（同 parent 约束）。建议 parent 留空（默认 root）；指定非 root parent 时，物件位置 = Path3D 世界坐标被当 parent 局部，parent 非原点会错位（与 path JSON 既有行为一致）。错误分支：节点不存在 / 非 Path3D / curve null / baked<2 → `invalid_params`。

错误码：path<2 点 / total_len=0 / spacing/count 缺失·非正·互斥违反 / `count==1`+endpoints / samples>BATCH_LIMIT → 一律 `invalid_params` + message；复用 `unsupported_shape` / `no_active_scene` / `parent_not_found`。

## undo_last

```json
{"type":"undo_last","id":"u1"}
```

回 `{"type":"generate_result","id":"u1","success":true,"message":"freed N"}`。batch 原子（同 `batch_id` 一次弹 N 条）。undo 仅 `queue_free` 场景节点，**不删** `.tscn`。

## 错误

| error | 含义 |
|-------|------|
| `unsupported_shape` | 未知 shape |
| `invalid_params` | 参数类型错 / batch items > 64 |
| `parent_not_found` | parent 路径无效（不自动建中间节点） |
| `no_active_scene` | 编辑器无活动场景，先 New Scene 或打开场景 |
| `unauthorized` | handshake token 不符 |
| `nothing_to_undo` | undo 空栈 |

## token 路径解析（客户端）

优先级：

1. `--godot-user-dir <绝对路径>` 参数
2. `GODOT_USER_DIR=<绝对路径>` 环境变量
3. 默认 `%APPDATA%\Godot\app_userdata\<project_name>\asset_forge.token`（Windows；`<project_name>` 取自 `project.godot` 的 `config/name`）
