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


async def send_and_recv(ws, msg):
    await ws.send(json.dumps(msg, ensure_ascii=False))
    while True:
        data = json.loads(await ws.recv())
        if data.get("type") == "generate_result" and data.get("id") == msg.get("id"):
            return data


async def send_and_recv_batch(ws, msg, n):
    """batch 专用：发 generate_batch，收齐 n 条同 req_id 的 generate_result。

    server 对 batch 的每个 item 独立 emit 一条 generate_result（共享 req_id，
    2026-07-04 Q7 宽松化），client 按 id 收齐 n 条后聚合。n = items 数。
    """
    await ws.send(json.dumps(msg, ensure_ascii=False))
    req_id = msg.get("id")
    results = []
    while len(results) < n:
        data = json.loads(await ws.recv())
        if data.get("type") == "generate_result" and data.get("id") == req_id:
            results.append(data)
    return results


async def connect_and_handshake(args):
    ws = await websockets.connect(WS_URL)
    token = read_token(args)
    await ws.send(json.dumps({"type": "handshake", "payload": {"client": "forge_client", "version": "1.0.0", "token": token}}))
    while True:
        data = json.loads(await ws.recv())
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
        payload["material"] = json.loads(args.mat) if args.mat.startswith("{") else args.mat
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
    args = p.parse_args()
    if args.selftest:
        asyncio.run(run_selftest(args)); return
    if args.shape == "undo":
        asyncio.run(run_undo(args)); return
    if args.shape == "batch":
        asyncio.run(run_batch(args)); return
    if not args.shape:
        p.error("需指定 shape，或 batch <shapes...>，或 undo，或 --selftest")
    asyncio.run(run_generate(args))


if __name__ == "__main__":
    main()
