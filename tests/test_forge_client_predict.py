"""forge_client.predict_n 与 GDScript PathGenerator.sample().size() parity（F2 同步约定）。
基准来自 tests/test_path_generator.gd 的 parity 断言。"""
import math
import sys
from pathlib import Path

# 让 tests/ 能 import tools/forge_client.py
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
from forge_client import predict_n  # noqa: E402


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
