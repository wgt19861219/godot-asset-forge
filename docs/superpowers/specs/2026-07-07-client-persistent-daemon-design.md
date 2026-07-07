# v8 forge_client 常驻 daemon 设计

> **spec**：让 forge_client 复用 WS 连接，消除 v7 占比层发现的 ~594ms/条 client 启动开销。
> **动机来源**：v7 占比层（`docs/superpowers/plans/2026-07-06-mesh-cache.md` 完成后验证 + 开发日志 `2026-07-06 v7 mesh 缓存`）——端到端 ~600ms 里 server `generate_path` 仅 ~7ms，**99% 是 forge_client 每次新 python 进程 + WS handshake**。

## 目标

- 连续多条 CLI 命令复用 WS 连接，省每次 ~594ms python 启动 + handshake
- **bash 一行用法零改变**（`python tools/forge_client.py fence ...` 所有现有形态不变）
- daemon 永远是**加速层**：任何故障 CLI 回退直连 = 当前行为（零回归）
- **不改 server**（`command_server.gd` 零改动，已支持长连接多命令）

## 非目标（YAGNI）

- 不改 server / 协议（server 已支持一个连接发多条命令，120s keepalive + ping/pong）
- 不做多 client 调度 / 优先级
- 不做远程（仅本机 127.0.0.1）
- 不做 daemon 集群 / 负载均衡
- 不改 dock UI / 协议常量 / BATCH_LIMIT

## 背景（v7 占比层事实）

- **client**（`tools/forge_client.py`）：每条命令 `connect_and_handshake` → 发 1 命令 → `ws.close` → `sys.exit`（:196-200 / :203-208 / :235-242 / :354-363）。固定开销 ~594ms/次。
- **server**（`addons/asset_forge/command_server.gd`）：`_handle_text`（:166）对 generate/batch/path/undo 仅 match 分支，**不限每连接命令数**；`CLIENT_TIMEOUT_MSEC=120000`（:14）+ ping/pong（:200）+ `MAX_CLIENTS=8`。
- **结论**：瓶颈纯在 client 一次性进程模式。server 零改动支持连接复用。

## 架构

### 进程模型（2 个 python 进程）

1. **daemon**（`forge_client --serve`，后台）：常驻，保 server WS（60650），监听本地 TCP 60651，转发 CLI 命令 → server，收齐 result → 聚合返 CLI
2. **CLI**（`forge_client.py <shape>`，前台，入口不变）：检测 daemon → IPC 转发；不在 → 直连 server（兼容）+ 后台 `subprocess.Popen` 启 daemon

### 数据流

**命中 daemon**（第 2 条起）：
```
CLI → TCP 60651 → daemon → WS 60650 → server
result 原路：server → daemon（send_and_recv_batch 收齐）→ 聚合 {success,results,count} → CLI 打印
```

**首条命令**（daemon 没起）：
```
CLI → 直连 server 60650（当前 connect_and_handshake）→ 收 result → 打印
    → 后台 Popen 启 daemon（不等，daemon 自己连 server）
```

### IPC 协议

- **CLI → daemon**：复用 server 消息 `{type, id, payload/items}`（generate / generate_batch / generate_path / undo_last）
- **daemon → CLI**：聚合 `{success: bool, results: [...], count: int}`（与当前 `run_path`/`run_batch` 输出格式一致）
- daemon 按 type 决定收齐策略：generate/undo 收 1 条，batch 按 n，path 按 total（D 方案，复用 `send_and_recv_batch`）

## 关键决策

| 决策 | 选择 | 理由 |
|---|---|---|
| IPC | 本地 TCP `127.0.0.1:60651` | 跨平台（Win/Mac/Linux），紧挨 server 60650，python socket 简单 |
| daemon 启动 | 自动 fork（首条 CLI 触发，Popen 后台） | 用户无感，bash 用法不变 |
| daemon 退出 | 空闲 60s / server WS 断 / `--stop` | 防泄漏 + 跟随 server 生命周期 |
| 兼容 | CLI 连 daemon 失败 → 直连 server | 零回归，daemon 是加速层非必需层 |
| daemon 收齐 | 复用 `send_and_recv_batch` | 不重新发明收齐逻辑 |
| CLI 连 daemon 超时 | 200ms | 短，快速回退直连 |

