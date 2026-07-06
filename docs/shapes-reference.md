# Shape 参考

## 6 内置 PrimitiveMesh（`asset_factory.gd`）

| shape | 参数（默认） |
|-------|------|
| `box` | `size [1,1,1]` |
| `cylinder` | `height 1` / `radius 0.5` / `radial_segments 24` |
| `sphere` | `radius 0.5` / `radial_segments 24` / `rings 16` |
| `prism` | `size [1,1,1]` / `left_to_right 0.5` |
| `wall` | `length 2` / `height 1` / `thickness 0.1`（语义化 box） |
| `ramp` | `length 2` / `height 1` / `width 1`（语义化 prism，坡道，`left_to_right=0`；v5 起支持 continuous 模式，接缝高度台阶为已知局限） |

## 5 手写 ArrayMesh（`custom_meshes.gd`，SurfaceTool）

| shape | 参数（默认） |
|-------|------|
| `cone` | `height 1` / `radius 0.5` / `segments 24` |
| `tube` | `height 1` / `radius 0.5` / `thickness 0.1` / `segments 24`（空心圆柱） |
| `torus` | `major_radius 0.5` / `minor_radius 0.2` / `major_segments 32` / `minor_segments 16` |
| `stairs` | `steps 5` / `step_height 0.2` / `step_depth 0.3` / `width 1.2`（多台阶） |
| `fence` | `length 3` / `height 1.2` / `posts 4` / `post_radius 0.05` / `rail_thickness 0.04` / `start_post true` / `end_post true`（柱+横档；continuous 模式放置层自动注入 start/end_post 端柱共享，单件/discrete 默认 true） |

`stairs` / `fence` 把多部件烘焙进**单个 ArrayMesh**（一个 surface），避免多 mesh 取首偏置问题。

## 10 预设材质（`material_library.gd`）

| 名称 | 颜色 | metallic | roughness | 备注 |
|------|------|----------|-----------|------|
| `wood` | #8B5A2B | 0 | 0.8 | |
| `metal` | #B0B0B0 | 1.0 | 0.4 | |
| `stone` | #808080 | 0 | 0.9 | |
| `glass` | #88CCEE | 0 | 0.1 | alpha 0.3 透明 |
| `gold` | #FFD700 | 1.0 | 0.3 | |
| `coral` | #FF7F50 | 0 | 0.7 | |
| `sand` | #C2B280 | 0 | 0.95 | |
| `seaweed` | #2E8B57 | 0 | 0.8 | |
| `water` | #1E90FF | 0 | 0.2 | alpha 0.5 透明 |
| `default` | #FFFFFF | 0 | 0.7 | 未知预设回退此 |

`glass` / `water` 自动设 `transparency = BaseMaterial3D.TRANSPARENCY_ALPHA` + `albedo_color.a`。

## 自定义材质 dict

```json
{"color":"#RRGGBB","metallic":0.5,"roughness":0.4,"emissive":"#...","alpha":0.5}
```

`alpha < 1.0` 自动启用 alpha 透明。
