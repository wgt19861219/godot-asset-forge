# 路径阵列 continuous 模式（v2）— 设计文档

- **日期**：2026-07-05
- **状态**：spec 审查通过（2026-07-05，F1 fence z-fighting 措辞修正 + F2 ramp 注记），待 commit + writing-plans
- **关联**：[v1 discrete 设计](2026-07-05-procedural-path-array-design.md)（continuous 复用 v1 框架，本文档只写差异 + 新增）

## 目标

为 `generate_path` 加 `mode: "continuous"` —— 栏板（wall/fence）沿路径首尾相连铺满，长度自适应段长，朝向 `+X` 对齐段弦方向（chord）。

```bash
python tools/forge_client.py path wall --path '[[0,0,0],[5,0,0],[5,0,5]]' --mode continuous --count 5 --mat stone
# → 沿 L 形路径铺 5 块等长石墙，无缝拼接，转角 V 形接缝
python tools/forge_client.py path fence --path '[[0,0,0],[10,0,0]]' --mode continuous --spacing 2 --mat wood
# → 沿直线每 2 米一段木栅栏（段接缝端柱重合 z-fighting，preview 级，见朝向注记）
```

## 非目标（YAGNI）

- **顶点对齐分段**（顶点强制为段边界，转角更整齐）—— v3
- **mesh 缓存优化**（count 模式 length 全同可共享 mesh，spacing 仅尾段不同）—— 后续优化
- **fence 段接缝端柱去重** —— v3（MVP 接受每接缝 z-fighting 为 preview 级瑕疵，见朝向注记）
- **任意"长度沿 X" shape**（ramp/box）—— v3（MVP 只 wall/fence，length 参数名一致，无需映射表）。注：ramp 也有 `length` 沿 X（`asset_factory.gd:41-48`），v3 纳入时 length 注入零改动，仅扩 shape 白名单

## 关联 v1：复用面 vs 新增

**复用 v1**（零改动或加默认参数）：
- `parse_path` / `_position_at` / `_distances`（弧长边界算式）
- `_handle_generate_path` 编排框架（加 mode 分支）
- batch_id / per-item 散回执 / `BATCH_LIMIT=64` / 错误码归并 `invalid_params`
- `forge_client.py` path 子命令 + `send_and_recv_batch`
- `predict_n`（加 `mode` 默认参数，v1 调用零回归）

**continuous 新增**：
- `PathGenerator.sample` 加 `mode` 参数（continuous 返回段含 `length` 字段）
- `PathGenerator.validate` 加 `mode` + `align` 校验
- plugin continuous 分支（每段独立 `create_mesh` 注入 length）
- `predict_n` spacing 模式 −1（count 不变）

## §1 架构（minimal-diff，4 文件改，command_server 零改动）

```
addons/asset_forge/
  path_generator.gd        ← 改：sample() / validate() 加 mode 参数；continuous 分支
  asset_forge_plugin.gd    ← 改：_handle_generate_path 加 mode 分支 + 抽 _place_one helper
tools/forge_client.py      ← 改：build_path_payload 加 --mode；predict_n 加 mode 参数
command_server.gd          ← 零改动（mode 是 payload 字段，透传）
```

**PathGenerator.sample 签名**（加 mode 默认参数）：
```gdscript
# discrete（v1，默认）：返回 [{position, rotation_deg, distance}]
# continuous（v2）：返回 [{position, rotation_deg, length, distance}]  ← 加 length
static func sample(points, spacing, count, align, include_endpoints, mode := "discrete") -> Array
```

**plugin `_handle_generate_path` 加 mode 分流 + 抽 `_place_one`**：
- shared：mode 合法性 + parse + validate + sample + BATCH_LIMIT + shape/material/root 校验
- discrete：`probe_mesh` 共享，N 采样点用同一 mesh
- continuous：`probe_mesh` 仅校验 shape（不进场景，RefCounted 释放）；loop 内每段独立 `create_mesh(shape, seg_params)`（`seg_params["length"] = segment.length`）
- `_place_one(root, mesh, material, base_name, i, pos, rot, payload, batch_id, req_id, ws)` helper：构造 place_payload + `ScenePlacer.place` + `send_result`，消除两 loop 重复（顺便解 v1 F7 的一半）

## §2 算法

### 段定义（continuous 段 = 弧长边界相邻对）

- **spacing 模式**（复用 v1 边界）：边界 = v1 采样距离 `[0, s, 2s, …, total]`，段 = 相邻边界对。`floor(total/s)` 个满段 +（`include_endpoints=true` 且余数 > ε 时）1 个尾段（length = 余数 < s）。
- **count 模式**（独立等分，不复用 v1 边界）：边界 = `[i·total/N for i in 0..N]`，N 个等长段，length = total/N。