## 错误处理（直连回退矩阵）

| 场景 | CLI 行为 | 用户感知 |
|---|---|---|
| daemon 没起 | 直连 server（当前）+ 后台启 daemon | 首条 ~600ms（= 现状） |
| daemon 在但 server 断 | daemon 返错 → CLI 回退直连 | 该条 ~600ms |
| daemon 崩溃 / 端口占 | CLI 连 60651 失败 → 直连 | 该条 ~600ms |
| 连 daemon 超时（200ms） | 回退直连 | 该条 ~600ms |
| daemon 空闲 60s | 自退 | 下条命令重启（首条 ~600ms） |

**核心不变量**：最差体验 = 当前现状（直连）。daemon 故障永不让用户卡死或报错。

## 必须守住的语义不变量

1. **bash 一行用法零改变**：`python tools/forge_client.py fence --path '[[0,0,0],[32,0,0]]' --count 64 --mode continuous` 等所有现有命令形态、参数、输出格式（`{success, results, count}`）不变
2. **零回归**：daemon 不可用时 CLI 直连 = 当前行为（最差 = 现状）
3. **不改 server / 协议**：`command_server.gd` 零改动，IPC 不引入新 server 消息类型
4. **token 鉴权不绕过**：daemon 连 server 仍走 handshake token（读同一 token 文件，token 优先级不变）
5. **batch per-item 散回执语义不变**（CLAUDE.md 不变量 4）：daemon 收齐后聚合返 CLI 是 **client 端聚合**（当前 `run_batch` 已是 client 聚合，:238-239），不改变 server 散回执

## 文件结构

| 文件 | 改动 | 责任 |
|---|---|---|
| `tools/forge_client.py` | 加 daemon 模式（`--serve`）+ CLI daemon 检测/转发/回退 + IPC 收齐 | 全部 v8 改动集中此文件 |

**单文件改动**（`forge_client.py`），不新增文件、不改 server、不改插件。daemon 逻辑与既有 `connect_and_handshake`/`send_and_recv_batch`/`run_*` 共存。

## 测试策略

| 层 | 方法 | 覆盖 |
|---|---|---|
| daemon 转发 | pytest（mock server WS） | generate/batch/path/undo 各 type 收齐 + 聚合 |
| CLI 检测/回退 | pytest（mock daemon TCP） | daemon 在→转发 / 不在→直连 / 超时→回退 |
| IPC 收齐 | pytest | batch N 条 / path 按 total 多 result 聚合 |
| 端到端 | 编辑器插桩（同 v7 占比层） | daemon 模式连续 10 命令端到端耗时（6s → ~1s） |

- pytest 扩展 `tests/test_forge_client_predict.py`（既有 pytest 基础）或新建 `tests/test_forge_client_daemon.py`
- headless（pytest）覆盖逻辑层，编辑器手测验证收益

## 风险 / 未决

- **Windows `subprocess.Popen` 后台 daemon 的 stdout/stderr**：daemon 后台跑，stdout 不能干扰 CLI 的 JSON 输出。daemon 重定向 stdout/stderr 到日志文件（如 `%TEMP%/forge_client_daemon.log`）或 `DEVNULL`。**计划阶段定具体方式**。
- **daemon 与 CLI 的 token 一致性**：daemon 启动时读 token（同 CLI），server 重启换 token 时 daemon 的 WS 失效 → 返错 → CLI 回退直连。可接受（回退保证）。
- **端口 60651 冲突**：若被占，daemon 启动失败 → CLI 回退直连。可接受（文档注明端口约定）。
- **daemon 与既有 selftest 兼容**：`--selftest` 是一次性流程，不经 daemon（直连）。daemon 只加速常规 generate/batch/path/undo 命令。
