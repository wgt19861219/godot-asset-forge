# v6 ramp continuous 接缝高度衔接 设计

> **状态**：已定范围（v5 已完结；v6 解 v5 留的 ramp continuous 接缝高度台阶已知局限）
> **基线**：v5 完结（master 66a21db，210 headless + 17 pytest + selftest 全 green）
> **设计审查**：独立 reviewer 两轮——第 1 轮设计 checklist（Lake Score 3/3）+ 第 2 轮 spec 文档审查（2 CRITICAL + 2 IMPORTANT + 4 ADVISORY，本 spec 据此修订）
> **范围性质**：minimal-diff，单件/discrete ramp 字节级零回归（PrismMesh 不动），仅 continuous ramp 衔接

---

## 目标

1. **解 continuous 模式 ramp 相邻段接缝高度台阶**（v5 留的已知局限）：PrismMesh 斜面在 Y 方向（高度 0→height），每段独立 → 段 i 末端高度 ≠ 段 i+1 首端高度，接缝处台阶。v6 让各段端点高度衔接（连续斜面，恒定坡度），**折线路径下也要解**（v5 留的局限本就是折线下台阶）。
2. **支持下降**（rise<0）：整条路径从 0 降到 rise（凹槽/下坡），与上升对称。

## 背景

### ramp continuous 现状（v5 完结后）

- `asset_factory.gd:40-48` ramp = PrismMesh（`size = Vector3(length, height, width)`, `left_to_right = 0.0`）。PrismMesh **不支持端点高度**。
- continuous 放置层（`asset_forge_plugin.gd:289-314`）：每段独立 `create_mesh("ramp", seg_params)`，`seg_params["length"] = seg["length"]`。每段 PrismMesh 沿 X 从 0 升到 height → **段 i 末端（height）与段 i+1 首端（0）高度突变 = 台阶**。
- v5 白名单 `:240` 已放行 ramp，但接缝台阶未解。

### path_generator segment 的弧长 vs 弦长（CRITICAL 2 背景）

`_sample_continuous`（`path_generator.gd:108-175`）返回 segment dict：
- `distance` = 段起点**弧长** d_start（累计）
- `length` = `p_start.distance_to(p_end)` = **弦长**（直线距离）

段不跨折线顶点时（va 模式，段边界=顶点）弦长=弧长；段跨折线顶点时（spacing/count 模式）**弦长 < 弧长**。v6 高度分配必须用**弧长**（恒定坡度的物理基础），不能用弦长——否则折线下衔接错 + 坡度被弯曲段压低。

### _total_length 已存在

`PathGenerator._total_length(points)`（`path_generator.gd:195`）返路径弧长总和。placement 层可调（GDScript 静态 `_` 前缀外部可调，与 v5 `CustomMeshes._post_xs` 单测同模式）。

## 设计

### 设计点 1：`CustomMeshes.make_ramp(params)` 手写 wedge 几何

新增手写 ArrayMesh（与 make_fence/make_stairs 同 SurfaceTool 模式），支持两端独立高度。

**参数**：`length`（沿 X，默认 2.0）/ `width`（沿 Z，默认 1.0）/ `start_height`（默认 0.0，X=−length/2 端）/ `end_height`（默认 height 或 1.0，X=+length/2 端）。

**8 顶点**（hl = length/2，hw = width/2，sh = start_height，eh = end_height）：

| 顶点 | 坐标 |
|------|------|
| D0 | (−hl, 0, −hw) 底面后左 |
| D1 | (−hl, 0, +hw) 底面前左 |
| D2 | (+hl, 0, +hw) 底面前右 |
| D3 | (+hl, 0, −hw) 底面后右 |
| T0 | (−hl, sh, −hw) 顶面后左 |
| T1 | (−hl, sh, +hw) 顶面前左 |
| T2 | (+hl, eh, +hw) 顶面前右 |
| T3 | (+hl, eh, −hw) 顶面后右 |

