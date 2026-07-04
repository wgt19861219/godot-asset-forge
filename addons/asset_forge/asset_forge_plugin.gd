# asset_forge_plugin.gd
# Asset Forge EditorPlugin 入口：装配 dock + server、_on_command 编排、_undo_stack 持有。
@tool
extends EditorPlugin

const _Server = preload("res://addons/asset_forge/command_server.gd")
const _Dock = preload("res://addons/asset_forge/forge_dock.gd")

var _server = null
var _dock: AssetForgeDock = null
var _undo_stack: Array = []   # IMPORTANT-2：registry 持有者，_exit_tree 清空

func _enter_tree() -> void:
	_server = _Server.new()
	_server.command_received.connect(_on_command)
	_server.connection_status_changed.connect(_on_connection)
	_server.log_emitted.connect(_on_log)
	_dock = _Dock.new()
	_dock.name = "Asset Forge"
	_dock.start_server_pressed.connect(_on_start)
	_dock.stop_server_pressed.connect(_on_stop)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	_on_start()  # 自动启动 server

func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	_undo_stack.clear()   # IMPORTANT-2：不跨会话
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

func _process(_delta: float) -> void:
	if _server:
		_server.poll()

func _on_start() -> void:
	if _server:
		var token_path: String = _server.start()
		if _dock:
			_dock.set_server_running(_server.is_running)
			if token_path != "":
				_dock.set_token_path(token_path)
				LogHelper.log("token 路径（供 forge_client 读取）: " + token_path)  # stdout，IMPORTANT-3

func _on_stop() -> void:
	if _server:
		_server.stop()
		if _dock:
			_dock.set_server_running(false)

func _on_connection(connected: bool) -> void:
	if _dock:
		_dock.update_connection(connected)

func _on_log(msg: String) -> void:
	if _dock:
		_dock.append_log(msg)

func _on_command(payload: Dictionary, batch_id: int) -> void:
	var req_id: String = String(payload.get("__req_id", ""))
	# undo（batch_id == -1）
	if bool(payload.get("__undo", false)):
		var ur := ScenePlacer.undo_last(_undo_stack)
		_server.send_result(req_id, bool(ur["success"]), {"message": "freed %d" % int(ur["freed"]), "error": String(ur["error"])})
		return
	# generate
	var shape: String = String(payload.get("shape", ""))
	var mesh = AssetFactory.create_mesh(shape, payload.get("params", {}))
	if mesh == null:
		_server.send_result(req_id, false, {"error": "unsupported_shape", "message": "未知 shape: %s（支持 box/cylinder/sphere/prism/wall/ramp/cone/tube/torus/stairs/fence）" % shape})
		return
	var material = AssetFactory.create_material(payload.get("material", null))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_server.send_result(req_id, false, {"error": "no_active_scene", "message": "无活动场景，请先在编辑器新建或打开场景再 generate"})
		return  # A1 修订（2026-07-04）：原自动建场景因 EditorInterface 无 set_edited_scene API，改为显式 error
	var place_payload := {
		"name": payload.get("name", ""),
		"transform": payload.get("transform", {}),
		"parent": payload.get("parent", ""),
		"save": payload.get("save", false),
	}
	var r := ScenePlacer.place(root, mesh, material, place_payload, _undo_stack, batch_id)
	if bool(r["success"]):
		_server.send_result(req_id, true, {"node_path": String(r["node_path"]), "resource_path": String(r["resource_path"])})
		if _dock:
			_dock.add_to_generated_list(String(place_payload["name"]), String(r["node_path"]))
		EditorInterface.mark_scene_as_unsaved()
	else:
		_server.send_result(req_id, false, {"error": String(r["error"]), "message": "place 失败"})
