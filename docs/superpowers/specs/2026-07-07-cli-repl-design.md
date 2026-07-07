# v9 CLI REPL 设计

> **spec**：forge_client 加 REPL 模式（`--repl`），一个 python 进程 + 一次 WS 连接循环读命令，省 python 启动 + handshake。叠加 v8 daemon 共存。
> **动机来源**：v8 Step 8 实测（`docs/superpowers/plans/2026-07-07-client-persistent-daemon.md` 实测结论 + 开发日志 `2026-07-07 v8 client 常驻 daemon`）——python 启动（~150-300ms）是单条 CLI 命令大头，v8 daemon 只省 handshake（~133ms/条，1.4x）。要省 python 启动需 CLI 进程常驻 → REPL。

## 目标

- 连续多条命令**一个 python 进程 + 一次 WS**，省 python 启动 + handshake（每条仅 server 处理 ~7ms）
- **叠加 v8 daemon 共存**：bash 一行 → v8 daemon（省 handshake 1.4x）；连续命令 → v9 REPL（省 python+handshake ~5x）。用户按场景选
- **复用 bash 子命令格式**（一套语法）：`fence --path '[[...]]' --count 64 --mode continuous` / `box --pos 1 0 0` / `undo` / `batch box wall`
- **复用 v8 `_collect`/`_shape`**（输出逐字节不变）

## 非目标（YAGNI）

- 不改 v8 daemon / bash 一行 CLI（**零回归**，v9 叠加不替代）
- 不做 history（readline 自然支持）/ help / tab 补全（后续）
- 不做 WS 断重连（断则提示退）
- 不做远程（仅本机）
- 不改 server / 协议

## 架构

### 入口

`forge_client --repl`（新增 argparse 选项，main 分流，先于 shape/selftest；**与 shape/位置参数互斥**——`--repl` 独占）

### REPL 流程

1. `connect_and_handshake` server（**一次**，保 `ws`，复用 v8 既有 :282）
2. 循环：
   - `input("forge> ")`（读一行）
   - `exit`/`quit`/`EOFError`（Ctrl+D）→ break
   - `_parse_repl_line(line) -> msg|None`（shlex split + 复用 main 的 argparse parser（`parse_args(tokens)`）+ 分流逻辑，**零改 `build_*`**；解析失败 → 提示错误 + continue）
   - `results = await _collect(ws, msg)` + `print(json.dumps(_shape(msg, results), ensure_ascii=False))`（复用 v8 纯函数，输出格式逐字节 = bash CLI）
   - 异常（解析/server）→ 提示 + continue（**单命令错误不退 REPL**）
3. `await ws.close()` + `sys.exit(0)`

### REPL 直连 server（不经 v8 daemon）

REPL 是常驻 python 进程，直连 server 最简（省 daemon 转发层，省 IPC）。v8 daemon 继续服务 bash 一行 CLI（每条新 python + 经 daemon）。两路径独立共存：

```
bash 一行：forge_client fence ... → dispatch → v8 daemon（IPC）→ server（复用 WS，省 handshake）
REPL：     forge_client --repl → 直连 server（一次 WS）→ 循环命令（省 python 启动 + handshake）
```

### 命令格式（复用 bash 子命令）

`shlex.split(line)` → 重建 main 的 argparse parser（`parse_args(tokens)`）→ 复用 main 分流（generate/batch/path/undo）→ 构造 `msg`（**零改 `build_*`**，一套语法）：
- **generate**：`fence`/`box`/... + params（`--size`/`--pos`/`--mat`/...）
- **batch**：`batch box wall ramp`
- **path**：`path fence --path '[[0,0,0],[32,0,0]]' --count 64 --mode continuous`
- **undo**：`undo`
- **exit**/`quit`：退 REPL

### 收益（推算，Step 端到端实测验证）