**6 面绕序约定（统一 _add_box 约定，CRITICAL 1 修订）**：每面 `_add_face` 4 顶点的顺序让**几何法线（cross 乘积）朝楔形内部**，`set_normal` 手设**朝外**法线。这与 `_add_box`（`custom_meshes.gd:177-182`，stairs/fence 已验证可见）**完全同约定**。不调 `index()`/`generate_normals()`（与 _add_box 一致，避免平滑）。

| 面 | 顶点（CCW，几何法线朝内） | set_normal（朝外） |
|------|------|------|
| 底面（Y=0，内侧 +Y） | D1, D2, D3, D0 | (0, −1, 0) |
| 斜顶（内侧 −Y 为主） | T0, T3, T2, T1 | **(sh − eh, length, 0).normalized()** |
| 前面（Z=+hw，内侧 −Z） | D1, T1, T2, D2 | (0, 0, +1) |
| 后面（Z=−hw，内侧 +Z） | D0, D3, T3, T0 | (0, 0, −1) |
| 左端（X=−hl，内侧 +X） | D0, T0, T1, D1 | (−1, 0, 0) |
| 右端（X=+hl，内侧 −X） | D2, T2, T3, D3 | (+1, 0, 0) |

每面几何法线已用 cross 乘积验证朝内（如斜顶 T0,T3,T2,T1 几何 = (eh−sh, −length, 0)，上升 eh>sh 时 Y 分量 −length < 0 朝下 = 朝楔形内 ✓）。

**斜顶 set_normal 关键**：`(sh − eh, length, 0).normalized()`——Y 分量恒 `+length > 0`（朝上外），无论上升（sh<eh，X 分量负）或下降（sh>eh，X 分量正）。必须归一化（与 `_add_box` 单位向量风格一致）。

**F5 实测验证（CRITICAL 1 修订，reviewer 黄金标准）**：绕序统一 _add_box 约定后，plan 实现第一步跑 `make_ramp({"length":2,"width":1,"start_height":0,"end_height":1})` 在编辑器 F5 肉眼确认 6 面全可见（无 cull 缺面）。若 _add_box 约定下某面被 cull（culling 行为与预期反），则反转全部 6 面顶点顺序（相反约定）——以 F5 可见性为准。**此验证是绕序正确性的最终判据**（cross 乘积理论分析在 Godot culling 语义下有歧义，实测定论）。

**单 `commit()` 单 surface**（A3 不变量）：6 面进同一 SurfaceTool 再 commit。

**退化面**：start_height=0 时左端面（D0,T0,T1,D1）退化为零面积（T0/T1 与 D0/D1 共 Y=0），仍提交不渲染。end_height=0 时右端面同理。**不特殊处理**（与 make_stairs/make_fence 总是提交 6 面一致）。注意：`_add_box` 不退化（box 两端高度同），此处 wedge 端面可退化，**不类比 _add_box 退化行为**。

### 设计点 2：下降支持（Δh<0，决策 1，复审物理修正）

下降场景：用户传负 `height`（rise<0），整条路径从高到低（下坡）。**楔形始终朝上**（斜面是上表面，法线 +Y，你踩的面），下降 = 各段 start_h > end_h（Δh<0，正高度递减）。

**复审修正（原 §2 sign 系数倒置楔形物理错误）**：原 spec §2 的 sign 系数让 start_h/end_h<0（楔形倒置，底面 Y=0 在上、斜面 Y<0 在下）→ 斜面在 path 平面以下（向下尖的钟乳石），不是下坡面。reviewer 决策 1 "Δh<0 斜顶法线自动朝上"的真意是**楔形朝上**，由斜顶法线公式 `(sh − eh, length, 0).normalized()` 自动保证（Y 分量恒 +length > 0，无论 Δh 符号），**无需 sign 分支**。

