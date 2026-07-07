# v8 forge_client 常驻 daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** forge_client 加常驻 daemon 复用 WS 连接，连续多条 CLI 命令省每次 ~594ms python 启动+handshake，bash 用法与输出格式零改变。

**Architecture:** daemon 后台进程保 server WS（60650）+ 监听本地 TCP 60651，串行转发 CLI 命令按 type 收齐逐 type 镜像返；CLI 检测 daemon 在则 IPC 转发，不在直连回退（零回归）+ 后台 Popen 启 daemon。复用既有 `connect_and_handshake`/`send_and_recv`/`send_and_recv_batch`，不改 server。

**Tech Stack:** Python 3（asyncio + websockets，forge_client 既有栈），pytest，subprocess.Popen（Windows CREATE_NO_WINDOW）。

## Global Constraints

- **单文件改动** `tools/forge_client.py`，新建 `tests/test_forge_client_daemon.py`，**不改** server（`command_server.gd`）/ 插件 / 协议常量
- **bash 一行用法零改变**：所有现有命令形态、参数、**输出格式逐字节不变**（generate/undo 单条 result、batch `{success,results}`、path `{success,results,count}`），**`$?` 语义不变**（CLI 据 daemon 返回 success 算 exit code，非 daemon 进程退）
- **零回归**：daemon 不可用 → CLI 直连 = 当前行为（最差 = 现状）；`--selftest` 路径不经 daemon（保持直连，`run_selftest` 独立 `connect_and_handshake`）
- **daemon 串行**（守不变量 #7）：单 WS 复用，`asyncio.Lock` 一次只处理一个 CLI 请求（固定 id `req_1`/`r_batch`/`r_path`/`undo_1` 并发会撞 id 串结果）
- **daemon idle < server keepalive**（守不变量 #6）：`DAEMON_IDLE_TIMEOUT = 60`（必须 < `CLIENT_TIMEOUT_MSEC = 120000`，`command_server.gd:14`）
- **token 鉴权不绕过**：daemon 连 server 走 `connect_and_handshake`（读同一 token 文件）
- **IPC**：本地 TCP `127.0.0.1:60651`，CLI 连 daemon 超时 `0.2s`（`DAEMON_CONNECT_TIMEOUT`）
- **Windows Popen stdio 三件套**：stdout/stderr → `%TEMP%/forge_client_daemon.log`（truncate-on-start，非 DEVNULL）+ `creationflags=CREATE_NO_WINDOW`（防控制台闪窗）+ `stdin=DEVNULL`
- forge_client.py **缩进 = 4 空格**（既有 python 风格）；注释简体中文
- 现有 4 命令输出形状（必须逐 type 镜像）：generate/undo = 单条原始 result（无 `results`/`count`）、batch = `{success,results}`（无 `count`，对齐 :238-239）、path = `{success,results,count}`（对齐 :361）
- 当前分支 `master`（v1-v7 直接 commit master，无 feature 分支）；本仓库无 remote
- godot 不在 PATH，全路径：`D:/godot/Godot_v4.6.3-stable_win64_console.exe`
- pytest 既有：`tests/test_forge_client_predict.py`（python 3）

## File Structure

| 文件 | 改动 | 责任 |
|------|------|------|
| `tools/forge_client.py` | 加 `_collect`/`_shape`/`serve`/`_handle_cli`/`dispatch`/`_try_daemon`/`maybe_start_daemon`/`run_stop` + 改 `run_generate`/`run_undo`/`run_batch`/`run_path`/`main` 用 dispatch + argparse `--serve`/`--stop` | v8 全部改动 |
| `tests/test_forge_client_daemon.py` | 新建 pytest | daemon 转发/收齐/shaping/串行/CLI dispatch/回退 |

`_collect(ws, msg)` + `_shape(msg, results)` 是纯函数（daemon 与直连共用收齐 + 镜像逻辑，DRY）。`dispatch` 是 CLI 入口分流（daemon 在转发 / 不在直连 + 启 daemon）。

---

### Task 1: `_collect` + `_shape` 纯函数（按 type 收齐 + 逐 type 镜像 shaping）

**Files:**
- Modify: `tools/forge_client.py`（加 `_collect` + `_shape`，紧贴既有 `send_and_recv_batch` 后）
- Test: `tests/test_forge_client_daemon.py`（新建）

