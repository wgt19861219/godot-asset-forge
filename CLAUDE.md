# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目

Asset Forge —— Godot 4.6（Forward+）EditorPlugin：bash 一行命令经 WebSocket 把参数化 3D shape 节点实时生成到编辑器视口。Fork 自 Tripo3D Godot Bridge。本仓库既是插件源码，也是一个让插件能加载、测试能跑的 minimal Godot 壳（见 `project.godot` 注释）。实际分发时只需把 `addons/asset_forge/` 复制进目标 Godot 项目。详见 `README.md` 与 `docs/`。

## 常用命令

```bash
# 跑全部测试（4 suite，headless，无需打开编辑器）
godot --headless --path . --script res://tests/test_runner.gd

# 11 种 shape + undo 的活体自检（需先在 Godot 编辑器启用插件、打开一个场景）
python tools/forge_client.py --selftest

# 客户端依赖
pip install websockets
```

跑单个 suite：`tests/test_runner.gd::_initialize` 硬编码注册全部 4 个 suite，**没有** CLI 过滤参数。要隔离某 suite，临时注释 `_initialize` 里其它三行 `_run_suite(...)`。单个 `runner.check` 失败不会中断 suite（跑完再汇总），有失败则进程 exit code = 1。

## 架构（跨文件大图）

生成路径**全同步、单帧、零后台线程、零文件 IO**（仅 `save=true` 时写一次 `.tscn`）：

```
bash → tools/forge_client.py ──WS──> command_server.poll → _handle_text
  → emit command_received(payload, batch_id)
  → asset_forge_plugin._on_command
    → AssetFactory.create_mesh(shape, params)        # 调度：6 PrimitiveMesh + 5 手写
    → AssetFactory.create_material(material spec)    # 预设名 / dict / res://.tres
    → ScenePlacer.place(root, mesh, mat, ..., _undo_stack, batch_id)
  → server.send_result ──WS──> bash 拿 node_path
  → forge_dock.add_to_generated_list                # 视口实时出现节点
```

组件分层（全在 `addons/asset_forge/`，扁平 10 文件）：
- `asset_forge_plugin.gd` —— EditorPlugin 入口：装配 dock+server、`_process` 里调 `server.poll()`、`_on_command` 编排、**`_undo_stack` 的唯一持有者**。
- `command_server.gd` —— WS 服务器（`bind 127.0.0.1:60650`）+ 协议常量 + handshake token 鉴权 + 消息分发。
- `asset_factory.gd` / `custom_meshes.gd` / `material_library.gd` —— 纯静态调度层（mesh 分发、手写 ArrayMesh、10 预设材质）。
- `scene_placer.gd` —— `place` / `undo_last` / 存 `.tscn`，纯静态。
- `forge_dock.gd` —— Dock UI；`log_helper.gd` —— 单例日志（静态方法 + 信号广播）。

### 必须守住的语义不变量

改这几处前先读这几条。代码注释用 `IMPORTANT-N` / `Q-N` / `A-N` 标记对应设计 spec 条款，修改时保留：

1. **undo 绝不删 `res://GeneratedAssets/*.tscn`** —— `ScenePlacer.undo_last` 只 `queue_free` 场景节点；`.tscn` 是用户可复用的 PackedScene 资产。`tests/test_scene_placer.gd` 显式断言「undo 后文件仍在」。
2. **undo 不跨编辑器会话** —— registry = `asset_forge_plugin._undo_stack: Array`，`_exit_tree` 清空。重启编辑器 = undo 历史清零。
3. **batch 原子 undo** —— 同一 `batch_id` 的所有条目在一次 `undo_last` 里一起弹。单个 `generate` 也是 batch=1。`undo_last` 从栈顶取 `batch_id`，弹到遇到不同 `batch_id` 为止。
4. **batch per-item 散回执** —— `generate_batch` 对每个 item 各发一条独立 `generate_result`，共享同一个 `req_id`（**不**返单条 `results[]` 聚合体）。客户端按 `id` 收齐 N 条再自己聚合。`BATCH_LIMIT = 64`，超限返 `invalid_params`。
5. **无活动场景 → `no_active_scene` error**，不自动建场景（`EditorInterface` 无 `set_edited_scene` API；客户端引导用户先 New Scene）。
6. **`_resolve_parent` 双向兼容但不建中间节点** —— 绝对路径 `/Root/Decor`（首段等于 root.name 会剥掉）与相对路径都吃；路径无效 → `parent_not_found`，**不**自动造父节点。
7. **`stairs` / `fence` 烘焙成单 ArrayMesh（单 surface）** —— 多部件必须进同一个 `SurfaceTool` 再 `commit()`，避免「多 mesh 取首偏置」老 bug（A3）。

## 关键约定

- **全 `@tool`**：每个 .gd 顶格 `@tool`（编辑器内运行）。注意 `EditorInterface.get_edited_scene_root()` 在无打开场景时返 `null`，分支要处理。
- **没有 autoload；静态类靠 `class_name` 全局注册**：`AssetFactory` / `CustomMeshes` / `MaterialLibrary` / `ScenePlacer` / `LogHelper` / `AssetForgeServer` 都是 `class_name X extends RefCounted`，直接 `X.foo()` 调用，**不**需要 preload，`project.godot` 也无 autoload 段。`LogHelper` 内部用 `static var _instance` 持单例。唯一例外是插件入口 `asset_forge_plugin.gd`（EditorPlugin，由 `plugin.cfg` 指向）。
- **缩进 = Tab**（GDScript 默认）；注释一律简体中文；新增/修改时保留注释里的 `IMPORTANT-N` / `Q-N` / `A-N` 标记。
- **向量协议**：JSON 里向量统一 `[x,y,z]` 数组，由各文件本地 `_vec3()` helper 解析（同时兼容 `Array` 与 `PackedFloat64Array`）。
- **材质 spec 三态 + null**：`String` 预设名（未知回退 `default`）/ `Dictionary` 自定义 PBR（`color` 用 hex 如 `"FF0000"` 或 `"#FF0000"`，`alpha<1` 自动开透明）/ `"res://..."` 外部 `.tres` / `null` → default。
- **新增 shape 的完整触点**（shape 名必须逐字一致）：`asset_factory.gd::create_mesh` 的 match（内置）或 `custom_meshes.gd::make_xxx`（手写）→ `tools/forge_client.py::SHAPES_11` → `docs/shapes-reference.md` → `README.md` 形状表 → `tests/test_asset_factory.gd` / `tests/test_custom_meshes.gd`。

## 协议 & 鉴权速查

JSON over WebSocket，`ws://127.0.0.1:60650`（仅本机）。消息类型：`handshake` / `handshake_ack` / `ping` / `pong` / `generate` / `generate_batch` / `generate_result` / `undo_last`。错误码：`unsupported_shape` / `invalid_params` / `parent_not_found` / `no_active_scene` / `unauthorized` / `nothing_to_undo`。完整字段、回执形状、batch 上限语义见 `docs/protocol.md`。

token：插件启动时生成 32 字节随机 hex 写到 `user://asset_forge.token`。客户端按优先级定位该文件：`--godot-user-dir` 参数 > `GODOT_USER_DIR` 环境变量 > `%APPDATA%\Godot\app_userdata\<config/name>\`（`<config/name>` 取自 `project.godot`，本仓库为 `godot-asset-forge`）。token 不符 → `unauthorized` + 断连。
