# Asset Forge

> bash 驱动的 Godot 资产生成插件：通过 WebSocket 指令在 Godot 编辑器内实时生成 11 种参数化 3D shape 节点。

把"在编辑器里手摆基础几何体"这件事变成 bash 一行命令。配合脚本可批量铺设场景骨架（墙、台阶、栅栏、管道、装饰物），省去逐个手摆。适用于 Godot 4.6（Forward+）。

## 特性

- **11 种 shape**：6 内置 PrimitiveMesh（box / cylinder / sphere / prism / wall / ramp）+ 5 手写 ArrayMesh（cone / tube / torus / stairs / fence）
- **10 个预设材质**（自然/水族主题）+ 自定义 PBR dict + 外部 `.tres` 引用
- **场景内放置**：parent / transform / name 碰撞自增 `_001`
- **批量生成** + **undo**（batch 原子一条 undo）+ **save `.tscn` 预制件**（PackedScene，可复用 instance）
- **本地安全**：bind `127.0.0.1` + handshake token 鉴权
- **EditorPlugin `@tool`**：编辑器视口实时可见，零文件 IO、零后台线程

## 架构

```
bash: python tools/forge_client.py box --size 2 1.5 1.2 --mat wood --name crate_01
  └─WS→ command_server.poll → _handle_text(type=generate)
        └─ emit command_received(payload, batch_id)
             └─ asset_forge_plugin._on_command:
                  mesh = AssetFactory.create_mesh(...)
                  mat  = AssetFactory.create_material("wood")
                  res  = ScenePlacer.place(mesh, mat, ...)
                  server.send_result(res) ─WS→ bash 拿到 node_path
                  forge_dock.add_to_generated_list(...)  # 编辑器视口实时出现木箱
```

详见 [docs/architecture.md](docs/architecture.md)。

## 安装

1. 复制 `addons/asset_forge/` 到你的 Godot 4.6 项目 `addons/` 下
2. 编辑器 → 项目 → 项目设置 → 插件，启用 "Asset Forge"
3. 编辑器右侧 Dock 出现 Asset Forge（端口 60650 / 监听中 / token 路径）
4. 客户端依赖：`pip install websockets`

## 快速开始

```bash
# 单个生成
python tools/forge_client.py box --size 2 1.5 1.2 --mat wood --name crate_01 --pos 0 0 0

# 11 种 shape 自检
python tools/forge_client.py --selftest

# 撤销最后一条（batch 原子）
python tools/forge_client.py undo

# 批量（位置参数，每项 {"shape": <name>}）
python tools/forge_client.py batch box cylinder cone --name a b c

# 批量（JSON items）
python tools/forge_client.py batch --items '[{"shape":"box","name":"a"},{"shape":"cone"}]'

# 存为 .tscn 预制件
python tools/forge_client.py box --save --name pillar

# 自定义材质
python tools/forge_client.py box --mat '{"color":"FF0000","metallic":0.5,"roughness":0.4}'
```

## 11 种 shape

| shape | 实现 | 关键参数（默认） |
|-------|------|----------------|
| `box` | BoxMesh | `size [1,1,1]` |
| `cylinder` | CylinderMesh | `height 1` / `radius 0.5` |
| `sphere` | SphereMesh | `radius 0.5` |
| `prism` | PrismMesh | `size [1,1,1]` / `left_to_right 0.5` |
| `wall` | BoxMesh 语义化 | `length 2` / `height 1` / `thickness 0.1` |
| `ramp` | PrismMesh 语义化 | `length 2` / `height 1` / `width 1` |
| `cone` | 手写 SurfaceTool | `height 1` / `radius 0.5` / `segments 24` |
| `tube` | 手写 | `height 1` / `radius 0.5` / `thickness 0.1` |
| `torus` | 手写 | `major_radius 0.5` / `minor_radius 0.2` |
| `stairs` | 手写 组合 | `steps 5` / `step_height 0.2` / `step_depth 0.3` / `width 1.2` |
| `fence` | 手写 组合 | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04` |

详见 [docs/shapes-reference.md](docs/shapes-reference.md)。

## 材质

`--mat` 支持三种：

- **预设名**：`wood` / `metal` / `stone` / `glass` / `gold` / `coral` / `sand` / `seaweed` / `water` / `default`
- **自定义 PBR**：`--mat '{"color":"FF0000","metallic":0.5,"roughness":0.4}'`
- **外部资源**：`--mat res://path/to/material.tres`

`glass` / `water` 预设自动启用 alpha 透明。

## 协议

JSON over WebSocket（端口 60650，bind 127.0.0.1）。消息类型：`handshake` / `handshake_ack` / `ping`/`pong` / `generate` / `generate_batch` / `generate_result` / `undo_last`。详见 [docs/protocol.md](docs/protocol.md)。

## 鉴权

插件启动时生成随机 token 写到 `user://asset_forge.token`（Godot 项目 user 目录）。客户端三重解析定位：`--godot-user-dir` 参数 > `GODOT_USER_DIR` 环境变量 > 默认 `%APPDATA%\Godot\app_userdata\<project_name>\`。token 不符 → `unauthorized` + 断连。

## 跑测试

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

4 个 suite：AssetFactory / CustomMeshes / ScenePlacer / CommandServer（后者用 WebSocketPeer 自连本地 server 直测协议层）。

## 项目结构

```
addons/asset_forge/   # 插件（10 文件，扁平结构）
  asset_forge_plugin.gd    # EditorPlugin 入口：装配 + _on_command 编排
  command_server.gd        # WS 服务器 + 协议常量 + handshake token 鉴权
  asset_factory.gd         # shape 调度 + 内置 mesh + create_material 4 来源
  custom_meshes.gd         # 5 手写 ArrayMesh（SurfaceTool）
  material_library.gd      # 10 预设 StandardMaterial3D
  scene_placer.gd          # place + undo + save .tscn
  forge_dock.gd            # Dock UI
  log_helper.gd / localization.gd / plugin.cfg
tools/forge_client.py  # bash 客户端（generate / undo / batch / --selftest）
tests/                  # 4 suite + test_runner.gd
docs/                   # 架构 / shape / 协议 文档
```

## 致谢

Forked from **Tripo3D Godot Bridge** —— 复用其 WebSocket 服务器骨架 / Dock UI / 日志 / 本地化框架，核心改造成通用资产生成器。

## 协议

[MIT](LICENSE)
