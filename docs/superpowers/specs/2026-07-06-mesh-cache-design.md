# v7 mesh 缓存 设计

> **状态**：已定方案（通用 create_mesh 缓存 + benchmark 验证）
> **基线**：v6 完结（master 1671b40，247 headless + 17 pytest + selftest 全 green）
> **动机**：用户报告 continuous 大量段（N 接近 BATCH_LIMIT 64）生成慢。mesh 缓存对 continuous fence count（中间 N-1 段 mesh 相同）+ wall count + 单件重复对症
> **设计审查**：独立 reviewer 核实三个命门（§1 hash key 顺序敏感+碰撞 / §3 不清理 trade-off / §4 benchmark 两层），本 spec 据此修订

---

## 目标

`AssetFactory.create_mesh` 缓存：相同 (shape, params) 返同一 Mesh 资源，避免重复创建（尤其 `make_fence` SurfaceTool 360 顶点重操作）+ GPU vertex buffer 自动复用（MeshInstance3D 共享 Mesh 资源）。

## 背景

- `AssetFactory.create_mesh(shape, params)` 当前每次 `new` 一个新 Mesh（PrimitiveMesh 或 CustomMeshes.make_xxx 手写 ArrayMesh），相同 (shape, params) 不复用
- discrete 模式已复用 `probe_mesh`（`asset_forge_plugin.gd:252`，所有离散点共享一个 mesh）—— 无需缓存
- continuous 模式每段独立 `create_mesh`（`:289-314`）

### 命中/不命中场景（已核对）

- **命中**：
  - continuous fence count：中间 N-1 段 `start_post=true, end_post=false`（段 0..N-2）+ length 相同（count 模式 step=total/N）→ mesh 相同，命中 N-1 次（`make_fence` 重，显著省）。段 N-1 `end_post=true` 不同 → miss
  - continuous wall count：N 段 mesh 相同（length 同 + 无段特定参数）→ 命中 N 次（BoxMesh 轻，省微）
  - 单件 generate 重复 shape+params → 命中
- **不命中**（v5/v6 设计本质要求各段几何唯一，无法缓存）：
  - continuous fence spacing/va：段长不同 → mesh 不同
  - continuous ramp：v6 各段 start_height/end_height 不同 → mesh 不同

## 设计

### 设计点 1：规范化 params 字符串 key（顺序无关 + 零碰撞，reviewer §1 修订）

**不用 `Dictionary.hash()`**（两个 correctness 坑）：
- (a) **顺序敏感**（官方确认 godot-proposals #9452）：`Dictionary.hash()` 依赖插入顺序，同内容不同顺序 → 不同 hash。当前 placement 层 `seg_params = base_params.duplicate()` 后按固定顺序加键（length → start_post → end_post）能命中，但 refactor 改顺序 / batch 不同 item JSON 字段顺序不同 → 静默漏命中（退化无缓存，难排查）
- (b) **hash 碰撞 → 静默返错误 mesh**：32 位 int 碰撞概率虽低（< 万分之一），但碰撞后果是返错误 mesh 持续静默——不可接受

**改用规范化 params 字符串 key**（排序 key + 递归嵌套），顺序无关 + 零碰撞（完整内容，非 hash）：

```gdscript
# 顺序无关（Dictionary key 排序）+ 零碰撞（完整内容序列化，非 hash）
static func _params_key(params: Dictionary) -> String:
	var keys: Array = params.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append(str(k) + ":" + _variant_key(params[k]))
	return "{" + ",".join(parts) + "}"

static func _variant_key(v: Variant) -> String:
	if v is Dictionary:
		return _params_key(v)  # 嵌套 dict 递归 + 排序
	if v is Array:
		var parts: PackedStringArray = []
		for x in (v as Array):
			parts.append(_variant_key(x))  # 数组有序（正确，数组本有序）
		return "[" + ",".join(parts) + "]"
	if v is PackedFloat64Array:  # _vec3 兼容（asset_factory.gd:114）
		var parts: PackedStringArray = []
		for x in (v as PackedFloat64Array):
			parts.append(str(x))
		return "[" + ",".join(parts) + "]"
	return str(v)
```

cache key = `shape.to_lower() + "|" + _params_key(params)`。

**代价**：params 小（几十字段），构造 key 远快于重建 fence（360 顶点 SurfaceTool）。浮点 `str()` 同值同串（int 3 与 float 3.0 都 "3" → 命中且几何同，正确）；位同的 `duplicate()` → 同串 → 命中。

### 设计点 2：create_mesh 缓存逻辑

`AssetFactory` 加 `static var _cache: Dictionary = {}`，`create_mesh` 入口查缓存：

```gdscript
static func create_mesh(shape: String, params: Dictionary) -> Mesh:
	var key: String = shape.to_lower() + "|" + _params_key(params)
	if _cache.has(key):
		return _cache[key]  # 命中返同一 Mesh 资源
	# 未命中：既有 match 分支创建 mesh
	var mesh: Mesh = _create_mesh_uncached(shape, params)
	if mesh != null:
		_cache[key] = mesh
	return mesh
```