**修正实现**：
- **make_ramp 无 sign 分支**：start_height/end_height ≥ 0（楔形在 Y≥0，朝上），Δh 任意（上升 sh<eh / 下降 sh>eh）。6 面顶点顺序（§1 表）对上升下降都适用——已 cross 验证：斜顶 T0,T3,T2,T1 几何法线 Y 分量 = −length（朝楔形内）无论 Δh 符号；前面 D1,T1,T2,D2 几何 −Z（sh>0 时）无论 Δh。斜顶 set_normal `(sh − eh, length, 0).normalized()` 自动 Y+（上升 sh<eh X 负 / 下降 sh>eh X 正，Y 恒 +length）。
- **`_compute_seg_heights` 处理 rise 符号**（§4）：rise≥0 上升（start_h/end_h 从 0 到 rise，递增）；rise<0 下降（start_h/end_h 从 |rise| 到 0，递减，都 ≥0）。
- **placement 注入 start_h/end_h ≥0**（§6），make_ramp 收到正高度。

**约束**：make_ramp 要求 start_height, end_height ≥ 0（placement 保证）。单件手传负值或混合符号 → 几何退化（斜面穿过底面或倒置），不报错但视觉破损，用户负责。

**下降 UX**：continuous ramp 下降直接传负 `height`（如 `--height -1`）；单件 PrismMesh 下降用节点 `rotation_deg` 或 `left_to_right`。

### 设计点 3：`height` = 总升高（无新参数）

continuous 模式下 `height`（ramp 既有参数，默认 1.0）语义 = **整条路径总升高 rise**（起点 0，终点 height）。各段端点高度 = `height × (累计弧长 / 总弧长)`。

- 单件/discrete ramp：`height` = 顶端高度（PrismMesh 语义不变，零回归）。
- continuous ramp：`height` = 路径终点高度（= 总升高幅值）。语义"ramp 达到的最大高度"两种模式一致。

### 设计点 4：`PathGenerator._compute_seg_heights` 纯函数（决策 2 + CRITICAL 2 弧长修订）

提取纯函数（与 `_post_xs`（v5）并列，可独立 headless 单测）。**用弧长不用弦长**（CRITICAL 2）：段 i 的 d_end = 段 i+1 的 d_start（弧长衔接，因 `_sample_continuous` boundaries 连续），末段 d_end = total_len（placement 传 `_total_length(points)`）。**不用 `seg["length"]`**（弦长，跨折线顶点时 < 弧长）。

```gdscript
# v6 continuous ramp 高度分配：rise 按累计弧长比例分到各段端点（恒定坡度）
# 段 i 的 d_end = 段 i+1 的 d_start（弧长衔接，boundaries 连续）；末段 d_end = total_len
# 注意：seg["length"] 是弦长（p_start.distance_to(p_end)），跨折线顶点时 < 弧长，不能用（CRITICAL 2）
# rise 符号：≥0 上升（0→rise 递增）；<0 下降（|rise|→0 递减，正高度，楔形朝上，§2 物理修正）
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
			# 下降：abs_rise → 0（递减，正高度，楔形朝上）
			heights.append({"start_h": abs_rise * (total_len - d_start) / total_len, "end_h": abs_rise * (total_len - d_end) / total_len})
	return heights
```

**关键性质**：
- 段 i `end_h` = 段 i+1 `start_h`（高度衔接，无台阶）——折线下也成立（用弧长）
- 首段 `start_h` = 0（路径起点）
- 末段 `end_h` = rise（路径终点 = 总升高）
- 坡度恒定 = rise/total_len（每段升高 = rise × 段弧长/total，段弧长长的升得多）
- va 模式（段长不等）+ spacing/count 跨折线顶点模式都正确（弧长基础）

**守卫**：`assert(samples.size() > 0)` + `assert(total_len > 0.0)`（A2，ADVISORY）。total_len 由 placement 传 `_total_length(points)`（>0，validate 保证 path 总长 >_EPS）。

### 设计点 5：`asset_factory.gd` ramp 分流（零回归关键 + feature）

