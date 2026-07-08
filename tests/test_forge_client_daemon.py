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


def test_serve_forward_failed_on_ws_closed():
    """P1#4 扩展（手测发现）：daemon 转发时 server WS 已关闭（send 抛 ConnectionClosedOK，
    websockets 异常不继承 OSError）→ daemon 应返 forward_failed resp，不杀 handler Task、CLI 收到错误。
    修复前：ConnectionClosedOK 不被 except SystemExit / except(OSError,...) 捕获 → unhandled → CLI 收不到 resp。"""
    from websockets.exceptions import ConnectionClosedOK

    class FakeWSClosed:
        """模拟 server 停止 → WS 正常关闭：send 抛 ConnectionClosedOK（对端 close 1000）。"""
        async def send(self, _text):
            raise ConnectionClosedOK(None, None)
        async def close(self):
            pass

    cli_responses = []

    async def run():
        async def fake_handshake(args):
            return FakeWSClosed()

        async def cli_task():
            await asyncio.sleep(0.3)  # 等 daemon 起来
            reader, writer = await asyncio.open_connection("127.0.0.1", DAEMON_PORT)
            writer.write(json.dumps({"type": "generate", "id": "req_1", "payload": {"shape": "box"}}).encode("utf-8"))
            await writer.drain()
            data = await asyncio.wait_for(reader.read(65536), timeout=5.0)
            cli_responses.append(json.loads(data.decode("utf-8")))
            writer.close()

        with patch("forge_client.connect_and_handshake", new=fake_handshake):
            serve_task = asyncio.create_task(serve(_make_args()))
            cli_task_obj = asyncio.create_task(cli_task())
            await asyncio.wait_for(cli_task_obj, timeout=6.0)
            serve_task.cancel()
            try:
                await serve_task
            except asyncio.CancelledError:
                pass

    asyncio.new_event_loop().run_until_complete(run())
    assert len(cli_responses) == 1, "CLI 应收到 forward_failed resp（修复前超时无响应）"
    assert cli_responses[0]["success"] is False
    assert cli_responses[0]["error"] == "forward_failed"


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
        # M-1：锁死 _shape 透传语义（type/id 也透传，不被吞）
        assert result["type"] == "generate_result"
        assert result["id"] == "req_1"
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


# === v8 Task 3 fix（I-1）：run_stop 集成测（daemon 在 / 不在）===
def test_run_stop_when_daemon_running(capsys):
    """daemon 在：run_stop 发 stop → stdout 含 stopped + SystemExit code 0。
    I-1：补 run_stop 集成测。启真假 daemon 监听 60651 回 {success,stopped}。"""
    async def run():
        async def fake_handle(reader, writer):
            await reader.read(65536)
            writer.write(json.dumps({"success": True, "stopped": True}).encode("utf-8"))
            await writer.drain()
        srv = await asyncio.start_server(fake_handle, "127.0.0.1", DAEMON_PORT)
        async with srv:
            with pytest.raises(SystemExit) as exc:
                await run_stop(_make_args())
            assert exc.value.code == 0
            captured = capsys.readouterr()
            assert "stopped" in captured.out
            assert "daemon_not_running" not in captured.err
    asyncio.new_event_loop().run_until_complete(run())


def test_run_stop_when_daemon_not_running(capsys):
    """daemon 不在：mock open_connection 抛 OSError → stderr 含 daemon_not_running + code 1。
    I-1：补 run_stop 集成测。用 mock 避免真连 60651（测试隔离）。"""
    async def fake_open_conn(*a, **kw):
        raise OSError("mock：daemon 不在")
    async def run():
        with patch("forge_client.asyncio.open_connection", new=fake_open_conn):
            with pytest.raises(SystemExit) as exc:
                await run_stop(_make_args())
        assert exc.value.code == 1
        captured = capsys.readouterr()
        assert "daemon_not_running" in captured.err
    asyncio.new_event_loop().run_until_complete(run())


# === v9 Task 1：_build_parser + _build_batch_items（DRY 重构 main/run_batch，零行为改变）===
import shlex
from forge_client import _build_parser, _build_batch_items


def _args(tokens):
    """shlex + _build_parser 解析 tokens → args（测试 helper）。"""
    return _build_parser().parse_args(tokens)


def test_build_parser_parses_generate():
    """_build_parser 解析 generate 命令（box + params）。"""
    args = _args(shlex.split("box --pos 1 2 3"))
    assert args.shape == "box"
    assert list(args.pos) == [1.0, 2.0, 3.0]


def test_build_parser_parses_path():
    """_build_parser 解析 path 子命令。"""
    args = _args(shlex.split("path fence --path '[[0,0,0],[10,0,0]]' --count 5 --mode continuous"))
    assert args.shape == "path"
    assert args.batch_shapes == ["fence"]
    assert args.count == 5
    assert args.mode == "continuous"


def test_build_batch_items_from_positional():
    """_build_batch_items 位置参数 → items 列表。"""
    args = _args(["batch", "box", "wall", "ramp"])
    items = _build_batch_items(args)
    assert items == [{"shape": "box"}, {"shape": "wall"}, {"shape": "ramp"}]


def test_build_batch_items_from_items_json():
    """_build_batch_items --items JSON → items。"""
    args = _args(["batch", "--items", '[{"shape":"box"},{"shape":"fence","params":{"length":3}}]'])
    items = _build_batch_items(args)
    assert items == [{"shape": "box"}, {"shape": "fence", "params": {"length": 3}}]


def test_build_batch_items_invalid_json_returns_none(capsys):
    """_build_batch_items --items 畸形 JSON → None（已打印错误，不 sys.exit）。"""
    args = _args(["batch", "--items", "{not json"])
    items = _build_batch_items(args)
    assert items is None
    assert "JSON" in capsys.readouterr().err  # 已打印 JSON 解析失败