**Interfaces:**
- Consumes: 既有 `send_and_recv(ws, msg)`（单条，:89）/ `send_and_recv_batch(ws, msg, n)`（多条，:102）
- Produces:
  - `async _collect(ws, msg) -> Array`（按 type 收齐：generate/undo 返 `[单条]`、batch 按 n、path 按 total）
  - `_shape(msg, results) -> Dictionary`（逐 type 镜像 CLI 输出形状）

- [ ] **Step 1: 写失败测试（新建 test 文件）**

创建 `tests/test_forge_client_daemon.py`：

```python
"""v8 forge_client daemon 单测：_collect 收齐 + _shape 逐 type 镜像 shaping。"""
import asyncio
import json
import pytest


class FakeWS:
    """mock server WS：预设 server 返回的 result 序列，记录 send 的消息。"""
    def __init__(self, responses):
        self._responses = responses  # list[dict]：recv 依次返回
        self.sent = []
    async def send(self, text):
        self.sent.append(json.loads(text))
    async def recv(self):
        return json.dumps(self._responses.pop(0))


# 导入被测函数（forge_client 在 tools/）
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from forge_client import _collect, _shape


def test_collect_generate_single():
    """generate：send_and_recv 单条，返 [单条 result]。"""
    ws = FakeWS([{"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_0"}])
    msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
    results = asyncio.get_event_loop().run_until_complete(_collect(ws, msg))
    assert len(results) == 1
    assert results[0]["node_path"] == "/Root/box_0"
    assert ws.sent[0]["type"] == "generate"


def test_collect_undo_single():
    """undo_last：单条 result。"""
    ws = FakeWS([{"type": "generate_result", "id": "undo_1", "success": True}])
    msg = {"type": "undo_last", "id": "undo_1"}
    results = asyncio.get_event_loop().run_until_complete(_collect(ws, msg))
    assert len(results) == 1


def test_collect_batch_by_n():
    """generate_batch：send_and_recv_batch 按 n 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
    ])
    msg = {"type": "generate_batch", "id": "r_batch", "items": [{"shape": "box"}, {"shape": "wall"}, {"shape": "ramp"}]}
    results = asyncio.get_event_loop().run_until_complete(_collect(ws, msg))
    assert len(results) == 3


def test_collect_path_by_total():
    """generate_path：send_and_recv_batch n=None 靠 total 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
    ])
    msg = {"type": "generate_path", "id": "r_path", "payload": {"shape": "fence"}}
    results = asyncio.get_event_loop().run_until_complete(_collect(ws, msg))
    assert len(results) == 2


def test_shape_generate_no_wrapping():
    """generate：单条原始 result，无 results/count 包装（守不变量 #1）。"""
    msg = {"type": "generate", "id": "req_1"}
    results = [{"success": True, "node_path": "/Root/box_0"}]
    shaped = _shape(msg, results)
    assert shaped == {"success": True, "node_path": "/Root/box_0"}  # 直接是单条，无 results/count
    assert "results" not in shaped
    assert "count" not in shaped


def test_shape_undo_no_wrapping():
    """undo：单条原始 result，无包装。"""
    msg = {"type": "undo_last", "id": "undo_1"}
    results = [{"success": True, "message": "freed 3"}]
    shaped = _shape(msg, results)
    assert shaped == {"success": True, "message": "freed 3"}
    assert "results" not in shaped


def test_shape_batch_no_count():
    """batch：{success, results}，无 count（对齐 run_batch :238-239）。"""
    msg = {"type": "generate_batch", "id": "r_batch"}
    results = [{"success": True}, {"success": False, "error": "x"}]
    shaped = _shape(msg, results)
    assert shaped == {"success": False, "results": results}  # all_ok=False
    assert "count" not in shaped


def test_shape_path_with_count():
    """path：{success, results, count}（对齐 run_path :361）。"""
    msg = {"type": "generate_path", "id": "r_path"}
    results = [{"success": True, "total": 2}, {"success": True, "total": 2}]
    shaped = _shape(msg, results)
    assert shaped == {"success": True, "results": results, "count": 2}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/test_forge_client_daemon.py -v 2>&1 | tail -10`
Expected: 8 FAIL（`ImportError: cannot import name '_collect'` / `'_shape'`）。

- [ ] **Step 3: 实现 `_collect` + `_shape`**