```
"ramp":
    if params.has("start_height") or params.has("end_height"):
        return CustomMeshes.make_ramp(params)   # v6 continuous 衔接（手写 wedge）
    var m := PrismMesh.new()                      # 现状（单件/discrete 不动）
    m.size = Vector3(float(params.get("length", 2.0)), float(params.get("height", 1.0)), float(params.get("width", 1.0)))
    m.left_to_right = 0.0
    return m
```

**此为 feature（非 leak）**：单件 generate ramp 也可用 `{"start_height": ..., "end_height": ...}` 触发手写 wedge（自定义两端高度的独立楔形）。discrete/单件默认 params 不含 start_height/end_height → PrismMesh 完全不动，字节级零回归。

### 设计点 6：placement 层 continuous ramp 高度注入（CRITICAL 2 弧长）

`_handle_generate_path` continuous 分支（v5 fence 端柱 `if shape == "fence":` + v6 `elif shape == "ramp":`）。`_compute_seg_heights` 循环外算一次，`total_len = PathGenerator._total_length(points)`（弧长，非末段 distance+length 弦长反推——CRITICAL 2）：

```gdscript
else:  # continuous：每段独立 create_mesh（length + fence 端柱 / ramp 高度注入）
    var seg_count: int = samples.size()
    var ramp_heights: Array = []  # v6：ramp 高度衔接，循环外算一次（仅 ramp 用）
    if shape == "ramp":
        var rise: float = float(base_params.get("height", 1.0))
        var total_len: float = PathGenerator._total_length(points)  # 弧长总和（CRITICAL 2：非弦长）
        ramp_heights = PathGenerator._compute_seg_heights(samples, total_len, rise)
    for i in seg_count:
        var seg: Dictionary = samples[i]
        var seg_params: Dictionary = base_params.duplicate()
        seg_params["length"] = seg["length"]
        if shape == "fence":
            seg_params["start_post"] = true
            seg_params["end_post"] = i == seg_count - 1
        elif shape == "ramp":
            seg_params["start_height"] = float(ramp_heights[i]["start_h"])
            seg_params["end_height"] = float(ramp_heights[i]["end_h"])
        var seg_mesh := AssetFactory.create_mesh(shape, seg_params)
        _place_one(root, seg_mesh, material, base_name, i, seg["position"], seg["rotation_deg"], payload, batch_id, seg_count, req_id, ws)
```

**仅 ramp 注入** start_height/end_height。discrete 不进此分支 → 零回归。`points` 是 `_handle_generate_path` 局部变量（`:175-196` 解析），continuous 分支可访问。

## 测试矩阵

### headless 单测

**`tests/test_custom_meshes.gd`** 新增 make_ramp A3 用例（对称既有 fence/stairs）：

| # | params | 断言 |
|---|--------|------|
| 1 | `{"length":2,"width":1,"start_height":0,"end_height":1}` 默认上升 | ArrayMesh + 单 surface + 顶点>0 + 索引合法（A3） |
| 2 | `{"length":2,"width":1,"start_height":0.2,"end_height":0.8}` 自定义两端 | A3 + 顶点数与 #1 不同 |
| 3 | `{"length":2,"width":1,"start_height":0,"end_height":0}` 水平段（退化） | A3 + 不报错（height=0） |
| 4 | `{"length":2,"width":1,"start_height":1.0,"end_height":0.5}` 下降（Δh<0，正高度递减） | A3 + 斜顶法线 Y>0（楔形朝上，§2 物理修正） |

**斜顶法线断言**（决策 3，复用 `test_custom_meshes.gd:56-78` I-3 模式）：从 make_ramp 返回的 ArrayMesh 取 `ARRAY_NORMAL`，断言斜顶面顶点法线 Y>0（上升下降都朝上）+ 模长 ≈ 1（归一化）。

**绕序可见性（CRITICAL 1 测试盲区）**：headless 无法测 culling（需渲染）。绕序正确性靠 **F5 实测**（§1 黄金标准）+ selftest 编辑器视觉验证。headless 单测只验证 A3（结构）+ 法线（光照方向），不验证 culling。

