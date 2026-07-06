# 路径顶点对齐分段（v4）— 设计文档

- **日期**：2026-07-06
- **状态**：设计已确认（含 reviewer 评审修正），待写实施计划
- **关联**：[v1 discrete 设计](2026-07-05-procedural-path-array-design.md) · [v2 continuous 设计](2026-07-05-path-continuous-design.md) · [v3 Path3D 输入设计](2026-07-06-path3d-input-design.md)（v4 复用 v1-v3 框架，本文档只写差异 + 新增）

## 目标

为 continuous 模式加 `align_vertices` opt-in 参数（默认 false）——true 时把折线每个**顶点**强制设为段边界，让栏板在转角处自然断开，不再横跨转角"切角"。顺带激活 `_sample_continuous` 里 v2 review 记的 `vertex_d` 死代码。

```bash
# v4 顶点对齐：栏板在折线转角处断开，转角不切角
python tools/forge_client.py path fence --path '[[0,0,0],[4,0,0],[4,0,4]]' --spacing 3 --mode continuous --align-vertices --mat wood
# 不带 --align-vertices = v2 等间距（栏板可能横跨转角，chord 直连转角两侧 → 切角）
```

**痛点实证**（L 形折线 `[(0,0,0),(4,0,0),(4,0,4)]`，两段各 4m，spacing=3）：
- v2 等间距：boundaries `[0,3,6,8]`，段 `3→6` 横跨转角顶点(4,0,0)——栏板从 (3,0,0) 直连 (4,0,2)，**切掉转角**。
- v4 顶点对齐：boundaries `[0,3,4,7,8]`（顶点 4 强制为边界），段在转角处断开，栏板贴着折线铺。

## 非目标（YAGNI）

- **discrete 顶点对齐** —— 不做。discrete 是点采样、无段概念，va 在 discrete 无定义；`va+discrete` 报错暴露用户误解（非静默忽略，见 §2.1）。
- **count 模式顶点对齐** —— 不做。count=N 的边界是 `i·total/N` 等分点，几乎从不对齐 path 顶点；`va+count` 报错（同上理由）。
- **短尾均分 / 短尾并入前段 / 短尾丢弃** —— 不做。已选"短尾保留"（每折线段独立按 spacing 切，余数留短尾段）。丢弃破坏顶点对齐（顶点=边界语义），均分/并入改变 spacing 语义。
- **fence 端柱去重** —— 不做（推 v5）。fence 沿 continuous 放置时相邻段接缝端柱重叠 z-fighting 是独立 mesh 改造（`make_fence` 加 start/end_post 参数 + 放置层共享端点），与顶点对齐正交；v2 就存在，非 v4 引入。
- **va 模式 include_endpoints 行为变化** —— 不做。va 已保证顶点=边界（等价强制补尾），include_endpoints 在 va 下冗余，静默忽略（文档注明，非冲突）。

## 关联 v1/v2/v3：复用面 vs 新增

**复用**（零改动或加默认参数）：
- `_sample_continuous` 框架（seg_len / vertex_d / boundaries / 段生成 :127-147）
- `validate` 报错原则（v2 spec §3.1「显式拦截 > 静默忽略」，`continuous+align≠path` 选择报错的同一原则——va 与不兼容模式冲突同样报错）
- `BATCH_LIMIT`（仍护段数）/ A7 samples 空守卫（v3）/ v3 result total 字段
- `command_server`（**零改动**，align_vertices 是 payload 字段透传，同 v3 path_node）
- `_handle_generate_path` 编排 / `_place_one`（v2/v3 已抽，零改动）

**v4 新增**：
- `align_vertices: bool = false` 参数（sample / `_sample_continuous` / validate 三处）
- `_sample_continuous` 内 va 分支（boundaries 生成处加 `if align_vertices:` 优先分支）
- validate 2 条不兼容模式报错（discrete+va / continuous+va+count）
- `forge_client --align-vertices` + `predict_n` va 分支（段数预校验）
- **顺带**：激活 `_sample_continuous:102-108` 的 `vertex_d` 死代码（v2 Task 1 review 记的 Minor，va 分支用它做段区间）

