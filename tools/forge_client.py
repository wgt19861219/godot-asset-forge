#!/usr/bin/env python3
"""Asset Forge bash 客户端：发 JSON 指令到 Godot 编辑器内的插件。

用法：
  python tools/forge_client.py box --size 2 1.5 1.2 --mat wood --name crate_01 --pos 0 0 0
  python tools/forge_client.py cylinder --height 1 --radius 0.5
  python tools/forge_client.py undo
  python tools/forge_client.py batch box cylinder cone          # 位置参数（每项 {"shape":<name>}）
  python tools/forge_client.py batch --items '[{"shape":"box","name":"a"},{"shape":"cone"}]'
  python tools/forge_client.py --selftest
"""
import argparse
import asyncio
import json
import math
import os
import sys
from pathlib import Path

try:
    import websockets
except ImportError:
    print("缺少 websockets 库：pip install websockets", file=sys.stderr)
    sys.exit(2)

WS_URL = "ws://127.0.0.1:60650"
DEFAULT_USER_DIR = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata", "godot-asset-forge")
TOKEN_FILENAME = "asset_forge.token"

# 与 tests/test_asset_factory.gd 的 shapes 名逐字一致
SHAPES_11 = ["box", "cylinder", "sphere", "prism", "wall", "ramp", "cone", "tube", "torus", "stairs", "fence"]