在 `tools/forge_client.py` 的 `send_and_recv_batch` 函数后（:134 后）插入：

```python
# === v8 daemon：按 type 收齐 + 逐 type 镜像 shaping（daemon 与直连共用，DRY）===


# 按 type 收齐 server result：generate/undo 返 [单条]，batch 按 n，path 按 total
async def _collect(ws, msg):
	await ws.send(json.dumps(msg, ensure_ascii=False))
	t = msg.get("type")
	if t == "generate" or t == "undo_last":
		return [await send_and_recv(ws, msg)]  # 单条（既有 send_and_recv）
	# batch/path：send_and_recv_batch
	n = len(msg.get("items", [])) if t == "generate_batch" else None  # path n=None 靠 total
	return await send_and_recv_batch(ws, msg, n)


# 逐 type 镜像 CLI 输出形状（守不变量 #1：generate/undo 单条、batch 无 count、path 有 count）
def _shape(msg, results):
	t = msg.get("type")
	success = all(bool(r.get("success")) for r in results)
	if t == "generate" or t == "undo_last":
		return results[0]  # 单条原始 result，无 results/count 包装
	if t == "generate_batch":
		return {"success": success, "results": results}  # 无 count（对齐 run_batch :238-239）
	if t == "generate_path":
		return {"success": success, "results": results, "count": len(results)}  # 有 count（对齐 run_path :361）
	return {"success": False, "error": "unknown_type"}
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/test_forge_client_daemon.py -v 2>&1 | tail -10`
Expected: 8 PASS。

- [ ] **Step 5: 跑既有测试确认零回归**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/ -v 2>&1 | tail -5`
Expected: 既有 `test_forge_client_predict.py` 全 PASS + 新 8 PASS（_collect/_shape 是纯加法，不影响既有）。

- [ ] **Step 6: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_daemon.py
git commit -m "feat: v8 _collect + _shape 纯函数（按 type 收齐 + 逐 type 镜像）

- _collect：generate/undo 单条 / batch 按 n / path 按 total（复用 send_and_recv(_batch)）
- _shape：逐 type 镜像 CLI 输出形状（守不变量 #1，不统一 shaping）
- daemon 与直连共用（DRY），Task 2/3 复用
- 8 pytest PASS（收齐 4 + shaping 4）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: daemon 进程 `serve` + `_handle_cli`（连 server + 监听 IPC + 串行 + 空闲退 + stop）

**Files:**
- Modify: `tools/forge_client.py`（加 `serve` + `_handle_cli` + 常量，Task 1 函数后）
- Test: `tests/test_forge_client_daemon.py`（追加集成测）

**Interfaces:**
- Consumes: Task 1 `_collect`/`_shape`；既有 `connect_and_handshake(args)`（:137）
- Produces:
  - 常量 `DAEMON_HOST="127.0.0.1"` / `DAEMON_PORT=60651` / `DAEMON_IDLE_TIMEOUT=60` / `DAEMON_CONNECT_TIMEOUT=0.2`
  - `async serve(args)`：daemon 主循环（连 server + 监听 60651 + 串行转发 + 空闲 60s/stop 退）

- [ ] **Step 1: 写失败测试（追加集成测）**

在 `tests/test_forge_client_daemon.py` 末尾追加：

```python
import asyncio
from unittest.mock import AsyncMock, patch
from forge_client import serve, DAEMON_PORT, DAEMON_IDLE_TIMEOUT


async def _start_daemon_with_mock_server(server_responses, stop_after=2.0):
    """启动真 daemon（mock server WS）+ 一个真 CLI socket 连它，返回 CLI 收到的响应。
    stop_after 秒后强制取消 daemon（测空闲退出另写）。"""
    cli_responses = []

    async def fake_connect_and_handshake(args):
        return FakeWS(list(server_responses))

    async def cli_task():
        await asyncio.sleep(0.3)  # 等 daemon 起来
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", DAEMON_PORT)
            for msg in [
                {"type": "generate", "id": "req_1", "payload": {"shape": "box"}},
            ]:
                writer.write(json.dumps(msg).encode("utf-8"))
                await writer.drain()
                data = await asyncio.wait_for(reader.read(65536), timeout=5.0)
                cli_responses.append(json.loads(data.decode("utf-8")))
            writer.close()
        except OSError:
            pass

    with patch("forge_client.connect_and_handshake", new=fake_connect_and_handshake):
        serve_task = asyncio.create_task(serve(_make_args()))
        cli_task_obj = asyncio.create_task(cli_task())
        await asyncio.wait_for(cli_task_obj, timeout=stop_after)
        serve_task.cancel()
        try:
            await serve_task
        except asyncio.CancelledError:
            pass
    return cli_responses