## §1 架构（minimal-diff，2 文件核心改，command_server 零改动）

```
addons/asset_forge/
  path_generator.gd        ← 改：sample/_sample_continuous/validate 加 align_vertices + va 分支（核心）
  asset_forge_plugin.gd    ← 改：_handle_generate_path 透传 align_vertices（1 行）
tools/forge_client.py      ← 改：--align-vertices + build_path_payload + predict_n va 分支
docs/protocol.md/README.md ← 改：align_vertices 字段 + 示例 + 极短尾注记
```

**接口签名**（3 处加 `align_vertices: bool = false`，默认 false = v2 字节级零回归）：
```gdscript
static func sample(
    points: Array, spacing: float, count: int, align: String,
    include_endpoints: bool, mode := "discrete", align_vertices := false
) -> Array:
    if mode == "continuous":
        return _sample_continuous(points, spacing, count, include_endpoints, align_vertices)
    # discrete 分支不传 align_vertices（零改动，discrete 不看此参数）

static func _sample_continuous(
    points: Array, spacing: float, count: int, include_endpoints: bool, align_vertices := false
) -> Array:

static func validate(
    points: Array, spacing: float, count: int, align: String,
    include_endpoints: bool, mode := "discrete", align_vertices := false
) -> String:
```

**validate 新增 2 条不兼容模式报错**（追加在 validate 末尾、`return ""` 之前——让所有 v2 既有校验先报，va+count+spacing 这种被 spacing/count 互斥先拦截，va+count 无 spacing 才落到此报错）：
```gdscript
if align_vertices and mode == "discrete":
    return "align_vertices 仅 continuous 模式可用"
if align_vertices and mode == "continuous" and count >= 1:
    return "align_vertices 仅 spacing 模式可用（count 等分边界不对齐顶点）"
# include_endpoints + va：静默忽略（冗余非冲突，文档注明，不报错）
```

**va 分支算法**（`_sample_continuous` 内 boundaries 生成处 `:110-125`，加 `if align_vertices:` 优先分支；validate 已保证 mode==continuous 且 spacing>0）：
```gdscript
# vertex_d（:102-108）从此被 va 分支激活，不再是死代码
if align_vertices:
    for i in range(last):  # 折线段 i: vertex_d[i] → vertex_d[i+1]
        var seg_start: float = float(vertex_d[i])
        var seg_end: float = float(vertex_d[i+1])
        if float(seg_len[i]) < _EPS:
            continue  # 零长折线段跳过（其末顶点 = 下段起点，不丢顶点）
        if boundaries.is_empty():
            boundaries.append(seg_start)  # ★ 首段才补起点（跨段共享顶点：前段末已 append seg_end = 本段 seg_start）
        var d := seg_start + spacing
        while d < seg_end - _EPS:
            boundaries.append(d)
            d += spacing
        # ★ 段末去重（复用 v2 :117 补尾模式，防御浮点近似整除时 while 末点 ≈ seg_end 产生重复边界 → 零长段）
        if (seg_end - float(boundaries[boundaries.size() - 1])) > _EPS:
            boundaries.append(seg_end)
elif spacing > 0.0:
    # v2 spacing 分支不变（:112-118）
elif count >= 1:
    # v2 count 分支不变（:119-125）
# 段生成（:127-147）零改动，直接吃新 boundaries
```