### 段几何（每段独立）

```
段 i 边界 [d_start, d_end]：
  p_start  = _position_at(d_start)          # 复用 v1
  p_end    = _position_at(d_end)
  length   = p_start.distance_to(p_end)     # 弦长（非弧长）
  position = p_start.lerp(p_end, 0.5)       # 段中点
  chord    = p_end - p_start
注入 seg_params["length"]（wall/fence 的 length 参数名一致）
```

### X 切线 yaw（length 沿 chord，与 v1 -Z 对齐差 90°）

wall/fence 长度沿 +X，把 +X 对齐到 chord：
```
yaw_deg = rad_to_deg(atan2(-chord.z, chord.x))
```
推导：`rotation_y(θ) * (1,0,0) = (cosθ, 0, -sinθ)`，令 = chord → `θ = atan2(-cz, cx)`。对照 v1 discrete `atan2(-t.x, -t.z)`，continuous = discrete + 90°（+X vs -Z）。

continuous 模式 align 强制 `"path"`（见 §3.1），故实际只有 `rotation_deg = Vector3(0, yaw_deg, 0)`。

### 转角处理（continuous 比 discrete 简单，无需 miter）

discrete 在顶点落点要算角平分线；continuous 不需要——每段有单一方向（其 chord），转角自然出现在段与段的接缝（相邻段 chord 的角度差 = 路径转角）。相邻段共享端点（`panel_i.end = panel_{i+1}.start`）→ 无空隙、无重叠，转角呈"V"形接缝。

**段跨 path 顶点**（边界是弧长等分点，通常不在 path 顶点）：该段 chord 取直跨过顶点（弦长 < 弧长，panel 不跟随转角）。长直边内无影响；仅急弯 + 长 panel 时切角明显（v3 顶点对齐分段优化）。

**零长段跳过**：path 局部重合点 / 浮点尾段重合 → length=0 段不计入 predict_n、不 place。

## §3 协议 / payload / plugin / predict_n / 测试

### 3.1 continuous 强制 align="path"

validate 加：`if mode == "continuous" and align != "path": return "continuous align 强制 path（length 沿 chord），当前 {align}"`

机制：**validate 拦截**（显式 > 静默忽略）。默认 align="path" 不受影响，仅显式 align=none/normal 报错，立刻暴露用户误解。

### 3.2 payload（mode 字段，command_server 零改动）

```jsonc
{
  "type": "generate_path",
  "id": "<req_id>",
  "payload": {
    "shape": "wall",                              // wall 或 fence（MVP 仅这俩）
    "params": { "height": 1.0, "thickness": 0.1 }, // length 由段注入；params 不写 length
    "path": [[0,0,0],[5,0,0],[5,0,5]],
    "spacing": 2.0,                                // continuous: = panel 长度
    "count": null,
    "mode": "continuous",                          // NEW，默认 "discrete"（v1 行为不变）
    "align": "path",                               // continuous 强制 path（validate）
    "include_endpoints": true,                     // count 模式忽略；spacing 模式控制尾段
    "name": "barrier", "parent": "", "save": false
  }
}
```

mode 在 payload 透传 → command_server 零改动。回执 / batch_id / undo 语义与 v1 完全一致（N 条 generate_result 共享 req_id，一条 undo_last 全删）。

### 3.3 plugin `_on_command` path 分支（shared 验证 + mode 分流）

```
if payload.has("path"):
    mode = payload.get("mode", "discrete")
    if mode not in ["discrete", "continuous"]: invalid_params; return
    pts = parse_path(...); if error: invalid_params; return
    verr = validate(points, spacing, count, align, include_endpoints, mode); if verr: invalid_params; return
    samples = sample(points, spacing, count, align, include_endpoints, mode)
    if samples.size() > BATCH_LIMIT: invalid_params; return
    shape = payload.get("shape", "")
    probe_mesh = create_mesh(shape, params)          # shape 校验（continuous 下创建后丢弃）
    if probe_mesh == null: unsupported_shape; return
    material = create_material(...)
    root = get_edited_scene_root(); if null: no_active_scene; return
    base_name = payload.get("name", "") or shape
    if mode == "discrete":
        for i, s in samples:                         # 共享 probe_mesh
            _place_one(root, probe_mesh, material, base_name, i, s.position, s.rotation_deg, ...)
    else:                                            # continuous：每段独立 create_mesh
        for i, seg in samples:
            seg_params = params.duplicate()
            seg_params["length"] = seg.length
            seg_mesh = create_mesh(shape, seg_params)
            _place_one(root, seg_mesh, material, base_name, i, seg.position, seg.rotation_deg, ...)
    mark_scene_as_unsaved()
    return

# _place_one helper：构造 place_payload {name:"{base}_{i}", transform:{position,rotation_deg}, parent, save}
#                       + ScenePlacer.place(..., batch_id) + send_result
```

