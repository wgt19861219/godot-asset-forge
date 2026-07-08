# 架构

## 组件职责

| 文件 | 职责 |
|------|------|
| `asset_forge_plugin.gd` | EditorPlugin 入口：装配 dock+server+Orchestrator、`_on_command` 透传 Orchestrator、EditorInterface/UI 包装（`_get_root`/`_mark_unsaved`/`_dock_add`）、`_undo_stack` clear 责任 |
| `orchestrator.gd` | 编排层（claim 5）：`handle_command`/`_handle_generate_path`/`_place_one`，零 EditorInterface 依赖（Callable 注入，可 headless 测，22 case） |
| `command_server.gd` | WebSocket 服务器（bind 127.0.0.1）+ 协议常量 + handshake token 鉴权 |
| `asset_factory.gd` | `create_mesh(shape, params)` 分发 + 内置 PrimitiveMesh + `create_material` |
| `custom_meshes.gd` | 5 手写 ArrayMesh（cone/tube/torus/stairs/fence，SurfaceTool） |
| `material_library.gd` | 10 预设 StandardMaterial3D |
| `scene_placer.gd` | `place()`（name 碰撞/parent/save `.tscn`/owner）+ `undo_last()` |
| `forge_dock.gd` | Dock UI（端口/连接/token/清单/日志/启停） |
| `log_helper.gd` | 单例日志（带时间戳 + 信号广播） |
| `localization.gd` | 9 语言框架 |

## 数据流

生成路径**全同步、零 IO、零后台线程**：`PrimitiveMesh`/`SurfaceTool` 造 mesh → `add_child` → 可选 `ResourceSaver.save(.tscn)`。主线程一帧内完成，故无需 `Thread` 链路。

```
bash → forge_client → WS → command_server.poll → _handle_text
  → emit command_received(payload, batch_id)
  → plugin._on_command → Orchestrator.handle_command
    → AssetFactory.create_mesh + create_material
    → ScenePlacer.place（add_child, owner=root, undo_stack 入栈, 可选 save .tscn）
  → server.send_result ─WS→ bash 拿 node_path
  → forge_dock.add_to_generated_list（视口实时可见）
```

## undo 语义

- `undo_last` 仅 `queue_free` 场景节点，**绝不删** `res://GeneratedAssets/*.tscn`（避免误删用户后续手动 instance 的复用资产）
- registry = `asset_forge_plugin._undo_stack: Array[Dictionary]`（每条 `{node, parent, batch_id, saved_path}`），`_exit_tree` 清空 → **不跨编辑器会话**
- `generate_batch` 原子一条 undo：同 `batch_id` 的所有条目一次弹出 free

## 编排层（`Orchestrator.handle_command`，claim 5 从 plugin 迁出）

- undo 分支（`batch_id == -1`, `payload.__undo == true`）→ `ScenePlacer.undo_last(_undo_stack)` + `send_result`
- generate 分支（`batch_id > 0`）→ `AssetFactory.create_mesh` + `create_material` + `ScenePlacer.place(..., _undo_stack, batch_id)` + `send_result` + Dock 清单更新
- generate_path 分支（`payload` 含 `path`/`path_node`）→ `PathGenerator` 采样 + 段循环 `_place_one`（discrete/continuous）
- 无活动场景 → 返 `no_active_scene` error（不自动建场景，客户端引导用户先 New Scene）
- plugin.`_on_command` 现 1 行透传 `_orch.handle_command`；EditorInterface 副作用（`get_edited_scene_root`/`mark_scene_as_unsaved`）经 Callable 注入 → Orchestrator 零 EditorInterface 依赖，22 case headless 测（`tests/test_orchestrator.gd`）

## `_resolve_parent` 双向兼容

`ScenePlacer._resolve_parent(root, parent_path)`：
- 空 → root
- 绝对路径 `/Name/Xxx`：首段等于 `root.name` 则剥（`root.get_node_or_null("Xxx")`）；不剥则按完整路径从 root 找（`root.get_node_or_null("Name/Xxx")`）→ 双向兼容，客户端发 `/<root.name>/...` 或相对路径均可
