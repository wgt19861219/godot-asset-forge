# command_server.gd
# Asset Forge WebSocket 服务器 + 协议常量 + 消息构造 + handshake/token 鉴权。
# 协议：handshake token / generate / batch（per-item 散回执）/ undo 分发。
@tool
class_name AssetForgeServer
extends RefCounted

# --- 协议常量 ---
const HOST: String = "127.0.0.1"
const PORT: int = 60650
const PROTOCOL_VERSION: String = "1.0.0"
const BATCH_LIMIT: int = 64
const MAX_CLIENTS: int = 8  # A-9：本机 DoS 防护，拒绝超额连接
const CLIENT_TIMEOUT_MSEC: int = 120000  # A-9：半开连接清理（无任何消息 120s → close）
const MSG_HANDSHAKE := "handshake"
const MSG_HANDSHAKE_ACK := "handshake_ack"
const MSG_PING := "ping"
const MSG_PONG := "pong"
const MSG_GENERATE := "generate"
const MSG_GENERATE_BATCH := "generate_batch"
const MSG_GENERATE_RESULT := "generate_result"
const MSG_GENERATE_PATH := "generate_path"
const MSG_UNDO_LAST := "undo_last"
const TOKEN_FILE := "user://asset_forge.token"

# --- 信号 ---
signal command_received(payload: Dictionary, batch_id: int, ws: WebSocketPeer)
signal connection_status_changed(connected: bool)
signal log_emitted(msg: String)

var _tcp: TCPServer = null
var _clients: Array = []  # {ws, id, authed}
var _token: String = ""
var _batch_counter: int = 0
var _running: bool = false

var is_running: bool:
	get:
		return _running

# --- 生命周期 ---


func start() -> String:
	if _running:
		return ProjectSettings.globalize_path(TOKEN_FILE)
	_token = _gen_token()
	if not _write_token():
		# I-4：token 写失败 → 与端口监听失败一致处理，不留 _running=true 误态（否则客户端永远 unauthorized）
		_running = false
		return ""
	_tcp = TCPServer.new()
	var err := _tcp.listen(PORT, HOST)
	if err != OK:
		log_emitted.emit("端口 %d 启动失败: %s" % [PORT, str(err)])
		_running = false
		return ""
	_running = true
	log_emitted.emit("Asset Forge server: ws://%s:%d（bind 127.0.0.1）" % [HOST, PORT])
	return ProjectSettings.globalize_path(TOKEN_FILE)


func stop() -> void:
	for c in _clients:
		(c["ws"] as WebSocketPeer).close()
	_clients.clear()
	if _tcp:
		_tcp.stop()
		_tcp = null
	_running = false
	connection_status_changed.emit(false)
	log_emitted.emit("Asset Forge server stopped")


func poll() -> void:
	if not _running:
		return
	while _tcp.is_connection_available():
		if _clients.size() >= MAX_CLIENTS:  # A-9：超额拒绝（防本机进程耗内存）
			log_emitted.emit("连接数达上限 %d，拒绝新连接" % MAX_CLIENTS)
			_tcp.take_connection().disconnect_from_host()
			break
		var stream := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1024 * 1024
		ws.outbound_buffer_size = 256 * 1024
		ws.accept_stream(stream)
		_clients.append(
			{
				"ws": ws,
				"id": str(stream.get_connected_host()) + ":" + str(stream.get_connected_port()),
				"authed": false,
				"last_seen": Time.get_ticks_msec()
			}
		)
	var to_remove: Array = []
	for i in range(_clients.size()):
		var c: Dictionary = _clients[i]
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var pkt := ws.get_packet()
				if ws.was_string_packet():
					_handle_text(ws, c, pkt.get_string_from_utf8())
			c["last_seen"] = Time.get_ticks_msec()  # A-9：收包刷新 keepalive（含 handshake/ping/generate）
		elif state == WebSocketPeer.STATE_CLOSED:
			# A-3：仅当没有其他 authed client 时才 emit false（多 client 任一断开不应让仍连着的 client 被显示为未连接）
			if c.get("authed", false) and _authed_count() <= 1:
				connection_status_changed.emit(false)
			to_remove.append(c)
		# A-9：keepalive 超时清理（无消息超 CLIENT_TIMEOUT_MSEC → close，下次 poll 转 STATE_CLOSED 移除）
		if (
			state == WebSocketPeer.STATE_OPEN
			and Time.get_ticks_msec() - int(c.get("last_seen", 0)) > CLIENT_TIMEOUT_MSEC
		):
			log_emitted.emit("client 超时无消息 %d ms，关闭: %s" % [CLIENT_TIMEOUT_MSEC, String(c["id"])])
			ws.close()
	for c in to_remove:
		_clients.erase(c)


# --- 发送 ---


# authed client 计数（A-3：多 client 任一断开时判断是否仍有 authed 连接）
func _authed_count() -> int:
	var n: int = 0
	for c in _clients:
		if c.get("authed", false):
			n += 1
	return n


func send_json(ws: WebSocketPeer, data: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(data))


# I-2：send_result 定向发回请求方 ws，不再 send_to_all 广播（避免多 client 互泄 node_path/resource_path）
func send_result(id: String, success: bool, fields: Dictionary, ws: WebSocketPeer) -> void:
	var msg := {"type": MSG_GENERATE_RESULT, "id": id, "success": success}
	for k in fields:
		msg[k] = fields[k]
	send_json(ws, msg)