### 3.4 客户端 predict_n（加 mode 参数，spacing 模式 -1）

```python
def predict_n(path, spacing, count, include_endpoints, mode="discrete"):
    n = _predict_n_discrete(path, spacing, count, include_endpoints)  # v1 公式
    if mode == "continuous" and spacing and spacing > 0:              # spacing: N 点 → N-1 段
        return max(0, n - 1)
    return n                                                          # count 模式 / discrete 不变
```

- count 模式 continuous = N（同 v1）
- spacing 模式 continuous = v1 点数 − 1（几何必然：N 点 → N−1 段）
- `max(0, n-1)` 防短路径段数 0/负
- v1 调用 `predict_n(...)` 不传 mode → 默认 discrete → v1 6 个 pytest 零回归

`forge_client.py` path 子命令加 `--mode discrete|continuous`（默认 discrete）；`build_path_payload` 加 mode 字段；`send_and_recv_batch(ws, msg, predict_n(..., mode))`。

**A 点（include_endpoints 语义）已落定**：count 模式 N 等长段恒铺满、include_endpoints 无意义（predict_n count 分支不读它）；spacing 模式 include_endpoints 控制尾段（predict_n 依赖）。与 v1 一致，无需特判。

### 3.5 错误码（复用 v1，无新增）

- mode 非 discrete/continuous → `invalid_params`
- continuous + align≠path → `invalid_params`
- continuous + shape 非 wall/fence → `unsupported_shape`（v1 复用，message 注明 continuous 仅支持 wall/fence）
- path<2 / total=0 / spacing/count 互斥 / samples>BATCH_LIMIT → `invalid_params`
- count 模式 continuous count=1 合法（1 段 = total，与 v1 discrete F5 不同——discrete count=1 + endpoints=true 才非法）

### 3.6 测试补充

| 文件 | 新增用例 |
|---|---|
| `test_path_generator.gd` | continuous sample：count N 等长段 / spacing 满段+尾段 / 段 chord length / position=midpoint / yaw=X 沿 chord（与 discrete 差 90°）/ 零长段跳过；validate：continuous+align≠path 报错 / mode 非法 / continuous count=1 合法 |
| `test_forge_client_predict.py` | predict_n continuous count = v1 / continuous spacing = v1−1 / discrete 不变（mode 默认） |
| `test_command_server.gd` | payload.mode 透传（emit 时 payload 含 mode，验证 command_server 零改动） |
| selftest | continuous wall 沿 L 路径 + undo 原子（与 discrete selftest 并列） |

## 朝向约定注记（写进 docs）

continuous 模式 align 强制 `"path"`：length 沿 chord 是连续拼接的几何本质，align 无独立语义（none/normal 会让墙不沿路径，断裂）。validate 拦截显式 align≠path。

**fence 段接缝端柱重合（z-fighting）**：fence 是组合 mesh（柱+横档，`make_fence` posts 默认 4、含两端），continuous 相邻段共享端点（`panel_i.end == panel_{i+1}.start`）→ **每个段接缝（含直段，非仅转角）两根端柱精确重合 → z-fighting 闪烁**（深度冲突，非"紧贴"）。原"转角端柱重叠 / 真实围栏也有双柱"措辞低估范围——直段每接缝也重合，而真实围栏直段一接缝一柱。MVP 接受为 preview 级瑕疵：生产栅栏用 `mode=discrete` 或等 v3（顶点对齐分段 + 端柱去重）。wall 是简单 box，端点对接无缝。

## 实施顺序提示（详细计划由 writing-plans 出）

1. `path_generator.gd`：sample/validate 加 mode 参数 + continuous 分支 + `_predict_n_discrete` 抽出（v1 公式）→ `test_path_generator.gd` continuous 用例
2. `asset_forge_plugin.gd`：`_handle_generate_path` 加 mode 分流 + 抽 `_place_one` helper
3. `tools/forge_client.py`：`--mode` 参数 + `build_path_payload` mode 字段 + `predict_n` 加 mode 参数 → `test_forge_client_predict.py` mode 用例
4. `test_command_server.gd`：mode 透传用例
5. 文档（`docs/protocol.md` mode 字段 + `README.md` continuous 示例 + fence 端柱注记）+ selftest continuous 集成