def _make_args():
    """最小 args mock（connect_and_handshake 被 patch，token 不读）。"""
    class A: pass
    a = A()
    a.godot_user_dir = None
    return a


def test_serve_forwards_generate_single_shape():
    """daemon 转发 generate → 返单条 result（无 results/count，守不变量 #1）。"""
    responses = [{"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_0"}]
    cli_responses = asyncio.get_event_loop().run_until_complete(_start_daemon_with_mock_server(responses))
    assert len(cli_responses) == 1
    assert cli_responses[0] == {"success": True, "node_path": "/Root/box_0"}  # 单条，无包装
    assert "results" not in cli_responses[0]


def test_serve_idle_timeout_exits():
    """daemon 空闲 DAEMON_IDLE_TIMEOUT 后自动退出（测短超时）。"""
    async def run():
        async def fake_handshake(args):
            return FakeWS([])
        with patch("forge_client.connect_and_handshake", new=fake_handshake), \
             patch("forge_client.DAEMON_IDLE_TIMEOUT", 1):  # 缩到 1s 加速测试
            task = asyncio.create_task(serve(_make_args()))
            await asyncio.sleep(1.5)  # 超过 1s 空闲
            assert task.done(), "daemon 应在空闲超时后退出"
    asyncio.get_event_loop().run_until_complete(run())


def test_serve_stop_message_exits():
    """CLI 发 {type:stop} → daemon 退出。"""
    async def run():
        async def fake_handshake(args):
            return FakeWS([])
        with patch("forge_client.connect_and_handshake", new=fake_handshake):
            task = asyncio.create_task(serve(_make_args()))
            await asyncio.sleep(0.3)
            reader, writer = await asyncio.open_connection("127.0.0.1", DAEMON_PORT)
            writer.write(json.dumps({"type": "stop"}).encode("utf-8"))
            await writer.drain()
            await asyncio.wait_for(task, timeout=2.0)
            assert task.done(), "daemon 应收到 stop 后退出"
    asyncio.get_event_loop().run_until_complete(run())
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/test_forge_client_daemon.py -v 2>&1 | tail -10`
Expected: 新 3 FAIL（`ImportError: cannot import name 'serve'`）+ 既有 8 PASS。

- [ ] **Step 3: 实现 `serve` + `_handle_cli` + 常量**

在 `tools/forge_client.py` 顶部 import 区加 `import time`（若无），Task 1 `_shape` 后加：

```python
# === v8 daemon 常量 ===
DAEMON_HOST = "127.0.0.1"
DAEMON_PORT = 60651
DAEMON_IDLE_TIMEOUT = 60  # 守不变量 #6：必须 < server CLIENT_TIMEOUT_MSEC=120s（command_server.gd:14）
DAEMON_CONNECT_TIMEOUT = 0.2  # CLI 连 daemon 超时，超时回退直连


# daemon 主循环：连 server + 监听 IPC + 串行转发 + 空闲/stop 退出
async def serve(args):
	ws_server = await connect_and_handshake(args)  # 复用既有，保 WS
	last_active = time.monotonic()
	state = {"stop": False}
	lock = asyncio.Lock()  # 守不变量 #7：串行（一次一个 CLI 请求）

	async def _handle_cli(reader, writer):
		nonlocal last_active
		try:
			data = await reader.read(65536)
			msg = json.loads(data.decode("utf-8"))
			if msg.get("type") == "stop":  # --stop 用
				state["stop"] = True
				writer.write(json.dumps({"success": True, "stopped": True}, ensure_ascii=False).encode("utf-8"))
				await writer.drain()
				return
			# 串行：lock 保证一次只处理一个 CLI 请求（固定 id 并发会撞）
			async with lock:
				results = await _collect(ws_server, msg)
				resp = _shape(msg, results)
			writer.write(json.dumps(resp, ensure_ascii=False).encode("utf-8"))
			await writer.drain()
		except (OSError, json.JSONDecodeError, asyncio.TimeoutError):
			pass  # 单连接错误不杀 daemon
		finally:
			writer.close()
			last_active = time.monotonic()  # 活动刷新（含 stop）

	srv = await asyncio.start_server(_handle_cli, DAEMON_HOST, DAEMON_PORT)
	try:
		async with srv:
			while not state["stop"]:
				await asyncio.sleep(1)  # 每 1s 检查空闲 + stop
				if time.monotonic() - last_active > DAEMON_IDLE_TIMEOUT:
					break  # 空闲超时退出（防僵尸 daemon）
	finally:
		await ws_server.close()