func send_unauthorized_and_close(ws: WebSocketPeer) -> void:
	send_json(
		ws,
		{
			"type": MSG_GENERATE_RESULT,
			"id": "",
			"success": false,
			"error": "unauthorized",
			"message": "token 不符"
		}
	)
	ws.close()


# --- 消息处理 ---


func _handle_text(ws: WebSocketPeer, client: Dictionary, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		log_emitted.emit("JSON 解析失败")
		return
	# I-1：非 dict 顶层 JSON（array/string/number）守卫。JSON.parse 对这些返 OK 但 get_data 非 dict，
	# 强转 Dictionary 触发 SCRIPT ERROR（handshake 前可达）。定向回 invalid_params，避免日志洪泛 + 客户端死循环。
	var parsed: Variant = json.get_data()
	if not (parsed is Dictionary):
		send_json(
			ws,
			{
				"type": MSG_GENERATE_RESULT,
				"id": "",
				"success": false,
				"error": "invalid_params",
				"message": "顶层 JSON 必须是对象"
			}
		)
		return
	var obj: Dictionary = parsed
	var t: String = String(obj.get("type", ""))
	var req_id := String(obj.get("id", ""))
	match t:
		MSG_HANDSHAKE:
			var payload: Dictionary = obj.get("payload", {})
			if String(payload.get("token", "")) != _token:
				log_emitted.emit("handshake token 不符，拒绝")
				send_unauthorized_and_close(ws)
				return
			client["authed"] = true
			log_emitted.emit("Client 已鉴权: " + String(client["id"]))
			connection_status_changed.emit(true)
			send_json(ws, _handshake_ack())
		MSG_PING:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			send_json(ws, {"type": MSG_PONG})
		MSG_GENERATE:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			_batch_counter += 1
			# v11.5 P1：payload 非 dict 守卫（与 I-1 顶层 / A-2 batch 一致），防强转 SCRIPT ERROR 中断 _handle_text
			var payload_v: Variant = obj.get("payload", {})
			if not (payload_v is Dictionary):
				send_result(req_id, false, {"error": "invalid_params", "message": "generate payload 必须是对象"}, ws)
				return
			var payload: Dictionary = payload_v
			payload["__req_id"] = req_id
			command_received.emit(payload, _batch_counter, ws)
		MSG_GENERATE_BATCH:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			# A-2：items 非 Array / item 非 Dictionary 时回 invalid_params，不静默退化为空 batch
			var items: Variant = obj.get("items", [])
			if not (items is Array):
				send_result(
					req_id,
					false,
					{"error": "invalid_params", "message": "generate_batch items 必须是数组"},
					ws
				)
				return
			var arr: Array = items
			if arr.size() > BATCH_LIMIT:
				send_result(
					req_id,
					false,
					{
						"error": "invalid_params",
						"message": "batch items 上限 %d，实际 %d" % [BATCH_LIMIT, arr.size()]
					},
					ws
				)
				return
			_batch_counter += 1
			for it in arr:
				if not (it is Dictionary):
					send_result(
						req_id,
						false,
						{"error": "invalid_params", "message": "generate_batch item 必须是对象"},
						ws
					)
					return
				var p: Dictionary = it
				p["__req_id"] = req_id
				command_received.emit(p, _batch_counter, ws)
		MSG_GENERATE_PATH:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			_batch_counter += 1  # 一次 path 请求 = 一个 batch_id
			# v11.5 P1：payload 非 dict 守卫（与 I-1/A-2 一致），防强转 SCRIPT ERROR 中断 _handle_text
			var gp_v: Variant = obj.get("payload", {})
			if not (gp_v is Dictionary):
				send_result(req_id, false, {"error": "invalid_params", "message": "generate_path payload 必须是对象"}, ws)
				return
			var gp: Dictionary = gp_v
			gp["__req_id"] = req_id
			command_received.emit(gp, _batch_counter, ws)
		MSG_UNDO_LAST:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws)
				return
			command_received.emit({"__undo": true, "__req_id": req_id}, -1, ws)
		_:
			log_emitted.emit("忽略未知消息类型: " + t)


# --- token ---


func _gen_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


func _write_token() -> bool:
	var f := FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(_token)
		f.close()
		# v11.5 P1 安全：限制 token 仅本用户可读（防本机其他用户进程读 token 越权操控编辑器）。
		# Linux/macOS 生效；Windows 返 ERR_UNAVAILABLE 无害（ACL 默认单用户隔离）。失败不阻断（token 已写）。
		# 0o600（仅 owner 读写）= 384；GDScript 无八进制字面量，故用十进制等值。
		FileAccess.set_unix_permissions(TOKEN_FILE, 384)
		return true
	log_emitted.emit("token 写入失败: " + TOKEN_FILE)
	return false


func _handshake_ack() -> Dictionary:
	return {
		"type": MSG_HANDSHAKE_ACK,
		"payload":
		{
			"server": "asset_forge",
			"godot_version": Engine.get_version_info().get("string", "4.6"),
			"protocol": PROTOCOL_VERSION,
		}
	}
