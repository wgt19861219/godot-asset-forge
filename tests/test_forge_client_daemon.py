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
    async def close(self):
        pass  # mock websockets 协议契约（真实连接对象有 close）


# 导入被测函数（forge_client 在 tools/）
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from forge_client import _collect, _shape


def test_collect_generate_single():
    """generate：send_and_recv 单条，返 [单条 result]。"""
    ws = FakeWS([{"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_0"}])
    msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 1
    assert results[0]["node_path"] == "/Root/box_0"
    assert ws.sent[0]["type"] == "generate"
    assert len(ws.sent) == 1  # 锁死单 send 不变量


def test_collect_undo_single():
    """undo_last：单条 result。"""
    ws = FakeWS([{"type": "generate_result", "id": "undo_1", "success": True}])
    msg = {"type": "undo_last", "id": "undo_1"}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 1
    assert len(ws.sent) == 1  # 锁死单 send 不变量


def test_collect_batch_by_n():
    """generate_batch：send_and_recv_batch 按 n 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_batch", "success": True},
        {"type": "generate_result", "id": "r_batch", "success": True},
        {"type": "generate_result", "id": "r_batch", "success": True},
    ])
    msg = {"type": "generate_batch", "id": "r_batch", "items": [{"shape": "box"}, {"shape": "wall"}, {"shape": "ramp"}]}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 3
    assert len(ws.sent) == 1  # 锁死单 send 不变量


def test_collect_path_by_total():
    """generate_path：send_and_recv_batch n=None 靠 total 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
    ])
    msg = {"type": "generate_path", "id": "r_path", "payload": {"shape": "fence"}}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 2
    assert len(ws.sent) == 1  # 锁死单 send 不变量


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


def test_shape_unknown_type():
    """unknown_type：兜底返 unknown_type error（保留兜底 + 覆盖）。"""
    msg = {"type": "bogus"}
    results = [{"success": True}]
    shaped = _shape(msg, results)
    assert shaped == {"success": False, "error": "unknown_type"}


# === v8 Task 2：daemon serve + _handle_cli 集成测（mock connect_and_handshake + 真 socket 连 daemon）===
from unittest.mock import patch
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
    """daemon 转发 generate → 透传单条 result（无 results/count 包装，守不变量 #1）。
    daemon 镜像直连 run_generate：透传 server 原始字段（type/id/success/node_path），不加包装。"""
    responses = [{"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_0"}]
    cli_responses = asyncio.new_event_loop().run_until_complete(_start_daemon_with_mock_server(responses))
    assert len(cli_responses) == 1
    assert cli_responses[0]["success"] is True
    assert cli_responses[0]["node_path"] == "/Root/box_0"
    assert "results" not in cli_responses[0]  # 单条，无聚合包装
    assert "count" not in cli_responses[0]


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
    asyncio.new_event_loop().run_until_complete(run())


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
    asyncio.new_event_loop().run_until_complete(run())


# === v8 Task 3：dispatch（daemon 在转发 / 不在直连回退 + 启 daemon）+ stdio 三件套 ===
from forge_client import dispatch, _try_daemon, maybe_start_daemon, run_stop


def test_try_daemon_returns_none_when_not_running():
    """daemon 没起 → _try_daemon 返 None（触发回退）。"""
    msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
    result = asyncio.new_event_loop().run_until_complete(_try_daemon(msg))
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
    asyncio.new_event_loop().run_until_complete(run())


def test_dispatch_falls_back_to_direct_when_no_daemon():
    """daemon 不在 → dispatch 直连 server（mock connect_and_handshake + _collect）。
    _shape 对 generate 透传单条原始 result（守不变量 #1）。"""
    async def run():
        # FakeWS 响应即期望输出（_shape 透传 results[0]，type/id 也透传）
        expected = {"success": True, "node_path": "/Root/box_1"}
        fake_ws = FakeWS([{"type": "generate_result", "id": "req_1", **expected}])
        started = []
        async def fake_handshake(args):
            return fake_ws
        def fake_start(args):
            started.append(args)  # 记录是否触发启 daemon
        msg = {"type": "generate", "id": "req_1", "payload": {"shape": "box"}}
        with patch("forge_client.connect_and_handshake", new=fake_handshake), \
             patch("forge_client.maybe_start_daemon", new=fake_start):
            result = await dispatch(msg, _make_args())
        # _shape 透传单条原始 result（含 type/id）
        assert result["success"] is True
        assert result["node_path"] == "/Root/box_1"
        assert len(started) == 1  # 回退时触发了启 daemon
    asyncio.new_event_loop().run_until_complete(run())


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
