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
const MSG_HANDSHAKE := "handshake"
const MSG_HANDSHAKE_ACK := "handshake_ack"
const MSG_PING := "ping"
const MSG_PONG := "pong"
const MSG_GENERATE := "generate"
const MSG_GENERATE_BATCH := "generate_batch"
const MSG_GENERATE_RESULT := "generate_result"
const MSG_UNDO_LAST := "undo_last"
const TOKEN_FILE := "user://asset_forge.token"

# --- 信号 ---
signal command_received(payload: Dictionary, batch_id: int)
signal connection_status_changed(connected: bool)
signal log_emitted(msg: String)

var _tcp: TCPServer = null
var _clients: Array = []   # {ws, id, authed}
var _token: String = ""
var _batch_counter: int = 0
var _running: bool = false

var is_running: bool:
	get: return _running

# --- 生命周期 ---

func start() -> String:
	if _running:
		return ProjectSettings.globalize_path(TOKEN_FILE)
	_token = _gen_token()
	_write_token()
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
		var stream := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1024 * 1024
		ws.outbound_buffer_size = 256 * 1024
		ws.accept_stream(stream)
		_clients.append({"ws": ws, "id": str(stream.get_connected_host()) + ":" + str(stream.get_connected_port()), "authed": false})
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
		elif state == WebSocketPeer.STATE_CLOSED:
			if c.get("authed", false):
				connection_status_changed.emit(false)
			to_remove.append(c)
	for c in to_remove:
		_clients.erase(c)

# --- 发送 ---

func send_json(ws: WebSocketPeer, data: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(data))

func send_to_all(data: Dictionary) -> void:
	for c in _clients:
		if c.get("authed", false):
			send_json(c["ws"], data)

func send_result(id: String, success: bool, fields: Dictionary) -> void:
	var msg := {"type": MSG_GENERATE_RESULT, "id": id, "success": success}
	for k in fields:
		msg[k] = fields[k]
	send_to_all(msg)

func send_unauthorized_and_close(ws: WebSocketPeer) -> void:
	send_json(ws, {"type": MSG_GENERATE_RESULT, "id": "", "success": false, "error": "unauthorized", "message": "token 不符"})
	ws.close()

# --- 消息处理 ---

func _handle_text(ws: WebSocketPeer, client: Dictionary, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		log_emitted.emit("JSON 解析失败")
		return
	var obj: Dictionary = json.get_data()
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
				send_unauthorized_and_close(ws); return
			send_json(ws, {"type": MSG_PONG})
		MSG_GENERATE:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws); return
			_batch_counter += 1
			var payload: Dictionary = obj.get("payload", {})
			payload["__req_id"] = req_id
			command_received.emit(payload, _batch_counter)
		MSG_GENERATE_BATCH:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws); return
			var items = obj.get("items", [])
			var arr: Array = items if items is Array else []
			if arr.size() > BATCH_LIMIT:
				send_result(req_id, false, {"error": "invalid_params", "message": "batch items 上限 %d，实际 %d" % [BATCH_LIMIT, arr.size()]})
				return
			_batch_counter += 1
			for it in arr:
				var p: Dictionary = it if it is Dictionary else {}
				p["__req_id"] = req_id
				command_received.emit(p, _batch_counter)
		MSG_UNDO_LAST:
			if not client.get("authed", false):
				send_unauthorized_and_close(ws); return
			command_received.emit({"__undo": true, "__req_id": req_id}, -1)
		_:
			log_emitted.emit("忽略未知消息类型: " + t)

# --- token ---

func _gen_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()

func _write_token() -> void:
	var f := FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(_token)
		f.close()
	else:
		log_emitted.emit("token 写入失败: " + TOKEN_FILE)

func _handshake_ack() -> Dictionary:
	return {
		"type": MSG_HANDSHAKE_ACK,
		"payload": {
			"server": "asset_forge",
			"godot_version": Engine.get_version_info().get("string", "4.6"),
			"protocol": PROTOCOL_VERSION,
		}
	}
