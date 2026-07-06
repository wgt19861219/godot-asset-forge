# v5 fence 端柱去重 + continuous 扩 ramp 设计

> **状态**：已定范围（fence 端柱去重为主 + continuous 扩 ramp 仅白名单；ramp 接缝高度台阶留后续）
> **基线**：v4 完结（master 3a20ba0，201 headless + 17 pytest + selftest 全 green）
> **范围性质**：minimal-diff，零单件/discrete 回归，与 v4 va 正交

---

## 目标

1. **解 continuous 模式 fence 相邻段端柱重叠 z-fighting**（v2 起老问题；v4 va 让段边界对齐折线顶点，转角处端柱精确重叠 → 更明显）
2. **顺带扩 continuous 白名单到 ramp**（PrismMesh，`size.x = length` 已能生效，纯白名单改动）

## 背景

### fence continuous 现状（v4 完结后）

- 放置层 `asset_forge_plugin.gd::_handle_generate_path` continuous 分支（`:289-308`）：每段独立 `AssetFactory.create_mesh(shape, seg_params)`，`seg_params["length"] = seg["length"]`。
- `CustomMeshes.make_fence`（`addons/asset_forge/custom_meshes.gd:136-153`）：柱子均匀分布在 `[-length/2, +length/2]`，`t = i/(posts-1)`。首柱 `t=0`（本地 `x=-length/2` = 段起点），末柱 `t=1`（本地 `x=+length/2` = 段末端）。posts 默认 4。
- 段放置：`position = p_start.lerp(p_end, 0.5)`（段中点），rotation 让本地 +X 对齐 chord（`path_generator.gd::_sample_continuous :164-166`）。
- **相邻段在世界坐标首尾相接**（段 i 末端 = 段 i+1 起点；spacing / va / count 三种 boundaries 模式都成立——boundaries 都是相邻边界对）→ **段 i 末柱与段 i+1 首柱世界坐标精确重合 → 双柱 z-fighting**。
- 横档（`_add_box`，`custom_meshes.gd:149-150`）`length` = 段长，贯穿 `[-length/2, +length/2]`，相邻段横档端点世界坐标**相接不重叠** → 横档无 z-fighting（问题仅限柱子）。
- v4 va：段边界对齐折线顶点，转角处段端点更精确对接 → 端柱重叠更明显（va 本身正确，但放大了 z-fighting）。

### continuous 白名单现状

- `asset_forge_plugin.gd:240`：`if mode == "continuous" and shape != "wall" and shape != "fence":` → 仅 wall/fence。
- ramp（`asset_factory.gd:40-48`，PrismMesh，`size.x = params["length"]`）：continuous 注入 `seg_params["length"]` 已能让 size.x 自适应段长，但被白名单挡住。

## 设计

### 设计点 1：提取 `_post_xs` 纯函数 + make_fence 加 start_post/end_post

**为何提取纯函数**：`make_fence` 把柱+横档烘焙成单 ArrayMesh（CLAUDE.md 不变量 7 / A3）。直接数 mesh 顶点断言柱数会依赖内部常数 `seg=12`（每柱 72 顶点），脆弱。提取柱位置计算为纯函数 `_post_xs`，单测纯函数返回的 x 数组——干净、不依赖 mesh 实现细节，符合「为隔离与清晰而设计」。

**`_post_xs(length, posts, start_post, end_post) -> Array`**（`custom_meshes.gd` 新增私有静态）：

```gdscript
# fence 柱 x 坐标列表（纯函数，可单测）。
# posts = 满配柱数；start_post/end_post=false 时跳过首/末柱。
# 剩余柱仍按 t=i/(posts-1) 取（跳过端点索引，柱间距不变）。
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

**`make_fence` 改造**（`custom_meshes.gd:136-153`，循环替换为调 `_post_xs`）：

```gdscript
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
	return st.commit()
