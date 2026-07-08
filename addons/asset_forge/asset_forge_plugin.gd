# asset_forge_plugin.gd
# Asset Forge EditorPlugin 入口：装配 dock + server、_on_command 编排、_undo_stack 持有。
@tool
extends EditorPlugin

const _Server = preload("res://addons/asset_forge/command_server.gd")
const _Dock = preload("res://addons/asset_forge/forge_dock.gd")

var _server = null
var _dock: AssetForgeDock = null
var _undo_stack: Array = []  # IMPORTANT-2：registry 持有者，_exit_tree 清空
var _orch: Orchestrator = null  # claim 5：编排层（EditorInterface 副作用经 Callable 注入）


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
	# claim 5：装配 Orchestrator（_server/_undo_stack 就绪 + dock 就绪后，server 启动前）
	_orch = Orchestrator.new(
		_server,
		_undo_stack,
		Callable(self, "_get_root"),
		Callable(self, "_mark_unsaved"),
		Callable(self, "_dock_add")
	)
	_on_start()  # 自动启动 server


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	_undo_stack.clear()  # IMPORTANT-2：不跨会话
	AssetFactory.clear_cache()  # P1-6：mesh 缓存也不跨会话（与 _undo_stack 对齐）
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


func _on_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	# claim 5：透传 Orchestrator（编排逻辑已搬迁，plugin 仅胶水）
	_orch.handle_command(payload, batch_id, ws)


# claim 5：EditorInterface/UI 副作用包装，经 Callable 注入 Orchestrator（解耦编排层）
func _get_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()


func _dock_add(node_name: String, node_path: String) -> void:
	if _dock:
		_dock.add_to_generated_list(node_name, node_path)