def test_build_batch_items_not_list_returns_none(capsys):
    """_build_batch_items --items 非 array → None。"""
    args = _args(["batch", "--items", '{"shape":"box"}'])  # dict 非 list
    items = _build_batch_items(args)
    assert items is None


# === v9 Task 2: _parse_repl_line + run_repl ===
from forge_client import _parse_repl_line, run_repl


def test_parse_repl_line_exit():
    assert _parse_repl_line("exit") == "exit"
    assert _parse_repl_line("quit") == "exit"


def test_parse_repl_line_generate():
    msg = _parse_repl_line("box --pos 1 0 0")
    assert msg["type"] == "generate"
    assert msg["payload"]["shape"] == "box"


def test_parse_repl_line_undo():
    msg = _parse_repl_line("undo")
    assert msg["type"] == "undo_last"


def test_parse_repl_line_batch():
    msg = _parse_repl_line("batch box wall")
    assert msg["type"] == "generate_batch"
    assert msg["items"] == [{"shape": "box"}, {"shape": "wall"}]


def test_parse_repl_line_path():
    msg = _parse_repl_line("path fence --path '[[0,0,0],[10,0,0]]' --count 5 --mode continuous")
    assert msg["type"] == "generate_path"
    assert msg["payload"]["shape"] == "fence"
    assert msg["payload"]["count"] == 5


def test_parse_repl_line_path_mutual_exclusion(capsys):
    """I-1：--path / --path-file / --path-node 三互斥 → None（已提示，不退）。"""
    msg = _parse_repl_line("path fence --path '[[0,0,0],[3,0,0]]' --path-node /Root/MyPath")
    assert msg is None
    assert "三互斥" in capsys.readouterr().err


def test_parse_repl_line_mat_invalid_json_returns_none(capsys):
    """--mat 畸形 JSON → None（已提示，不抛、不退）。"""
    msg = _parse_repl_line("box --mat '{bad json'")
    assert msg is None


def test_parse_repl_line_rejects_selftest_serve_stop():
    """REPL 内禁 selftest/serve/stop（REPL 是命令循环，非进程控制）。"""
    assert _parse_repl_line("--selftest") is None
    assert _parse_repl_line("--serve") is None
    assert _parse_repl_line("--stop") is None


def test_run_repl_loop_multiple_commands_then_exit(capsys, monkeypatch):
    """run_repl 多命令循环 + exit 退（mock ws + input 序列）。"""
    fake_ws = FakeWS([
        {"type": "generate_result", "id": "req_1", "success": True, "node_path": "/Root/box_0"},
        {"type": "generate_result", "id": "undo_1", "success": True},
    ])
    async def fake_handshake(args):
        return fake_ws
    inputs = iter(["box --pos 0 0 0", "undo", "exit"])
    monkeypatch.setattr("builtins.input", lambda *a, **kw: next(inputs, "exit"))
    async def run():
        with patch("forge_client.connect_and_handshake", new=fake_handshake):
            await run_repl(_make_args())
    asyncio.new_event_loop().run_until_complete(run())
    out = capsys.readouterr().out
    assert '"success": true' in out or '"success":true' in out  # 两条命令都 print result
    assert fake_ws.sent[0]["type"] == "generate"


def test_run_repl_command_error_continues(capsys, monkeypatch):
    """单命令 --mat 畸形 → continue 不退（再敲 exit 退）。"""
    async def fake_handshake(args):
        return FakeWS([])
    import asyncio
    async def run():
        with patch("forge_client.connect_and_handshake", new=fake_handshake):
            inputs = iter(["box --mat '{bad'", "exit"])
            monkeypatch.setattr("builtins.input", lambda *a, **kw: next(inputs, "exit"))
            await run_repl(_make_args())
    asyncio.new_event_loop().run_until_complete(run())
    # 未崩（跑到 exit 退）


def test_run_repl_server_timeout_sysexit_swallowed(capsys, monkeypatch):
    """单命令 _collect 内 sys.exit(5)（模拟 send_and_recv 超时）→ try/except SystemExit 吞 → continue。"""
    async def fake_handshake(args):
        return FakeWS([])
    async def fake_collect(ws, msg):
        raise SystemExit(5)  # 模拟 send_and_recv 超时 sys.exit
    inputs = iter(["box --pos 0 0 0", "exit"])
    monkeypatch.setattr("builtins.input", lambda *a, **kw: next(inputs, "exit"))
    async def run():
        with patch("forge_client.connect_and_handshake", new=fake_handshake), \
            patch("forge_client._collect", new=fake_collect):
            await run_repl(_make_args())  # sys.exit 被吞，continue 到 exit，不崩
    asyncio.new_event_loop().run_until_complete(run())
    err = capsys.readouterr().err
    assert "超时" in err or "错误" in err  # 提示跳过


# === v9 Task 3：--repl argparse + main 分流 + 互斥 ===
def test_build_parser_has_repl_flag():
    """_build_parser 含 --repl 选项。"""
    args = _build_parser().parse_args(["--repl"])
    assert args.repl is True


def test_repl_mutually_exclusive_with_shape():
    """--repl 与 shape 位置参数互斥（main 校验 → exit 2 + 互斥消息）。"""
    import subprocess, sys
    # v9 M-6：cwd 相对化（os.path 跨环境），test 文件在 tests/ 下 → dirname 两次到项目根
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    r = subprocess.run([sys.executable, "-u", "tools/forge_client.py", "--repl", "box"],
        capture_output=True, text=True, cwd=project_root)
    assert r.returncode == 2
    assert "互斥" in r.stderr
