"""forge_client.predict_n 与 GDScript PathGenerator.sample().size() parity（F2 同步约定）。
基准来自 tests/test_path_generator.gd 的 parity 断言。"""
import asyncio
import math
import sys
from pathlib import Path

# 让 tests/ 能 import tools/forge_client.py
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
from forge_client import predict_n, send_and_recv_batch  # noqa: E402


def _dist(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def test_spacing_endpoints_exact_divisible():
    # spacing=1, total=4, endpoints → [0,1,2,3,4] = 5（与 GDScript parity 一致）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True) == 5


def test_spacing_endpoints_nondivisible():
    # spacing=3, total=4, endpoints → [0,3,4] = 3（补尾点）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, True) == 3


def test_spacing_no_endpoints():
    # spacing=3, total=4, no endpoints → [0,3] = 2
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, False) == 2


def test_spacing_endpoints_total_multiple():
    # spacing=2, total=4, endpoints → [0,2,4] = 3（整除，不补）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 2.0, 0, True) == 3


def test_count_mode():
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 0.0, 5, True) == 5
    assert predict_n(line, 0.0, 1, False) == 1


def test_multi_segment():
    # L 形 total=2，spacing=1，endpoints → [0,1,2] = 3
    L = [[0, 0, 0], [1, 0, 0], [1, 0, 1]]
    assert predict_n(L, 1.0, 0, True) == 3


def test_continuous_count_unchanged():
    # count 模式 continuous = N（同 v1）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 0.0, 5, True, "continuous") == 5


def test_continuous_spacing_minus_one():
    # spacing 模式 continuous = v1 点数 - 1（v1=5 点 → 4 段）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True, "continuous") == 4


def test_continuous_spacing_no_endpoints():
    # v1 spacing=3 no endpoints = [0,3] = 2 点 → continuous = 1 段
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 3.0, 0, False, "continuous") == 1


def test_discrete_default_mode_zero_regression():
    # 不传 mode，默认 discrete = v1 行为（v1 6 pytest 零回归）
    line = [[0, 0, 0], [4, 0, 0]]
    assert predict_n(line, 1.0, 0, True) == 5
    assert predict_n(line, 0.0, 5, True) == 5


def test_continuous_multi_segment():
    # L 形 total=2，spacing=1 endpoints → v1 3 点 → continuous 2 段
    L = [[0, 0, 0], [1, 0, 0], [1, 0, 1]]
    assert predict_n(L, 1.0, 0, True, "continuous") == 2


class _FakeWS:
    """模拟 WebSocketPeer：按预置消息序列返回，记录 send 的消息。"""
    def __init__(self, responses):
        self._responses = list(responses)
        self.sent = []

    async def send(self, raw):
        self.sent.append(raw)

    async def recv(self):
        await asyncio.sleep(0)
        return self._responses.pop(0)


def test_send_and_recv_batch_by_total():
    """n=None：靠 result 第一条的 total 收齐（D 方案，path_node 模式）。"""
    msgs = [
        '{"type":"generate_result","id":"r","success":true,"node_path":"/a","total":3}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/b","total":3}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/c","total":3}',
    ]
    ws = _FakeWS([m.encode() for m in msgs])
    results = asyncio.run(send_and_recv_batch(ws, {"type": "generate_path", "id": "r"}, n=None))
    assert len(results) == 3
    assert all(r["success"] for r in results)


def test_send_and_recv_batch_n_compatible():
    """n 传了：按 n 收齐（v1/v2 batch 兼容，result 不带 total）。"""
    msgs = [
        '{"type":"generate_result","id":"r","success":true,"node_path":"/a"}',
        '{"type":"generate_result","id":"r","success":true,"node_path":"/b"}',
    ]
    ws = _FakeWS([m.encode() for m in msgs])
    results = asyncio.run(send_and_recv_batch(ws, {"type": "generate_batch", "id": "r"}, n=2))
    assert len(results) == 2