**`tests/test_path_generator.gd`** 新增 `_compute_seg_heights` 纯函数单测（决策 2 + CRITICAL 2 折线覆盖）：

| # | 输入（samples distance/length） | total_len | rise | 断言 |
|---|------|------|------|------|
| 1 | 等长 3 段直线 `[{0,3},{3,3},{6,3}]` | 9 | 3 | `[{0,1},{1,2},{2,3}]`（衔接 + 首尾 + 坡度 1/3） |
| 2 | **折线弦长<弧长** `[{distance:0,length:1.8},{distance:2,length:2.7},{distance:5,length:3.6}]`（length 弦长 1.8/2.7/3.6 **小于** 弧长差 2/3/4，模拟跨折线顶点） | 9 | 5 | 段 i end_h = 段 i+1 start_h（**用 distance 弧长衔接，非 length 弦长**），段 0 end_h = 5×2/9 ≈ 1.111（误用 length 得 5×1.8/9 = 1.0，衔接断测试失败）+ 末段 end_h=5 + 坡度 5/9 恒定 |
| 3 | rise<0 下降，等长 3 段（d: 0/3/6/9） | 9 | −3 | `[{3,2},{2,1},{1,0}]`（递减，正高度，楔形朝上——§2 物理修正） |
| 4 | 单段 | 5 | 2 | `[{0,2}]` |

**用例 #2 关键**（CRITICAL 2）：samples 的 `length`（弦长）与 `distance` 差（弧长）不相等，验证 `_compute_seg_heights` 用 distance（弧长）衔接而非 length（弦长）。若误用 length，段间 end_h/start_h 不衔接（台阶重现）。

**`tests/test_asset_factory.gd`** 新增分流单测：

| # | 调用 | 断言 |
|---|------|------|
| 1 | `create_mesh("ramp", {"start_height":0.5})` | 返回 ArrayMesh（触发手写） |
| 2 | `create_mesh("ramp", {})` 现有用例 | 返回 PrismMesh（零回归） |

### selftest（`tools/forge_client.py::run_selftest`，ADVISORY A4 修订）

v5 已有 continuous ramp（直线 count=3）。v6 **加一条折线 visual 验证**（L 路径，跨顶点，验证 CRITICAL 2 弧长衔接在折线下也通）：

```python
# v6 generate_path continuous + ramp（L 路径 count=3，高度衔接，验证折线弧长分配）
ramp_v6_results = await send_and_recv_batch(
    ws,
    {"type": "generate_path", "id": "st_v6_ramp",
     "payload": {"shape": "ramp", "path": [[0,0,0],[3,0,0],[3,0,3]], "count": 3,
                 "mode": "continuous", "height": 2, "material": "stone", "name": "st_v6_ramp"}},
    3,
)
ok = len(ramp_v6_results) == 3 and all(bool(r.get("success")) for r in ramp_v6_results)
# 高度衔接属视觉验证（编辑器手测看接缝台阶消除 + 各段端点高度连续），selftest 验证生成链路通
```

**高度衔接 + 绕序可见性属视觉验证**（编辑器手测），selftest 验证生成/undo 链路通。

## 文档

- **`docs/shapes-reference.md:12`** ramp 注记：从 v5「接缝高度台阶为已知局限」改为「v6 已解：continuous 模式 height 作总升高，各段按累计弧长比例衔接（`_compute_seg_heights`），恒定坡度；支持下降（height 负）」。补 `start_height`/`end_height` 参数说明。
- **`docs/protocol.md:83`** + **`README.md:115`** continuous 段：ramp 接缝台阶注记从「已知局限」改为「v6 已解（高度衔接）」。
- **`README.md:88`** + **`docs/shapes-reference.md:12`** ramp 参数表补 `start_height`/`end_height`（避免 fence 参数文档不一致覆辙）。

## defects.md note 纠偏（v6 实现 commit 一并改，不单独提）