```

- [ ] **Step 4: 跑测试确认 GREEN**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/test_forge_client_daemon.py -v 2>&1 | tail -10`
Expected: 11 PASS（Task 1 的 8 + Task 2 的 3）。

- [ ] **Step 5: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_daemon.py
git commit -m "feat: v8 daemon serve + _handle_cli（连 server + 监听 IPC + 串行 + 空闲退 + stop）

- serve：connect_and_handshake 保 WS + asyncio.start_server 监听 60651
- _handle_cli：asyncio.Lock 串行（守不变量 #7）+ _collect/_shape 转发
- 空闲 DAEMON_IDLE_TIMEOUT=60s 退出（< server 120s，守不变量 #6）
- {type:stop} 消息退出（--stop 用，复用 IPC 通道）
- 3 集成 pytest PASS（转发单条 shape + 空闲退 + stop 退）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: CLI `dispatch` + `_try_daemon` + `maybe_start_daemon` + `run_stop` + run_\* 改 + argparse

**Files:**
- Modify: `tools/forge_client.py`（加 dispatch/_try_daemon/maybe_start_daemon/run_stop + 改 run_generate/run_undo/run_batch/run_path/main + argparse）
- Test: `tests/test_forge_client_daemon.py`（追加 dispatch/回退测试）

**Interfaces:**
- Consumes: Task 1 `_collect`/`_shape`；Task 2 常量 `DAEMON_HOST`/`DAEMON_PORT`/`DAEMON_CONNECT_TIMEOUT`；既有 `connect_and_handshake`/`build_payload`/`build_path_payload`/argparse
- Produces:
  - `async dispatch(msg, args) -> Dictionary`（daemon 在转发 / 不在直连 + 启 daemon，返逐 type 镜像 result）
  - `async _try_daemon(msg) -> Dictionary|None`（连 daemon 转发，失败返 None）
  - `maybe_start_daemon(args)`（后台 Popen 启 daemon，stdio 三件套）
  - `async run_stop(args)`（发 stop 消息）
  - 改：`run_generate`/`run_undo`/`run_batch`/`run_path` 用 `dispatch`；`main` 加 `--serve`/`--stop` 分流

- [ ] **Step 1: 写失败测试（追加 dispatch/回退测试）**

在 `tests/test_forge_client_daemon.py` 末尾追加：

