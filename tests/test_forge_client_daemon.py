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
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 1
    assert results[0]["node_path"] == "/Root/box_0"
    assert ws.sent[0]["type"] == "generate"


def test_collect_undo_single():
    """undo_last：单条 result。"""
    ws = FakeWS([{"type": "generate_result", "id": "undo_1", "success": True}])
    msg = {"type": "undo_last", "id": "undo_1"}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 1


def test_collect_batch_by_n():
    """generate_batch：send_and_recv_batch 按 n 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
        {"type": "generate_result", "id": "r_batch", "success": True, "total": 3},
    ])
    msg = {"type": "generate_batch", "id": "r_batch", "items": [{"shape": "box"}, {"shape": "wall"}, {"shape": "ramp"}]}
    results = asyncio.run(_collect(ws, msg))
    assert len(results) == 3


def test_collect_path_by_total():
    """generate_path：send_and_recv_batch n=None 靠 total 收齐。"""
    ws = FakeWS([
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
        {"type": "generate_result", "id": "r_path", "success": True, "total": 2},
    ])
    msg = {"type": "generate_path", "id": "r_path", "payload": {"shape": "fence"}}
    results = asyncio.run(_collect(ws, msg))
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