```

**关键性质**：
- `start_post`/`end_post` 默认 `true` → params 不含时行为与现状字节一致（零回归保证）。
- posts 仍是「满配柱数」语义；跳过端柱后剩余柱按原 `t=i/(posts-1)` 分布 → **段内**柱间距 `= length/(posts-1)` 一致。段间柱间距仅在段长相等时一致；va 模式（折线各段长不等，`path_generator.gd:126-139` 按顶点切分）或段长不等时段间柱间距会不同。v5 只保证端柱不重叠（消 z-fighting），**不保证跨段等间距**。
- 横档不受 start/end_post 影响（仍贯穿 `[-length/2, +length/2]`，相邻段横档端面**共面贴合但无体积重叠** → 无 z-fighting；与柱子「圆柱体积完全重叠 → z-fighting」区别在此，故只需去柱）。

### 设计点 2：continuous 端柱共享规则（放置层注入）

放置层 `_handle_generate_path` continuous 分支按段索引注入 `seg_params`：

- **所有段 `start_post=true`**（首柱落在段起点 = 与前段接缝处）
- **仅末段 `end_post=true`**（末柱 = 路径终点柱）
- **其他段 `end_post=false`**（去末柱，避免与下段首柱重合）

**效果**：路径起点 1 柱（段 0 首柱）→ 每个接缝 1 柱（段 i 首柱，段 i-1 末柱已去）→ 路径终点 1 柱（段 N-1 末柱）。每个位置正好一根，零 z-fighting。

**`asset_forge_plugin.gd::_handle_generate_path` continuous 分支改造**（`:289-308`）：

```gdscript
else:  # continuous：每段独立 create_mesh（length + fence 端柱注入）
	var seg_count: int = samples.size()
	for i in seg_count:
		var seg: Dictionary = samples[i]
		var seg_params: Dictionary = base_params.duplicate()
		seg_params["length"] = seg["length"]
		if shape == "fence":
			# 端柱共享：所有段保首柱（=接缝柱），仅末段保末柱（=终点柱），
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

**仅 fence 注入**（wall/ramp 无柱）。discrete 分支（`:272-288`）不进此分支 → 零回归。

### 设计点 3：discrete / 单件 generate 零回归

- **单件 generate fence**（`asset_forge_plugin.gd:88`，走 `_on_command` 非 path 分支）：params 不含 start/end_post → `make_fence` 默认 true → 现状不变。
- **discrete 模式 fence**（`_handle_generate_path :272-288`）：不进 continuous 分支，不注入 → 默认 true → 现状不变。discrete 每个采样点是独立 fence 物件、物件间有间距、端柱本就不重叠。
- **现有 `make_fence` 调用方**（`test_custom_meshes.gd` 单件用例 / selftest 11 shape）：params 不含 start/end_post → 默认 true → 现状不变。

### 设计点 4：continuous 扩 ramp（仅白名单）

`asset_forge_plugin.gd:240` 白名单加 ramp：

```gdscript
if mode == "continuous" and shape != "wall" and shape != "fence" and shape != "ramp":
```

同步改同分支错误消息（`asset_forge_plugin.gd:247`）：`"continuous 模式仅支持 wall/fence（length 沿 X），当前 "` → `"continuous 模式仅支持 wall/fence/ramp（length 沿 X），当前 "`（加 ramp 后白名单实际为 wall/fence/ramp，否则 box/stairs 等触发该分支时消息与白名单不符，误导排错）。

ramp（PrismMesh，`asset_factory.gd:40-48`）`size.x = params["length"]`，continuous 注入 `seg_params["length"]` 已能让 size.x 自适应段长 → **零 mesh 改造**。box 跳过：box 读 `size` key 不读 `length`（`asset_factory.gd:10-13` `m.size = _vec3(params, "size", ...)`），continuous 注入对 box 不生效；且 wall 已是「box 沿 X」语义（`asset_factory.gd:32-39`），无新增价值。

**已知局限（不在 v5 解）**：PrismMesh 斜面在 Y 方向（高度 0→height），每段独立 → 相邻段接缝处高度台阶。v5 只让 ramp「能放」，高度衔接（需 ramp 加 start_height/end_height + 改用 CustomMeshes 手写，PrismMesh 不支持端点高度）留作 ramp 专项 / v6。

## 测试矩阵

### headless 单测（`tests/test_custom_meshes.gd` 新增 `_post_xs` 用例）

纯函数单测，不依赖 mesh 实现细节。length=3.0、posts=4 时 t={0, 1/3, 2/3, 1}，x=(t-0.5)*3 = {-1.5, -0.5, 0.5, 1.5}：

| # | 输入 (length, posts, start, end) | 期望 x 列表 | 说明 |
|---|---|---|---|
| 1 | (3.0, 4, true, true) | [-1.5, -0.5, 0.5, 1.5] | 默认满配（零回归） |
| 2 | (3.0, 4, true, false) | [-1.5, -0.5, 0.5] | 去末柱（continuous 非末段） |
| 3 | (3.0, 4, false, true) | [-0.5, 0.5, 1.5] | 去首柱 |
| 4 | (3.0, 4, false, false) | [-0.5, 0.5] | 去首末 |
| 5 | (3.0, 1, true, true) | [-1.5] | posts=1 走 t=0.0 特例 → x=-length/2（左端，**make_fence 既有行为**，v5 保留） |
| 6 | (3.0, 1, false, false) | [] | posts=1 + 全去：i=0 同为首位被 skip → 空列表（不崩） |
| 7 | (3.0, 2, true, true) | [-1.5, 1.5] | posts=2 两端柱 |
| 8 | (3.0, 2, true, false) | [-1.5] | posts=2 去末 |
| 9 | (3.0, 0, true, true) | [] | posts<1：`for i in 0` 不执行 → 空列表（不崩，纯函数信任上层 `make_fence :139 max(posts,1)`） |