```python
from forge_client import dispatch, _try_daemon, maybe_start_daemon, run_stop


def test_try_daemon_returns_none_when_not_running():
    """daemon 没起 → _try_daemon 返 None（触发回退）。"""
    msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
    result = asyncio.get_event_loop().run_until_complete(_try_daemon(msg))
    assert result is None


def test_try_daemon_forwards_when_running():
    """daemon 在 → _try_daemon 连上转发返逐 type 镜像。"""
    async def run():
        # 启个假 daemon（echo 单条 generate result）
        async def fake_handle(reader, writer):
            data = await reader.read(65536)
            msg = json.loads(data.decode("utf-8"))
            if msg.get("type") == "generate":
                resp = {"success": True, "node_path": "/Root/box_0"}  # 单条镜像
                writer.write(json.dumps(resp).encode("utf-8"))
                await writer.drain()
        srv = await asyncio.start_server(fake_handle, "127.0.0.1", DAEMON_PORT)
        async with srv:
            result = await _try_daemon({"type": "generate", "id": "req_1", "payload": {"shape": "box"}})
            assert result == {"success": True, "node_path": "/Root/box_0"}
    asyncio.get_event_loop().run_until_complete(run())


def test_dispatch_falls_back_to_direct_when_no_daemon():
    """daemon 不在 → dispatch 直连 server（mock connect_and_handshake + _collect）。"""
    async def run():
        fake_ws = FakeWS([{"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_1"}])
        started = []
        async def fake_handshake(args):
            return fake_ws
        def fake_start(args):
            started.append(args)  # 记录是否触发启 daemon
        msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
        with patch("forge_client.connect_and_handshake", new=fake_handshake), \
             patch("forge_client.maybe_start_daemon", new=fake_start):
            result = await dispatch(msg, _make_args())
        assert result == {"success": True, "node_path": "/Root/box_1"}  # 直连单条镜像
        assert len(started) == 1  # 回退时触发了启 daemon
    asyncio.get_event_loop().run_until_complete(run())


def test_maybe_start_daemon_uses_stdio_trio(monkeypatch, tmp_path):
    """maybe_start_daemon：日志文件 truncate-on-start + CREATE_NO_WINDOW + stdin=DEVNULL。"""
    import subprocess, sys
    captured = {}
    log_file = tmp_path / "forge_client_daemon.log"
    monkeypatch.setattr("tempfile.gettempdir", lambda: str(tmp_path))
    class FakePopen:
        def __init__(self, cmd, **kwargs):
            captured["cmd"] = cmd
            captured["kwargs"] = kwargs
    monkeypatch.setattr("subprocess.Popen", FakePopen)
    maybe_start_daemon(_make_args())
    # stdin=DEVNULL
    assert captured["kwargs"]["stdin"] == subprocess.DEVNULL
    # stdout 是文件对象（日志，非 DEVNULL/PIPE）
    assert captured["kwargs"]["stdout"] is not subprocess.DEVNULL
    assert captured["kwargs"]["stderr"] == subprocess.STDOUT
    # Windows CREATE_NO_WINDOW
    if sys.platform == "win32":
        assert captured["kwargs"].get("creationflags") == subprocess.CREATE_NO_WINDOW
    # 命令是 python -m forge_client --serve（或 __file__ --serve）
    assert "--serve" in captured["cmd"]
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/test_forge_client_daemon.py -v 2>&1 | tail -10`
Expected: 新 4 FAIL（`ImportError: cannot import name 'dispatch'` 等）+ 既有 11 PASS。

- [ ] **Step 3: 实现 `dispatch` + `_try_daemon` + `maybe_start_daemon` + `run_stop`**

在 Task 2 `serve` 后加：

```python
# === v8 CLI 端：daemon 转发 + 直连回退 + 启 daemon ===


# 连 daemon 转发，超时/失败返 None（触发直连回退）
async def _try_daemon(msg):
	try:
		reader, writer = await asyncio.wait_for(
			asyncio.open_connection(DAEMON_HOST, DAEMON_PORT),
			timeout=DAEMON_CONNECT_TIMEOUT)
	except (OSError, asyncio.TimeoutError):
		return None  # daemon 没起 / 端口占 → 回退
	try:
		writer.write(json.dumps(msg, ensure_ascii=False).encode("utf-8"))
		await writer.drain()
		data = await asyncio.wait_for(reader.read(65536), timeout=30.0)
		return json.loads(data.decode("utf-8"))
	except (OSError, asyncio.TimeoutError, json.JSONDecodeError):
		return None  # daemon 异常 → 回退
	finally:
		writer.close()


# 后台 Popen 启 daemon（Windows stdio 三件套，防闪窗 + 日志 + 防阻塞）
def maybe_start_daemon(args):
	import subprocess
	import tempfile
	log_path = os.path.join(tempfile.gettempdir(), "forge_client_daemon.log")
	log_f = open(log_path, "w")  # truncate-on-start（非 DEVNULL，崩了能看 traceback）
	kwargs = {"stdin": subprocess.DEVNULL, "stdout": log_f, "stderr": subprocess.STDOUT}
	if sys.platform == "win32":
		kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW  # 防控制台闪窗
	subprocess.Popen([sys.executable, __file__, "--serve"], **kwargs)  # 不等


# CLI 入口分流：daemon 在转发 / 不在直连 + 启 daemon（返逐 type 镜像 result）
async def dispatch(msg, args):
	resp = await _try_daemon(msg)
	if resp is not None:
		return resp  # daemon 返的逐 type 镜像
	# 回退直连（= 当前行为）+ 后台启 daemon（后续命令命中）
	maybe_start_daemon(args)
	ws = await connect_and_handshake(args)
	try:
		results = await _collect(ws, msg)
	finally:
		await ws.close()
	return _shape(msg, results)


# --stop：发 stop 消息给 daemon
async def run_stop(args):
	msg = {"type": "stop"}
	try:
		reader, writer = await asyncio.open_connection(DAEMON_HOST, DAEMON_PORT)
		writer.write(json.dumps(msg).encode("utf-8"))
		await writer.drain()
		await reader.read(65536)  # daemon 回 {success:true,stopped:true} 后退
		writer.close()
		print(json.dumps({"success": True, "stopped": True}, ensure_ascii=False))
		sys.exit(0)
	except OSError:
		print(json.dumps({"success": False, "error": "daemon_not_running"}), file=sys.stderr)
		sys.exit(1)
```

