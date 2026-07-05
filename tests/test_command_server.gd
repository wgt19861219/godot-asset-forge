extends RefCounted
## command_server 协议层测试（handshake/token/generate/batch/undo，IMPORTANT-5）。
## 用 WebSocketPeer 自连本地 server。lambda 捕获用数组（避免 GDScript 值拷贝陷阱）。


func run(runner) -> void:
	var server := AssetForgeServer.new()
	var token_path := server.start()
	runner.check(token_path != "", "start() 返回 token 路径非空（IMPORTANT-3）")
	runner.check(FileAccess.file_exists(token_path), "token 文件已写: " + token_path)
	var token := FileAccess.get_file_as_string(token_path).strip_edges()
	for i in 5:
		server.poll()
		OS.delay_msec(20)
	var url := "ws://127.0.0.1:60650"
	# 错 token → unauthorized + 断连
	var ws1 := WebSocketPeer.new()
	ws1.connect_to_url(url)
	_poll_until_open(ws1, server)
	runner.check(ws1.get_ready_state() == WebSocketPeer.STATE_OPEN, "client1 连上")
	ws1.send_text(JSON.stringify({"type": "handshake", "payload": {"token": "wrong"}}))
	var closed1 := _poll_until(
		ws1, server, func(): return ws1.get_ready_state() == WebSocketPeer.STATE_CLOSED, 30
	)
	runner.check(closed1, "错 token → 断连（unauthorized，IMPORTANT-3 鉴权）")
	# 正确 token → handshake_ack
	var ws2 := WebSocketPeer.new()
	ws2.connect_to_url(url)
	_poll_until_open(ws2, server)
	ws2.send_text(
		JSON.stringify(
			{
				"type": "handshake",
				"payload": {"client": "forge_client", "version": "1.0.0", "token": token}
			}
		)
	)
	var ack: Variant = _drain_until(ws2, server, "handshake_ack", 30)
	runner.check(ack != null, "正确 token → handshake_ack（A5）")
	# generate 分发（数组捕获）
	var recv: Array = []
	server.command_received.connect(func(p, b, _ws): recv.append({"payload": p, "batch": b}))
	ws2.send_text(
		JSON.stringify({"type": "generate", "id": "r1", "payload": {"shape": "box", "name": "t1"}})
	)
	for i in 30:
		server.poll()
		ws2.poll()
		if not recv.is_empty():
			break
		OS.delay_msec(20)
	runner.check(
		not recv.is_empty() and recv[0]["payload"].get("shape") == "box",
		"generate → command_received shape=box"
	)
	runner.check(int(recv[0]["batch"]) > 0, "generate batch_id > 0")
	# batch > 64 → invalid_params（IMPORTANT-4）
	var big_items: Array = []
	for i in 65:
		big_items.append({"shape": "box"})
	ws2.send_text(JSON.stringify({"type": "generate_batch", "id": "r2", "items": big_items}))
	var err: Variant = _drain_until(ws2, server, "error_invalid", 30)
	runner.check(
		err != null and String(err.get("error")) == "invalid_params",
		"batch > 64 → invalid_params（IMPORTANT-4）"
	)
	# 合法 batch → per-item 散回执（2 item → 2 条独立 generate_result 共享同 req_id，2026-07-04 Q7 宽松化）
	var batch_items: Array = [
		{"shape": "box", "name": "bt1"},
		{"shape": "cylinder", "name": "bt2"},
	]
	var batch_recv: Array = []
	var batch_state: Array = [{"emitted": 0, "batch_id": -2}]
	# 捕获 callable（命名变量，便于 disconnect）
	var on_batch := func(p, b, ws):
		batch_state[0]["emitted"] = int(batch_state[0]["emitted"]) + 1
		batch_state[0]["batch_id"] = b
		# 模拟 plugin 处理一个 item 后回 result（共享同 req_id，定向回请求方 ws，I-2）
		server.send_result(
			"r_batch", true, {"node_path": "/Root/%s" % String(p.get("name", "x"))}, ws
		)
	server.command_received.connect(on_batch)
	# 发 generate_batch，server 对每 item emit 一次 command_received（per-item 散）
	ws2.send_text(JSON.stringify({"type": "generate_batch", "id": "r_batch", "items": batch_items}))
	# 收齐 2 条 generate_result（按 id == "r_batch" 计数）
	for i in 60:
		ws2.poll()
		server.poll()
		while ws2.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws2.get_packet().get_string_from_utf8())
			if (
				m is Dictionary
				and String(m.get("type", "")) == "generate_result"
				and String(m.get("id", "")) == "r_batch"
			):
				batch_recv.append(m)
		if batch_recv.size() >= 2 and int(batch_state[0]["emitted"]) >= 2:
			break
		OS.delay_msec(20)
	server.command_received.disconnect(on_batch)
	runner.check(
		int(batch_state[0]["emitted"]) == 2,
		(
			"合法 batch 2 item → server emit 2 次 command_received（per-item 散，共享 batch_id=%d）"
			% int(batch_state[0]["batch_id"])
		)
	)
	runner.check(batch_recv.size() == 2, "client 收齐 2 条 generate_result（共享 req_id=r_batch，非单条聚合体）")
	if batch_recv.size() == 2:
		runner.check(
			(
				String(batch_recv[0].get("id")) == "r_batch"
				and String(batch_recv[1].get("id")) == "r_batch"
			),
			"两条 result 共享同一 req_id"
		)
		runner.check(batch_recv[0] != batch_recv[1], "两条 result 是独立对象（非同一聚合体）")
	# undo 转发（batch_id=-1, __undo=true）
	recv.clear()
	ws2.send_text(JSON.stringify({"type": "undo_last", "id": "r3"}))
	for i in 30:
		server.poll()
		ws2.poll()
		if not recv.is_empty():
			break
		OS.delay_msec(20)
	runner.check(
		not recv.is_empty() and bool(recv[0]["payload"].get("__undo", false)),
		"undo_last → command_received __undo=true"
	)
	runner.check(int(recv[0]["batch"]) == -1, "undo batch_id = -1")
	# === I-1：非 dict 顶层 JSON → invalid_params（handshake 前可达，定向回执，不 SCRIPT ERROR）===
	ws2.send_text("[1,2,3]")
	var nondict: Variant = _drain_until(ws2, server, "error_invalid", 30)
	runner.check(
		nondict != null and String(nondict.get("error")) == "invalid_params",
		"非 dict JSON → invalid_params（I-1）"
	)
	# === A-2：generate_batch items 非 Array / item 非 Dictionary → invalid_params（不静默退化）===
	ws2.send_text(JSON.stringify({"type": "generate_batch", "id": "bi", "items": "not_array"}))
	var bad_items: Variant = _drain_until(ws2, server, "error_invalid", 30)
	runner.check(
		bad_items != null and String(bad_items.get("error")) == "invalid_params",
		"batch items 非 Array → invalid_params（A-2）"
	)
	ws2.send_text(JSON.stringify({"type": "generate_batch", "id": "bi2", "items": [1, 2, 3]}))
	var bad_item: Variant = _drain_until(ws2, server, "error_invalid", 30)
	runner.check(
		bad_item != null and String(bad_item.get("error")) == "invalid_params",
		"batch item 非 Dictionary → invalid_params（A-2）"
	)
	# === I-2：多 client 不互泄 result（send_result 定向发送，不再 send_to_all 广播）===
	var ws3 := WebSocketPeer.new()
	ws3.connect_to_url(url)
	_poll_until_open(ws3, server)
	ws3.send_text(JSON.stringify({"type": "handshake", "payload": {"token": token}}))
	runner.check(
		_drain_until(ws3, server, "handshake_ack", 30) != null,
		"client3 handshake_ack（I-2 multi-client）"
	)
	var leak: Array = [0, 0]  # [ws2 命中 leak result 次数, ws3 收到 generate_result 次数]
	var on_leak := func(p, b, reqws):
		server.send_result("leak", true, {"node_path": "/Root/secret"}, reqws)
	server.command_received.connect(on_leak)
	ws2.send_text(JSON.stringify({"type": "generate", "id": "leak", "payload": {"shape": "box"}}))
	for i in 30:
		ws2.poll()
		ws3.poll()
		server.poll()
		while ws2.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws2.get_packet().get_string_from_utf8())
			if m is Dictionary and String(m.get("id", "")) == "leak":
				leak[0] += 1
		while ws3.get_available_packet_count() > 0:
			var m3 = JSON.parse_string(ws3.get_packet().get_string_from_utf8())
			if m3 is Dictionary and String(m3.get("type", "")) == "generate_result":
				leak[1] += 1
		if leak[0] > 0:
			break
		OS.delay_msec(20)
	server.command_received.disconnect(on_leak)
	runner.check(leak[0] == 1, "请求方 ws2 收到自己的 result（I-2 定向发送）")
	runner.check(leak[1] == 0, "其他 authed client ws3 不收到 ws2 的 result（I-2 不广播）")
	# === A-3：多 authed client 任一断开，仍有 authed 时 connection_status_changed 不 emit false ===
	var emitted_false: Array = [false]
	var on_conn := func(c):
		if not c:
			emitted_false[0] = true
	server.connection_status_changed.connect(on_conn)
	ws3.close()
	for i in 30:
		ws3.poll()
		server.poll()
		if emitted_false[0]:
			break
		OS.delay_msec(20)
	runner.check(not emitted_false[0], "ws3 断开但 ws2 仍 authed → 不 emit false（A-3）")
	server.connection_status_changed.disconnect(on_conn)
	# === A-9：MAX_CLIENTS 超额拒绝（ws2 占 1 席，填到上限，第 MAX_CLIENTS+1 个被拒）===
	for i in 5:
		server.poll()
		OS.delay_msec(20)  # 清残留
	var fill_clients: Array = []
	for i in range(AssetForgeServer.MAX_CLIENTS - 1):  # ws2 已占 1 席，填到 MAX_CLIENTS
		var c := WebSocketPeer.new()
		c.connect_to_url(url)
		_poll_until_open(c, server)
		if c.get_ready_state() == WebSocketPeer.STATE_OPEN:
			fill_clients.append(c)
	var overflow := WebSocketPeer.new()
	overflow.connect_to_url(url)
	for i in 30:
		overflow.poll()
		server.poll()
		if overflow.get_ready_state() in [WebSocketPeer.STATE_CLOSED, WebSocketPeer.STATE_CLOSING]:
			break
		OS.delay_msec(20)
	runner.check(
		overflow.get_ready_state() in [WebSocketPeer.STATE_CLOSED, WebSocketPeer.STATE_CLOSING],
		(
			"超额连接（第 %d 个）被拒 → STATE_CLOSED（A-9 MAX_CLIENTS=%d）"
			% [AssetForgeServer.MAX_CLIENTS + 1, AssetForgeServer.MAX_CLIENTS]
		)
	)
	for c in fill_clients:
		c.close()
	# === generate_path：emit command_received 共享同一 batch_id（与 generate 同语义）===
	recv.clear()
	ws2.send_text(
		JSON.stringify(
			{
				"type": "generate_path",
				"id": "rp",
				"payload":
					{"shape": "cylinder", "path": [[0, 0, 0], [1, 0, 0]], "count": 2, "name": "rp_test"}
			}
		)
	)
	for i in 30:
		ws2.poll()
		server.poll()
		if not recv.is_empty():
			break
		OS.delay_msec(20)
	runner.check(
		not recv.is_empty() and recv[0]["payload"].get("path") != null,
		"generate_path → command_received 含 path payload"
	)
	runner.check(int(recv[0]["batch"]) > 0, "generate_path batch_id > 0（共享 batch 语义）")
	runner.check(
		String(recv[0]["payload"].get("__req_id")) == "rp", "generate_path __req_id 透传"
	)
	# === generate_path mode 字段透传（command_server 零改动验证）===
	recv.clear()
	ws2.send_text(
		JSON.stringify(
			{
				"type": "generate_path",
				"id": "rpm",
				"payload":
					{"shape": "wall", "path": [[0, 0, 0], [4, 0, 0]], "count": 2, "mode": "continuous"}
			}
		)
	)
	for i in 30:
		ws2.poll()
		server.poll()
		if not recv.is_empty():
			break
		OS.delay_msec(20)
	runner.check(
		not recv.is_empty() and String(recv[0]["payload"].get("mode", "")) == "continuous",
		"generate_path mode 字段透传（command_server 零改动）"
	)
	server.stop()
	DirAccess.remove_absolute(token_path)


static func _poll_until_open(ws: WebSocketPeer, server) -> void:
	for i in 30:
		ws.poll()
		server.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return
		OS.delay_msec(20)


static func _poll_until(ws: WebSocketPeer, server, cond: Callable, frames: int) -> bool:
	for i in frames:
		ws.poll()
		server.poll()
		if cond.call():
			return true
		OS.delay_msec(20)
	return false


static func _drain_until(ws: WebSocketPeer, server, want: String, frames: int) -> Variant:
	for i in frames:
		ws.poll()
		server.poll()
		while ws.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if m is Dictionary:
				if want == "error_invalid" and m.has("error"):
					return m
				if String(m.get("type", "")) == want:
					return m
		OS.delay_msec(20)
	return null