def predict_n(path, spacing, count, include_endpoints, mode="discrete", align_vertices=False):
    """与 PathGenerator._distances/_sample_continuous 镜像（ε=1e-4 同步约定）。
    v4 align_vertices：每折线段 floor(seg/spacing)+(余数>eps?1:0) 之和。"""
    total = sum(_dist(p0, p1) for p0, p1 in zip(path, path[1:]))
    eps = 1e-4
    if align_vertices and mode == "continuous" and spacing and spacing > 0:
        # v4 va：每折线段独立按 spacing 切 + 短尾
        n = 0
        for p0, p1 in zip(path, path[1:]):
            seg = _dist(p0, p1)
            if seg < eps:
                continue  # 零长折线段贡献 0
            full = int(seg // spacing)
            n += full
            if seg - full * spacing > eps:
                n += 1  # 短尾段
        return n
    if spacing and spacing > 0:
        distances = []
        d = 0.0
        while d <= total + eps:
            distances.append(d)
            d += spacing
        if include_endpoints and (total - distances[-1]) > eps:
            distances.append(total)
        n = len(distances)
        if mode == "continuous":
            n = max(0, n - 1)
        return n
    elif count and count >= 1:
        return count
    return 0


def _dist(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def resolve_token_path(args):
    if args.godot_user_dir:
        return Path(args.godot_user_dir) / TOKEN_FILENAME
    env = os.environ.get("GODOT_USER_DIR")
    if env:
        return Path(env) / TOKEN_FILENAME
    return Path(DEFAULT_USER_DIR) / TOKEN_FILENAME


def read_token(args):
    p = resolve_token_path(args)
    if not p.exists():
        print(f"token 文件不存在: {p}\n（先开 Godot 编辑器启用 Asset Forge，或用 --godot-user-dir / GODOT_USER_DIR 指定）", file=sys.stderr)
        sys.exit(3)
    return p.read_text(encoding="utf-8").strip()


async def send_and_recv(ws, msg, timeout=30.0):
    await ws.send(json.dumps(msg, ensure_ascii=False))
    while True:
        # A-5：单次 recv 超时，防止 server 静默丢消息（如非 dict JSON）时 while True 死循环
        try:
            data = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        except asyncio.TimeoutError:
            print(f"等待 server 响应超时（{timeout}s 无消息），id={msg.get('id')}", file=sys.stderr)
            sys.exit(5)
        if data.get("type") == "generate_result" and data.get("id") == msg.get("id"):
            return data


async def send_and_recv_batch(ws, msg, n=None):
    """发 1 条，收齐 per-item result。
    n=None（D 方案，generate_path）：靠 result 第一条的 total 收齐。
    n 给定（v1/v2 batch 兼容）：按 n 收齐。
    success=false（fatal error）：立即退出（不等 total/n）。
    """
    await ws.send(json.dumps(msg, ensure_ascii=False))
    req_id = msg.get("id")
    results = []
    total = n  # caller 传 n 则用 n（batch 兼容）；None 则靠 server total
    while True:
        try:
            data = json.loads(await asyncio.wait_for(ws.recv(), timeout=30.0))
        except asyncio.TimeoutError:
            print(
                f"等待 server 响应超时（30s 无消息），已收 {len(results)}/{total}",
                file=sys.stderr,
            )
            sys.exit(5)
        if (
            data.get("type") == "generate_result"
            and data.get("id") == req_id
        ):
            results.append(data)
            # fatal error（success=false）→ 立即退出（不等 total/n）
            if data.get("success") is False:
                break
            # 第一条读 server total（D 方案）
            if total is None:
                total = data.get("total")
            if total is not None and len(results) >= int(total):
                break
    return results


async def connect_and_handshake(args):
    ws = await websockets.connect(WS_URL)
    token = read_token(args)
    await ws.send(json.dumps({"type": "handshake", "payload": {"client": "forge_client", "version": "1.0.0", "token": token}}))
    while True:
        # A-5：单次 recv 超时，防 server 未响应 handshake 时 while 死循环
        try:
            data = json.loads(await asyncio.wait_for(ws.recv(), timeout=30.0))
        except asyncio.TimeoutError:
            print("等待 handshake_ack 超时（30s 无消息）", file=sys.stderr)
            sys.exit(5)
        if data.get("type") == "handshake_ack":
            return ws
        if data.get("error") == "unauthorized":
            print("鉴权失败：token 不符", file=sys.stderr)
            sys.exit(4)


def build_payload(args):
    payload = {"shape": args.shape}
    if args.name:
        payload["name"] = args.name
    if args.mat:
        if args.mat.startswith("{"):
            try:
                payload["material"] = json.loads(args.mat)  # A-6：畸形 JSON 友好报错而非 traceback
            except json.JSONDecodeError as e:
                print(f"--mat JSON 解析失败: {e}", file=sys.stderr)
                sys.exit(2)
        else:
            payload["material"] = args.mat
    transform = {}
    if args.pos:
        transform["position"] = list(args.pos)
    if args.rot:
        transform["rotation_deg"] = list(args.rot)
    if args.scale:
        transform["scale"] = list(args.scale)
    if transform:
        payload["transform"] = transform
    if args.parent:
        payload["parent"] = args.parent
    if args.save:
        payload["save"] = True
    params = {}
    if args.size:
        params["size"] = list(args.size)
    if args.radius is not None:
        params["radius"] = args.radius
    if args.height is not None:
        params["height"] = args.height
    if args.thickness is not None:
        params["thickness"] = args.thickness
    if params:
        payload["params"] = params
    return payload


async def run_generate(args):
    ws = await connect_and_handshake(args)
    result = await send_and_recv(ws, {"type": "generate", "id": "req_1", "payload": build_payload(args)})
    print(json.dumps(result, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if result.get("success") else 1)


async def run_undo(args):
    ws = await connect_and_handshake(args)
    result = await send_and_recv(ws, {"type": "undo_last", "id": "undo_1"})
    print(json.dumps(result, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if result.get("success") else 1)


async def run_batch(args):
    """构造 items（--items JSON 字符串，或 batch shape1 shape2 ... 位置参数），
    发 generate_batch，收齐 n 条 per-item 散 result，打印聚合 JSON。"""
    items = []
    # 优先 --items JSON 字符串
    if args.items:
        try:
            parsed = json.loads(args.items)
            if not isinstance(parsed, list):
                print("--items 必须是 JSON 数组", file=sys.stderr)
                sys.exit(2)
            items = parsed
        except json.JSONDecodeError as e:
            print(f"--items JSON 解析失败: {e}", file=sys.stderr)
            sys.exit(2)
    # 位置参数：每个 shape 名展开为 {"shape": <name>}
    elif args.batch_shapes:
        for s in args.batch_shapes:
            items.append({"shape": s})
    else:
        print("batch 需要 --items '<json>' 或位置参数 shape 名", file=sys.stderr)
        sys.exit(2)

    n = len(items)
    ws = await connect_and_handshake(args)
    results = await send_and_recv_batch(ws, {"type": "generate_batch", "id": "r_batch", "items": items}, n)
    all_ok = all(bool(r.get("success")) for r in results)
    # 聚合输出（client 侧聚合，server 不返单条聚合体，2026-07-04 Q7 宽松化）
    aggregated = {"success": all_ok, "results": results}
    print(json.dumps(aggregated, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if all_ok else 1)


def _parse_path_arg(args):
    """从 --path JSON 或 --path-file 读 path 数组，失败 → None（已打印错误）。"""
    import json as _json
    raw = None
    if args.path is not None:
        try:
            raw = _json.loads(args.path)
        except _json.JSONDecodeError as e:
            print(f"--path JSON 解析失败: {e}", file=sys.stderr)
            return None
    elif args.path_file is not None:
        try:
            raw = _json.loads(Path(args.path_file).read_text(encoding="utf-8"))
        except (OSError, _json.JSONDecodeError) as e:
            print(f"--path-file 读取/解析失败: {e}", file=sys.stderr)
            return None
    if not isinstance(raw, list) or len(raw) < 2:
        print("--path 必须是 ≥2 个点的 JSON 数组", file=sys.stderr)
        return None
    return raw


def build_path_payload(args, path):
    # path 子命令模式：`path <shape> --path ...` 时 args.shape=="path"，真实 shape 在 batch_shapes[0]
    shape_name = args.shape
    if shape_name == "path" and args.batch_shapes:
        shape_name = args.batch_shapes[0]
    payload = {"shape": shape_name}
    if args.path_node is not None:
        payload["path_node"] = args.path_node
    elif path is not None:
        payload["path"] = path
    # path/path_file/path_node 三互斥在 run_path 已校验，这里只构造
    if args.name:
        payload["name"] = args.name
    if args.mat:
        if args.mat.startswith("{"):
            try:
                payload["material"] = json.loads(args.mat)
            except json.JSONDecodeError as e:
                print(f"--mat JSON 解析失败: {e}", file=sys.stderr)
                sys.exit(2)
        else:
            payload["material"] = args.mat
    if args.spacing is not None:
        payload["spacing"] = args.spacing
    if args.count is not None:
        payload["count"] = args.count
    if args.align != "path":
        payload["align"] = args.align
    if args.no_endpoints:
        payload["include_endpoints"] = False
    if args.mode != "discrete":
        payload["mode"] = args.mode
    if args.align_vertices:
        payload["align_vertices"] = True
    if args.parent:
        payload["parent"] = args.parent
    if args.save:
        payload["save"] = True
    params = {}
    if args.size:
        params["size"] = list(args.size)
    if args.radius is not None:
        params["radius"] = args.radius
    if args.height is not None:
        params["height"] = args.height
    if args.thickness is not None:
        params["thickness"] = args.thickness
    if params:
        payload["params"] = params
    return payload


async def run_path(args):
    """path 阵列：path JSON 或 path_node（Path3D 节点）。
    D 方案：n=None 靠 server result 的 total 收齐（predict_n 仅 path 模式预校验）。"""
    # path 源解析 + 三互斥校验
    path_sources = [args.path, args.path_file, args.path_node]
    if sum(1 for s in path_sources if s is not None) > 1:
        print("--path / --path-file / --path-node 三互斥", file=sys.stderr)
        sys.exit(2)
    if args.path_node is not None:
        path = None  # path_node 模式，client 不知曲线长
    else:
        path = _parse_path_arg(args)
        if path is None:
            sys.exit(2)

    spacing = args.spacing if args.spacing is not None else 0.0
    count = args.count if args.count is not None else 0
    include_endpoints = not args.no_endpoints

    # predict_n 仅 path 模式预校验（path_node 模式 client 不知 total_len，跳过，靠 server total）
    if path is not None:
        n = predict_n(path, spacing, count, include_endpoints, args.mode, args.align_vertices)
        if n == 0:
            print(
                "path 参数错误：需 --spacing >0 或 --count >=1（且二选一）",
                file=sys.stderr,
            )
            sys.exit(2)
        if n > 64:
            print(
                f"采样点 {n} 超过 BATCH_LIMIT 64（缩短路径/增大 spacing/减少 count）",
                file=sys.stderr,
            )
            sys.exit(2)

    ws = await connect_and_handshake(args)
    payload = build_path_payload(args, path)
    # D 方案：n=None，靠 server result 的 total 字段收齐
    results = await send_and_recv_batch(
        ws, {"type": "generate_path", "id": "r_path", "payload": payload}, n=None
    )
    all_ok = all(bool(r.get("success")) for r in results)
    aggregated = {"success": all_ok, "results": results, "count": len(results)}
    print(json.dumps(aggregated, ensure_ascii=False))
    await ws.close()
    sys.exit(0 if all_ok else 1)


async def run_selftest(args):
    ws = await connect_and_handshake(args)
    all_ok = True
    for shape in SHAPES_11:
        result = await send_and_recv(ws, {"type": "generate", "id": f"st_{shape}", "payload": {"shape": shape, "name": f"st_{shape}"}})
        ok = bool(result.get("success"))
        all_ok = all_ok and ok
        print(f"{'PASS' if ok else 'FAIL'}  {shape}: {result.get('error', result.get('node_path', ''))}")
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_undo"})
    ok = bool(result.get("success"))
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  undo_last")
    # generate_path（路径阵列，3 个采样点 → 3 条 per-point result）
    path_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_path",
            "payload": {
                "shape": "cylinder",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "material": "metal",
                "name": "st_path",
            },
        },
        3,
    )
    ok = len(path_results) == 3 and all(bool(r.get("success")) for r in path_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path（{len(path_results)}/3 result）")
    # undo 掉 path 生成的 3 个节点（同 batch_id，原子）
    # 服务端 undo 回执把 freed 数放在 message 字段（"freed N"），需解析
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_path_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path undo（freed 3）")
    # generate_path continuous（wall 沿 L 路径铺满，N 段 → N 条 per-point result）
    cont_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_cont",
            "payload": {
                "shape": "wall",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "material": "stone",
                "name": "st_cont",
            },
        },
        3,
    )
    ok = len(cont_results) == 3 and all(bool(r.get("success")) for r in cont_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous（{len(cont_results)}/3 result）")
    # undo continuous（同 batch_id 原子弹 3 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_cont_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous undo（freed 3）")
    # v4 generate_path continuous + align_vertices（L 路径 spacing=3 → 4 段，顶点对齐）
    va_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_va",
            "payload": {
                "shape": "wall",
                "path": [[0, 0, 0], [4, 0, 0], [4, 0, 4]],
                "spacing": 3,
                "mode": "continuous",
                "align_vertices": True,
                "material": "stone",
                "name": "st_va",
            },
        },
        4,
    )
    ok = len(va_results) == 4 and all(bool(r.get("success")) for r in va_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous + align_vertices（{len(va_results)}/4 result）")
    # undo va（同 batch_id 原子弹 4 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_va_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 4
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path va undo（freed 4）")
    # v5 generate_path continuous + fence（L 路径 count=3，端柱共享注入 start_post/end_post）
    fence_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v5_fence",
            "payload": {
                "shape": "fence",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "material": "wood",
                "name": "st_v5_fence",
            },
        },
        3,
    )
    ok = len(fence_results) == 3 and all(bool(r.get("success")) for r in fence_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous fence（{len(fence_results)}/3 result）")
    # undo continuous fence（同 batch_id 原子弹 3 段）
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v5_fence_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous fence undo（freed 3）")
    # v5 generate_path continuous + ramp（直线 count=3，验证白名单放行；接缝高度台阶属已知局限不断言）
    ramp_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v5_ramp",
            "payload": {
                "shape": "ramp",
                "path": [[0, 0, 0], [3, 0, 0]],
                "count": 3,
                "mode": "continuous",
                "material": "stone",
                "name": "st_v5_ramp",
            },
        },
        3,
    )
    ok = len(ramp_results) == 3 and all(bool(r.get("success")) for r in ramp_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp（{len(ramp_results)}/3 result）")
    # undo continuous ramp
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v5_ramp_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp undo（freed 3）")
    # v6 generate_path continuous + ramp（L 路径 count=3，高度衔接，验证折线弧长分配）
    ramp_v6_results = await send_and_recv_batch(
        ws,
        {
            "type": "generate_path",
            "id": "st_v6_ramp",
            "payload": {
                "shape": "ramp",
                "path": [[0, 0, 0], [3, 0, 0], [3, 0, 3]],
                "count": 3,
                "mode": "continuous",
                "height": 2,
                "material": "stone",
                "name": "st_v6_ramp",
            },
        },
        3,
    )
    ok = len(ramp_v6_results) == 3 and all(bool(r.get("success")) for r in ramp_v6_results)
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp v6（{len(ramp_v6_results)}/3 result，L 路径高度衔接）")
    # undo continuous ramp v6
    result = await send_and_recv(ws, {"type": "undo_last", "id": "st_v6_ramp_undo"})
    msg = str(result.get("message", ""))
    freed_n = int(msg.split()[-1]) if msg.startswith("freed ") and msg.split()[-1].isdigit() else -1
    ok = bool(result.get("success")) and freed_n == 3
    all_ok = all_ok and ok
    print(f"{'PASS' if ok else 'FAIL'}  generate_path continuous ramp v6 undo（freed 3）")
    await ws.close()
    sys.exit(0 if all_ok else 1)


def main():
    p = argparse.ArgumentParser(description="Asset Forge bash 客户端")
    # batch 子命令支持：batch shape1 shape2 ... 位置参数（nargs="*"），与单 shape 互斥
    p.add_argument("shape", nargs="?", help="shape 名，或 undo，或 batch（接多个 shape 名），或省略走 --selftest")
    p.add_argument("batch_shapes", nargs="*", help="batch 子命令的 shape 列表（仅 shape=='batch' 时生效）")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--items", default=None, help="batch 模式：JSON 数组字符串，如 '[{\"shape\":\"box\"},{\"shape\":\"cone\"}]'")
    p.add_argument("--name", default=None)
    p.add_argument("--mat", default=None, help="材质：预设名 / {json} / res://路径")
    p.add_argument("--pos", nargs=3, type=float, default=None, metavar=("X", "Y", "Z"))
    p.add_argument("--rot", nargs=3, type=float, default=None, metavar=("X", "Y", "Z"))
    p.add_argument("--scale", nargs=3, type=float, default=None, metavar=("X", "Y", "Z"))
    p.add_argument("--parent", default=None)
    p.add_argument("--save", action="store_true")
    p.add_argument("--size", nargs=3, type=float, default=None)
    p.add_argument("--radius", type=float, default=None)
    p.add_argument("--height", type=float, default=None)
    p.add_argument("--thickness", type=float, default=None)
    p.add_argument("--godot-user-dir", default=None, help="Godot user:// 绝对路径（覆盖 env/默认）")
    # path 子命令参数
    p.add_argument("--path", default=None, help='path 模式：JSON 数组 [[x,y,z],...] 如 \'[[0,0,0],[3,0,0]]\'')
    p.add_argument("--path-file", default=None, help="path 模式：从文件读 path JSON（每点一行或 JSON 数组）")
    p.add_argument("--spacing", type=float, default=None, help="path 模式：等间距采样（与 --count 互斥）")
    p.add_argument("--count", type=int, default=None, help="path 模式：等数量采样（与 --spacing 互斥）")
    p.add_argument("--align", default="path", choices=["none", "path", "normal"], help="path 模式：朝向（默认 path）")
    p.add_argument("--no-endpoints", action="store_true", help="path 模式：不含端点（默认含）")
    p.add_argument(
        "--path-node",
        default=None,
        help="path 模式：场景里 Path3D 节点路径（如 /Root/MyPath），与 --path/--path-file 三互斥",
    )
    p.add_argument(
        "--mode",
        default="discrete",
        choices=["discrete", "continuous"],
        help="path 模式：discrete（默认，等间距独立物件）/ continuous（栏板铺满）",
    )
    p.add_argument(
        "--align-vertices",
        action="store_true",
        help="path 模式 continuous：顶点对齐分段（顶点=段边界，转角不切角），仅 continuous+spacing",
    )
    args = p.parse_args()
    if args.selftest:
        asyncio.run(run_selftest(args)); return
    if args.shape == "undo":
        asyncio.run(run_undo(args)); return
    if args.shape == "batch":
        asyncio.run(run_batch(args)); return
    if args.path is not None or args.path_file is not None or args.path_node is not None:
        asyncio.run(run_path(args)); return
    if not args.shape:
        p.error("需指定 shape，或 batch <shapes...>，或 undo，或 --selftest")
    asyncio.run(run_generate(args))


if __name__ == "__main__":
    main()