- [ ] **Step 4: 改 `run_generate`/`run_undo`/`run_batch`/`run_path` 用 `dispatch`**

把 `tools/forge_client.py` 的 4 个 run_*（:195-208 / :211-242 / :319-363）改为：

```python
async def run_generate(args):
	msg = {"type": "generate", "id": "req_1", "payload": build_payload(args)}
	result = await dispatch(msg, args)  # daemon 在转发 / 不在直连
	print(json.dumps(result, ensure_ascii=False))
	sys.exit(0 if result.get("success") else 1)  # $? 由 CLI 据 success 算（守不变量 #1）


async def run_undo(args):
	msg = {"type": "undo_last", "id": "undo_1"}
	result = await dispatch(msg, args)
	print(json.dumps(result, ensure_ascii=False))
	sys.exit(0 if result.get("success") else 1)


async def run_batch(args):
	items = []
	if args.items:
		try:
			parsed = json.loads(args.items)
			if not isinstance(parsed, list):
				print("--items 必须是 JSON 数组", file=sys.stderr); sys.exit(2)
			items = parsed
		except json.JSONDecodeError as e:
			print(f"--items JSON 解析失败: {e}", file=sys.stderr); sys.exit(2)
	elif args.batch_shapes:
		for s in args.batch_shapes:
			items.append({"shape": s})
	else:
		print("batch 需要 --items '<json>' 或位置参数 shape 名", file=sys.stderr); sys.exit(2)
	msg = {"type": "generate_batch", "id": "r_batch", "items": items}
	result = await dispatch(msg, args)  # {success, results}（无 count，_shape 保证）
	print(json.dumps(result, ensure_ascii=False))
	sys.exit(0 if result.get("success") else 1)
```

`run_path`（:319-363）：**保留 path 源解析 + predict_n 校验段**（:322-352，path/path_file/path_node 三互斥 + predict_n 上限检查，不动）。把从 `ws = await connect_and_handshake(args)`（:354）到 `sys.exit(...)`（:364）的 连接+发送+收齐+close 段，替换为：

```python
	msg = {"type": "generate_path", "id": "r_path", "payload": build_path_payload(args, path)}
	result = await dispatch(msg, args)  # {success, results, count}（_shape 保证，dispatch 内 close）
	print(json.dumps(result, ensure_ascii=False))
	sys.exit(0 if result.get("success") else 1)
```

（原 `ws = await connect_and_handshake(args)` / `results = await send_and_recv_batch(...)` / `aggregated = {...}` / `await ws.close()` 全删——dispatch 内部处理连接生命周期与收齐 shaping。）

- [ ] **Step 5: 改 `main` 加 `--serve`/`--stop` 分流 + argparse**

在 `main()` 的 argparse 段（:565 附近）加：

```python
	p.add_argument("--serve", action="store_true", help="启动 daemon 常驻模式（后台保 WS，CLI 复用）")
	p.add_argument("--stop", action="store_true", help="停止 daemon")
```

在 `main()` 的分流段（:590 附近，`if args.selftest:` 之前）加：

```python
	if args.serve:
		asyncio.run(serve(args)); return
	if args.stop:
		asyncio.run(run_stop(args)); return
```

- [ ] **Step 6: 跑测试确认 GREEN + 零回归**

Run: `cd D:/GitHub/godot-asset-forge && python -m pytest tests/ -v 2>&1 | tail -10`
Expected: 15 PASS（Task 1/2 的 11 + Task 3 的 4）+ 既有 `test_forge_client_predict.py` 全 PASS（predict 函数零改动）。