`D:\workspace\review\.claude\knowledge\projects\godot-asset-forge\defects.md` `shared-vertex-box-smooth-normals` 条目**两字段**纠偏（复审修订：fix-forward :41 + note :44）：
- **:41 fix-forward**：「24 顶点 + generate_normals() 自然得轴对齐」→ 改为「`_add_face` + `set_normal` 手设面法线 + 不调 `index()`/`generate_normals()`」（与 `custom_meshes.gd:178-211` 实际一致）
- **:44 note**：「test_custom_meshes.gd 未查法线（测试盲区）」→ 改为「I-3 已补 box 法线轴对齐断言（`test_custom_meshes.gd:56-78`），v6 make_ramp 斜顶法线断言扩展之」

## 范围边界（YAGNI）

**v6 做**：
- `CustomMeshes.make_ramp`（手写 wedge，8 顶点 6 面，start_height/end_height，上升 + 下降，绕序统一 _add_box 约定 + F5 验证）
- `asset_factory` ramp 分流（params 含 start_height/end_height → 手写，否则 PrismMesh）
- `PathGenerator._compute_seg_heights` 纯函数（弧长基础，单测含折线用例）
- placement 层 continuous ramp 高度注入（`_total_length(points)` + `_compute_seg_heights`）
- 测试：make_ramp A3 + 斜顶法线 + 下降 + 水平；_compute_seg_heights 含折线/下降；分流；selftest 折线 visual
- 文档同步 + defects.md `:41` fix-forward 纠偏

**v6 不做**：
- mesh 缓存（YAGNI）
- make_ramp 的 start_height/end_height 直接暴露为 CLI flag（continuous 自动注入足够）
- PrismMesh ramp 的 left_to_right 暴露（单件保持现状）

## 不变量（修改时保留）

1. **make_ramp 仍烘焙单 ArrayMesh（单 surface）**——A3。6 面进同一 SurfaceTool 再 commit。
2. **单件/discrete ramp 字节级零回归**——params 不含 start_height/end_height → PrismMesh 完全不动。
3. **continuous 高度衔接仅 ramp 注入**——fence/wall 不注入 start_height/end_height。
4. **`_compute_seg_heights` 是纯函数**——用弧长（distance）不用弦长（length），可独立 headless 单测。
5. **斜顶 set_normal Y 分量恒正**（朝上）：`(sh − eh, length, 0).normalized()` 无论上升（sh<eh）/下降（sh>eh）。
6. **make_ramp start_height/end_height ≥ 0**（楔形朝上，§2 物理修正）：placement `_compute_seg_heights` 保证注入正高度（rise<0 下降时 |rise| 递减，不倒置）。

## 触点（完整清单）

- `addons/asset_forge/custom_meshes.gd`：新增 `make_ramp`（6 面绕序统一 _add_box 约定）
- `addons/asset_forge/asset_factory.gd:40-48`：ramp 分流
- `addons/asset_forge/path_generator.gd`：新增 `_compute_seg_heights` 纯函数（弧长基础）
- `addons/asset_forge/asset_forge_plugin.gd:289-314`：continuous 分支加 `elif shape == "ramp"` 高度注入（`_total_length(points)`）
- `tests/test_custom_meshes.gd`：make_ramp A3 + 斜顶法线 + 下降 + 水平
- `tests/test_path_generator.gd`：`_compute_seg_heights` 4 例（含折线弧长 CRITICAL 2 覆盖）
- `tests/test_asset_factory.gd`：ramp 分流 2 例
- `tools/forge_client.py`：selftest 加 v6 continuous ramp L 路径（折线 visual）
- `docs/protocol.md` / `README.md` / `docs/shapes-reference.md`：ramp 接缝 v5 局限 → v6 已解 + 补参数
- `D:\workspace\review\.claude\knowledge\projects\godot-asset-forge\defects.md` :41 fix-forward + :44 note：box-smooth-normals 两字段纠偏（v6 commit 一并改）