**关键设计点**：
1. **顶点=边界**：va 模式下每个折线顶点（`vertex_d[i]`）强制为段边界。两顶点之间独立按 spacing 切，整除余数留短尾段（如 4m 段 spacing=3 → 边界 0,3,4 → 段 [0,3] 长 3 + 段 [3,4] 长 1 短尾）。
2. **vertex_d 激活**：v2 `_sample_continuous` 算了 vertex_d（:102-108）但未用（死代码，v2 review 记）。va 分支用它做折线段区间 `[vertex_d[i], vertex_d[i+1]]`——死代码转为核心。
3. **段末去重**：`while d < seg_end - _EPS` 已使 while 内 d 严格 < seg_end，但浮点累加在极端 spacing（如 0.1 反复加）下边界微妙；段末 append 前复用 v2 :117 `(seg_end - last) > _EPS` 守卫，防御性 + 与 v2 风格统一。
4. **跨段共享顶点**：`if boundaries.is_empty()` 守卫确保只在首段补 `seg_start`，后续段不重复补（前段末 `append(seg_end)` 已是本段 `seg_start`）。中间零长折线段跳过后，下段 `is_empty()` 仍能正确补起点。
5. **短尾保留**：va 语义必然（丢短尾 = 丢顶点对齐）。短尾段经段生成 :134 `if length < _EPS: continue` 过滤——极短尾（< 0.1mm）会被跳过（该顶点对齐了 boundary 但无 mesh，工程可忽略，文档注记）。
6. **discrete 零改动**：sample 的 discrete 分支不传 align_vertices；discrete 现有 miter 切线 / `_distances` 等点采样逻辑全保留。

## §2 协议 / 错误处理 / 测试

### 2.1 错误处理（2 条新 invalid_params，复用 v2 §3.1「显式拦截 > 静默忽略」原则）

| # | 条件 | message |
|---|---|---|
| 1 | align_vertices + discrete | align_vertices 仅 continuous 模式可用 |
| 2 | align_vertices + continuous + count | align_vertices 仅 spacing 模式可用（count 等分边界不对齐顶点）|

**为什么不静默忽略**：va 语义是"顶点=边界"。count 等分边界（`i·total/N`）与 discrete 点采样都几乎不对齐 path 顶点。静默忽略 = 用户以为对齐了实际没有 = 静默误导。与 v2 `continuous+align≠path` 选择报错（v2 spec §3.1）同性质冲突，一致报错。include_endpoints+va 是冗余非冲突，静默忽略 OK。

后续复用 v1/v2/v3：mode / align / spacing-count 互斥 / BATCH_LIMIT / continuous shape 白名单 / no_active_scene / A7 samples 空。

### 2.2 payload（align_vertices 字段，默认 false）

```jsonc
{
  "type": "generate_path",
  "id": "<req_id>",
  "payload": {
    "shape": "fence",
    "path": [[0,0,0],[4,0,0],[4,0,4]],
    "spacing": 3,
    "mode": "continuous",            // va 仅 continuous+spacing 生效
    "align_vertices": true,          // 新字段，默认 false（false = v2 等间距）
    "material": "wood",
    "name": "fence", "parent": "", "save": false
  }
}
```

`align_vertices` 布尔，默认 false。`false` / 不传 = v2 等间距行为（零回归）。`include_endpoints` 在 va 下被忽略（va 已保证顶点=边界）。

### 2.3 CLI（--align-vertices）

```bash
# v4 顶点对齐：转角处栏板断开
python tools/forge_client.py path fence --path '[[0,0,0],[4,0,0],[4,0,4]]' --spacing 3 --mode continuous --align-vertices --mat wood
# discrete / count 模式加 --align-vertices → client predict_n 预校验报错（与 server validate 同语义）
```

`build_path_payload`：`--align-vertices` → payload `align_vertices: true`（默认不传 = false）。`predict_n` 加 va 分支做段数预校验（>BATCH_LIMIT 提前 exit，不发请求）。

### 2.4 predict_n（forge_client 预校验段数）