### make_fence 既有用例（零回归断言）

`test_custom_meshes.gd` 现有 make_fence 用例（默认 params）保持不变，断言仍 pass（默认 start=end=true → 顶点数/形状与 v4 一致）。

### plugin 层（continuous 段注入 + ramp 白名单）

`_handle_generate_path` 是 EditorPlugin 逻辑，headless `--script` 不加载 EditorInterface → 走 **selftest 端到端 + code review**（v4 验证过的模式：headless 测纯几何，plugin 编排靠 selftest + 审查）。注入逻辑仅两行（`start_post=true` + `end_post=(i==last)`），trivial，code review 把关。

### selftest 新增（`tools/forge_client.py::run_selftest`）

- **continuous fence 端柱去重**：count 模式（N 确定、无歧义，与 `forge_client.py:406-425` 现有 continuous wall selftest 对称，最小 diff）。payload：`shape=fence, path=[[0,0,0],[3,0,0],[3,0,3]], count=3, mode=continuous` → 断言 `send_and_recv_batch` 收 3 条 result 且全 success；undo 断言 `freed==3`。z-fighting 消除属视觉验证（编辑器手测确认）；selftest 只验证生成/undo 链路通 + 段数对（**柱数/柱位置无自动断言 = 已知测试盲区**，headless 数柱要依赖 seg=12 内部常数，靠 code review + 手测兜底）。
- **continuous ramp**：count 模式，直线避开 va 转角。payload：`shape=ramp, path=[[0,0,0],[3,0,0]], count=3, mode=continuous` → 断言 3 条 result + undo `freed==3`（验证白名单放行 + 链路通）。

### 客户端 `predict_n`

**无改动**。`predict_n` 是通用算法（按 spacing/count 算段数，与 shape 无关）；段数预测与端柱无关。

## 文档

- **`docs/protocol.md`**：continuous 白名单 `wall/fence` → `wall/fence/ramp`；加 fence 端柱去重注记（continuous 自动注入 start_post/end_post，discrete/单件不注入）。
- **`README.md`**：continuous 模式说明更新白名单；特性栏加 fence 端柱去重。
- **`docs/shapes-reference.md`**：fence 加 `start_post`/`end_post` 参数说明；ramp 加 continuous 注记（含已知局限：接缝高度台阶，留后续）。
- **`tools/forge_client.py`**：**无代码改动**（白名单是服务端单方面；`--align-vertices` 等 flag 不涉及）。

## 范围边界（YAGNI）

**v5 做**：
- `_post_xs` 纯函数 + `make_fence` 加 start_post/end_post（默认 true）
- continuous 放置层 fence 端柱注入（所有段首柱 + 末段末柱）
- continuous 白名单扩 ramp
- 9 例 `_post_xs` 单测（含 posts=0 边界）+ 2 条 selftest

**v5 不做**（留后续）：
- ramp continuous 接缝高度衔接（需手写 ramp mesh + start_height/end_height）
- mesh 缓存（收益场景窄，YAGNI）
- box continuous（wall 已覆盖）
- `_post_xs` 的 posts<1 拦截（make_fence `:139` 已 `max(posts, 1)`，纯函数信任上层）

## 不变量（修改时保留）

1. **make_fence 仍烘焙单 ArrayMesh（单 surface）**——CLAUDE.md 不变量 7（A3）。start/end_post 只控制柱循环，横档仍进同一个 SurfaceTool 再 commit()。
2. **单件/discrete 字节级零回归**——start/end_post 默认 true，params 不含时 make_fence 行为不变。
3. **continuous 端柱共享仅 fence 注入**——wall/ramp 无柱，seg_params 不加 start/end_post。
4. **`_post_xs` 是纯函数**——无副作用，不碰 SurfaceTool，可独立 headless 单测。

## 触点（新增 start_post/end_post 的完整清单）

- `addons/asset_forge/custom_meshes.gd`：新增 `_post_xs` + 改造 `make_fence` 循环
- `addons/asset_forge/asset_forge_plugin.gd:240`：白名单加 ramp（`and shape != "ramp"`）
- `addons/asset_forge/asset_forge_plugin.gd:247`：白名单错误消息 `wall/fence` → `wall/fence/ramp`（与 :240 同分支，加 ramp 后必须同步）
- `addons/asset_forge/asset_forge_plugin.gd:289-308`：continuous 分支 fence 端柱注入
- `tests/test_custom_meshes.gd`：9 例 `_post_xs` 单测（含 posts=0 边界）
- `tools/forge_client.py::run_selftest`：2 条 continuous（fence 端柱 + ramp）
- `docs/protocol.md` / `README.md` / `docs/shapes-reference.md`：白名单 + 端柱注记