每条命令仅 server 处理（~7ms，无 python 启动 + handshake）。连续 10 条：启动（connect ~500ms）+ 10×~7ms ≈ 570ms vs v8 前 10×~307ms ≈ 3070ms = **~5x**（v8 daemon 的 1.4x → REPL 5x）。

## 必须守住的语义不变量

1. **v8 daemon / bash 一行 CLI 零改变**（v9 叠加，不替代 v8；v8 的 35 测试零回归）
2. **REPL 输出格式逐字节 = bash CLI**（复用 `_shape`：generate/undo 单条原始 result、batch `{success,results}`、path `{success,results,count}`）
3. **REPL 单命令错误不退**（解析失败/server error → 提示 + continue 循环）。**`try/except SystemExit` 吞 `_collect`→`send_and_recv` 内部超时 `sys.exit(5)`**（防单命令超时杀 REPL，命门 #1）；`KeyboardInterrupt`（Ctrl+C）/`exit`/`quit`/Ctrl+D → `ws.close` + 退
4. **REPL 直连 server**（不经 daemon，一个 python 进程 + 一次 WS 复用）
5. **不改 server / 协议**（command_server.gd 零改动，REPL 用既有 generate/batch/path/undo 消息）

## 文件结构

| 文件 | 改动 | 责任 |
|------|------|------|
| `tools/forge_client.py` | 加 `run_repl(args)` + `_parse_repl_line(line) -> msg\|None` + `--repl` argparse + main 分流 | v9 全部改动 |
| `tests/test_forge_client_daemon.py` | 追加 REPL 测试 | _parse_repl_line + run_repl 循环 |

**单文件改动**（`forge_client.py`），复用 v8 `_collect`/`_shape`/`connect_and_handshake`/`build_*`。

## 测试策略

| 层 | 方法 | 覆盖 |
|---|---|---|
| `_parse_repl_line` | pytest（纯函数，shlex + 解析） | generate/batch/path/undo 各 → msg 正确；`exit`/`quit` → 退出标记；畸形行 → None（不崩） |
| `run_repl` 循环 | pytest（mock ws + `input` 行序列 via `monkeypatch`） | 多命令循环 + exit 退 + 单命令错误继续 + **server 超时 `sys.exit` 被 `try/except SystemExit` 吞 → continue** + **`--mat` 畸形 JSON → continue** + **WS 断 → 提示退** + 输出逐字节（复用 _shape） |
| 端到端 | 编辑器 REPL 实测（同 v8 Step 8） | 连续 10 命令 ~5x 收益验证 |

- `_parse_repl_line` 是纯函数（无 ws），pytest 易测
- `run_repl` 用 `monkeypatch.setattr("builtins.input", side_effect=[...])` 模拟输入序列 + mock ws

## 已决策（reviewer 审查裁定）

- **复用方式 = c1**（重建 main argparse parser）：`shlex.split(line)` → 重建 parser → `parse_args(tokens)` → 复用 main 分流。**零改 `build_*`** + 兑现「一套语法」+ 自动消解「argparse 复用」风险。
- **`input()` 阻塞 = `asyncio.to_thread`**：`await asyncio.to_thread(input, "forge> ")`（Python 3.9+），不阻塞 event loop。
- **sys.exit 冲突（命门 #1）= `try/except SystemExit`**：`run_repl` 循环体包 `try/except SystemExit`，吞 `_collect`→`send_and_recv` 内部超时的 `sys.exit(5)`，单命令超时 → continue（守不变量 #3），不杀 REPL。

## 与 v8 的关系

**叠加共存，不替代**：
- v8 daemon（`dispatch`/`serve`/`_try_daemon`/`maybe_start_daemon`/`run_stop`）继续服务 bash 一行 CLI（零改动）
- v9 REPL（`run_repl`/`_parse_repl_line`）是新模式，独立入口 `--repl`
- 两者共用 v8 的 `_collect`/`_shape`/`connect_and_handshake`/`build_*`（DRY）
- 用户按场景：偶尔单条 → bash 一行（v8 daemon）；连续多条 → REPL（v9）