va 模式段数 = 每折线段的（整 spacing 段数 + 余数 > _EPS 则 +1 短尾）之和：
```python
def predict_n(points, spacing, count, include_endpoints, mode, align_vertices=False):
    if mode != "continuous" or not align_vertices:
        # v1/v2 既有逻辑不变
        return _predict_n_legacy(...)
    # va 模式
    n = 0
    for i in range(len(points) - 1):
        seg_len = points[i].distance_to(points[i + 1])
        if seg_len < _EPS:
            continue  # 零长折线段贡献 0
        full = int(seg_len // spacing)
        n += full
        if seg_len - full * spacing > _EPS:
            n += 1  # 短尾段
    return n
```

与 server va 分支段数一致（段末去重去掉的是重复边界，不改段数）。

### 2.5 测试矩阵（10 例，test_path_generator.gd 新增）

| # | 场景 | 期望 |
|---|---|---|
| 1 | L 形(各4m) spacing=3 va=true | boundaries `[0,3,4,7,8]` → **4 段**（长 3/1/3/1，转角顶点 4 是边界）|
| 2 | L 形(各4m) spacing=2 va=true | `[0,2,4,6,8]` → 4 段（整除无短尾，验段末去重不产生重复边界）|
| 3 | 单段 3.1m spacing=3 va=true | boundaries `[0,3,3.1]` → 2 段（3 + 短尾 0.1，短尾保留）|
| 4 | count + va=true | validate 返「仅 spacing 模式可用」|
| 5 | discrete + va=true | validate 返「仅 continuous 模式可用」|
| 6 | va=false（默认）| = v2 等间距（现有 test_path_generator.gd continuous 用例覆盖，零回归）|
| 7 | include_endpoints=true + va=true | 静默忽略，boundaries = va 不带 endpoints |
| 8 | 中间零长折线段（共线三点中点重合）+ va | 该顶点不丢（下段 `is_empty()` 补起点），段数正确 |
| 9 | seg_len 整除 spacing（4m/2）+ va | 段末去重生效，无 length≈0 段（最后 boundary=4 不重复）|
| 10 | va + spacing 段数 > BATCH_LIMIT | invalid_params（A7/BATCH_LIMIT 不变量）|

**注记**（次要，spec 提一句不专门测）：va 下极短尾（< _EPS=0.1mm）经段生成 :134 `if length < _EPS: continue` 跳过 → 该顶点对齐了 boundary 但无 mesh 段。工程可忽略（<0.1mm 栏板段本就无意义）；用户用 spacing 接近折线段整数倍可避免短尾。

#1-3 验 va 切分算法 + 短尾，#4-5 验不兼容报错，#6 零回归，#7 验 include_endpoints 静默忽略，#8-9 验边缘（零长段 / 整除去重），#10 验不变量。

### 2.6 pytest（forge_client predict_n va 分支）

- `predict_n` va=true L 形 spacing=3 → 4（与 server #1 一致）
- `predict_n` va=true 整除（spacing=2）→ 4
- `predict_n` va=false → 走 legacy（v1/v2 用例覆盖，零回归）

## 实施顺序提示（详细计划由 writing-plans 出）

1. `path_generator.gd`：validate + sample + `_sample_continuous` 加 `align_vertices` + va 分支（含段末去重 + is_empty 守卫）→ test_path_generator.gd 10 例（TDD：先写测试见失败，再实现）
2. `tools/forge_client.py`：`--align-vertices` + `build_path_payload` + `predict_n` va 分支 → pytest 3 例
3. `asset_forge_plugin.gd`：`_handle_generate_path` 透传 `payload.get("align_vertices", false)`（1 行，复用 v3 入口）
4. 文档（protocol.md align_vertices 字段 + README 示例 + 极短尾注记）+ selftest va 集成（discrete/count+va 报错 + continuous va 生成）

## 不变量（零回归护城河）

- discrete 路径不碰；v2 continuous `align_vertices=false` 字节级不变（179 headless 不回归）
- BATCH_LIMIT 仍护段数（短尾增段，超限仍 invalid_params）
- A7 samples 空守卫（v3）仍生效
- v3 result total 字段仍带（va 段数 = total）