既有 `match shape.to_lower()` 创建逻辑提取到 `_create_mesh_uncached(shape, params)`（原 create_mesh body，不改逻辑，只改名）。null（未知 shape）不缓存。

### 设计点 3：缓存语义 + trade-off（reviewer §3 显式声明）

- **返同一 Mesh 资源**（identity 相等）：多个 MeshInstance3D 引用同一 Mesh → Godot GPU vertex buffer 自动复用（标准资源共用模式）
- `material_override` 各 MI3D 独立（`scene_placer.gd:26` 设，不冲突）
- **下游无 mesh mutation**（已 grep 核实）：`scene_placer.gd:25` `mi.mesh = mesh`（赋值）+ `create_material` 单独建 material → 无 `surface_set`/`add_surface`/`mesh.xxx` 修改 → 缓存共享安全
- **ramp 分流自动隔离**：v6 ramp 手写 wedge（含 start_height/end_height）vs PrismMesh（不含）params 不同 → 不同 `_params_key` → 自动隔离，cache key 含完整 params 已覆盖

**trade-off（显式声明，非疏忽）**：
- `static var _cache` 持 Mesh 引用 → 即使场景删了对应 MeshInstance3D，mesh 永不释放（cache 持引用）
- **长期编辑器 session 内存只增不减**。量级：fence ~10KB/个 × 几百不同 params ~几 MB，可接受；编辑器重启清空
- `@tool` 脚本热重载偶发清空 cache（无害，重新填充）

YAGNI 不加 LRU 上限（mesh 数可控，简单优先）。如果未来内存问题再加。

### 设计点 4：测试 + benchmark 两层（reviewer §4）

**单测**（`tests/test_asset_factory.gd` 追加）：
- 相同 params 返同一 Mesh（`is_same(create_mesh("fence", p), create_mesh("fence", p.duplicate())) == true`——`is_same()` 显式身份比较，reviewer 增量建议）
- 不同 params 返不同 Mesh（`is_same(create_mesh("fence", {length:3}), create_mesh("fence", {length:4})) == false`）
- 顺序无关（`{a:1,b:2}` vs `{b:2,a:1}` → `is_same == true`，验证 `_params_key` 排序）
- 未知 shape 不缓存（`create_mesh("pyramid", {}) == null`，不污染 cache）
- v6 ramp 分流隔离（`create_mesh("ramp", {start_height:0.5})` ArrayMesh vs `create_mesh("ramp", {})` PrismMesh 不互染）

**benchmark 两层**（plan 阶段定具体方式，headless 可测 create_mesh 直接）：
1. **占比层**：continuous fence count N=64，profile generate_path 总时间中 create_mesh 占比（若 <10%，优化它收益甚微——瓶颈在 ScenePlacer/node 创建/WS，mesh 缓存是"感觉快了"的安慰剂）
2. **收益层**：缓存前后 `create_mesh("fence", same_params)` N 次总时间对比（验证命中收益数值）

占比层确认 create_mesh 是瓶颈，收益层验证缓存效果。两层都做（CLAUDE.md 目标驱动 + verification，不凭假设优化）。

### 设计点 5：文档

`README.md` 性能段加 1 句"重复 shape / continuous count 模式自动缓存 mesh 资源（相同 params 共享，GPU vertex buffer 复用）"。

## 范围边界（YAGNI）

**v7 做**：
- `_params_key` + `_variant_key` 规范化 key（顺序无关 + 零碰撞）
- `create_mesh` 缓存（static var _cache + 查存）
- 既有创建逻辑提取 `_create_mesh_uncached`
- 单测（is_same 身份 + 顺序无关 + 不缓存 null + ramp 隔离）
- benchmark 两层（占比 + 收益）
- README 1 句

**v7 不做**：
- LRU 上限（YAGNI，mesh 数可控）
- _exit_tree 清理 cache（YAGNI，重启清空足够）
- 跨编辑器 session 持久化（YAGNI）

## 不变量（修改时保留）

1. **create_mesh 返回语义不变**——相同输入返 Mesh（缓存后返同一资源，但调用方无感知，`mi.mesh = mesh` 仍正确）
2. **未知 shape 返 null 不缓存**（避免 null 污染 cache）
3. **缓存 Mesh 不被下游 mutation**（已 grep 核实，scene_placer 只赋值 + material_override 独立）
4. **`_params_key` 顺序无关 + 零碰撞**（排序 + 完整内容序列化，非 hash）

## 触点（完整清单）

- `addons/asset_forge/asset_factory.gd`：新增 `_params_key` + `_variant_key` + `static var _cache` + create_mesh 缓存逻辑 + 既有 body 提取 `_create_mesh_uncached`
- `tests/test_asset_factory.gd`：缓存单测（is_same + 顺序无关 + null + ramp 隔离）
- benchmark（plan 阶段定：headless test 或 编辑器 timing print）
- `README.md`：性能段 1 句