Run: `cd D:/GitHub/godot-asset-forge && python -u tools/forge_client.py --help 2>&1 | grep -E "serve|stop"`
Expected: 看到 `--serve` / `--stop` 帮助行。

- [ ] **Step 7: Commit**

```bash
git add tools/forge_client.py tests/test_forge_client_daemon.py
git commit -m "feat: v8 CLI dispatch + daemon 启停 + run_* 改用 dispatch

- dispatch：daemon 在 IPC 转发 / 不在直连回退 + maybe_start_daemon（零回归）
- _try_daemon：连 60651 超时 200ms，失败返 None 触发回退
- maybe_start_daemon：Popen + 日志文件 truncate-on-start + CREATE_NO_WINDOW + stdin=DEVNULL
- run_stop：发 {type:stop} 给 daemon（复用 IPC 通道）
- run_generate/undo/batch/path 改用 dispatch（输出逐 type 镜像不变，\$? 由 CLI 算）
- main：--serve 进 daemon / --stop 停 daemon / selftest 保持直连
- 4 新 pytest PASS（_try_daemon 在/不在 + dispatch 回退 + stdio 三件套）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 完成后验证（Step 8 编辑器端到端手测，补 v8 闭环）

逻辑层已由 pytest 15 断言覆盖（收齐/shaping/串行/转发/回退/启停）。**端到端收益**需编辑器实测（同 v7 占比层）：

1. 启动编辑器（`"D:/godot/Godot_v4.6.3-stable_win64_console.exe" --path D:/GitHub/godot-asset-forge -e res://Demo.tscn`），等插件就绪（token + 60650 监听）
2. 首条命令（启动 daemon）：
   ```bash
   python tools/forge_client.py fence --path '[[0,0,0],[32,0,0]]' --count 64 --mode continuous
   ```
   预期：~600ms（= 现状，首条直连 + 启 daemon），输出 `{success,results,count}` 与现状逐字节一致
3. 连续 9 条命令（命中 daemon）：
   ```bash
   for i in $(seq 1 9); do
     python tools/forge_client.py box --pos $((i*2)) 0 0
   done
   ```
   预期：每条 ~40ms（IPC 30ms + server 7ms），**总 ~0.4s vs 现状 9×600ms=5.4s**
4. 停 daemon：`python tools/forge_client.py --stop`，预期 daemon 退出（60651 释放）
5. 自测零回归：`python tools/forge_client.py --selftest`（不经 daemon，直连，应与 v7 一致）

**预期**：连续多条命令端到端从 N×600ms 降到 600ms + (N-1)×40ms（首条启 daemon，后续命中）；输出格式逐字节不变；selftest/单条命令零回归。

**实测结论（2026-07-07 Step 8 已跑）**：预期**高估**——把「省 handshake」误当「省 python 启动」。实测 box 单件：v8 前 ~307ms/条（python 启动 ~150 + handshake ~150 + server ~7），v8 后 daemon 命中 ~174ms/条（python ~150 + IPC + server ~7）。**真实收益 = 省 handshake ~133ms/条（命中后 1.8x），连续 10 条 ~1.4x（非估算 6x）**。python 启动（~150-300ms）仍是单条命令大头，v8 没省（CLI 每次新 python 进程）。要真达 6x 需 CLI 常驻（v9 候选）。另发现 `--stop` 退出延迟 3-5s（`serve` 循环 `sleep(1)` 间隔 + 端口异步释放，功能 OK 感知慢，v8.1 候选优化）。功能正确：daemon 转发 + 输出逐字节不变 + 35 测试零回归 + `--stop` 最终退出。

## 守不变量自检清单（实施时逐条对）

- [ ] generate/undo 输出 = 单条原始 result（无 results/count）
- [ ] batch 输出 = `{success,results}`（无 count）
- [ ] path 输出 = `{success,results,count}`
- [ ] `$?` = CLI 据 success 算（非 daemon 退）
- [ ] daemon 串行（asyncio.Lock，并发请求排队）
- [ ] DAEMON_IDLE_TIMEOUT=60 < server 120s
- [ ] daemon 不可用 → CLI 直连回退（输出 = 现状）
- [ ] selftest 不经 daemon（直连）
- [ ] Windows Popen：日志文件 + CREATE_NO_WINDOW + stdin=DEVNULL
