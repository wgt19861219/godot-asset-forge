# asset_forge_plugin.gd
# Asset Forge EditorPlugin 入口：装配 dock + server、_on_command 编排、_undo_stack 持有。
@tool
extends EditorPlugin

const _Server = preload("res://addons/asset_forge/command_server.gd")
const _Dock = preload("res://addons/asset_forge/forge_dock.gd")

var _server = null
var _dock: AssetForgeDock = null
var _undo_stack: Array = []  # IMPORTANT-2：registry 持有者，_exit_tree 清空


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
	_undo_stack.clear()  # IMPORTANT-2：不跨会话
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
	var req_id: String = String(payload.get("__req_id", ""))
	# undo（batch_id == -1）
	if bool(payload.get("__undo", false)):
		var ur := ScenePlacer.undo_last(_undo_stack)
		_server.send_result(
			req_id,
			bool(ur["success"]),
			{"message": "freed %d" % int(ur["freed"]), "error": String(ur["error"])},
			ws
		)
		return
	# generate_path（路径阵列，MVP）—— payload 含 path 走路径分支
	if payload.has("path"):
		_handle_generate_path(payload, batch_id, req_id, ws)
		return
	# generate（单件）
	var shape: String = String(payload.get("shape", ""))
	var mesh = AssetFactory.create_mesh(shape, payload.get("params", {}))
	if mesh == null:
		(
			_server
			. send_result(
				req_id,
				false,
				{
					"error": "unsupported_shape",
					"message":
					(
						"未知 shape: %s（支持 box/cylinder/sphere/prism/wall/ramp/cone/tube/torus/stairs/fence）"
						% shape
					)
				},
				ws
			)
		)
		return
	var material = AssetFactory.create_material(payload.get("material", null))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_server.send_result(
			req_id,
			false,
			{"error": "no_active_scene", "message": "无活动场景，请先在编辑器新建或打开场景再 generate"},
			ws
		)
		return  # A1 修订（2026-07-04）：原自动建场景因 EditorInterface 无 set_edited_scene API，改为显式 error
	var place_payload := {
		"name": payload.get("name", ""),
		"transform": payload.get("transform", {}),
		"parent": payload.get("parent", ""),
		"save": payload.get("save", false),
	}
	var r := ScenePlacer.place(root, mesh, material, place_payload, _undo_stack, batch_id)
	if bool(r["success"]):
		_server.send_result(
			req_id,
			true,
			{"node_path": String(r["node_path"]), "resource_path": String(r["resource_path"])},
			ws
		)
		if _dock:
			_dock.add_to_generated_list(String(place_payload["name"]), String(r["node_path"]))
		EditorInterface.mark_scene_as_unsaved()
	else:
		_server.send_result(req_id, false, {"error": String(r["error"]), "message": "place 失败"}, ws)


# generate_path 编排：parse → validate → sample → mode 分流 → _place_one 循环（共享 batch_id，per-point 散回执）
func _handle_generate_path(
	payload: Dictionary, batch_id: int, req_id: String, ws: WebSocketPeer
) -> void:
	var mode := String(payload.get("mode", "discrete"))
	if mode != "discrete" and mode != "continuous":
		_server.send_result(
			req_id,
			false,
			{"error": "invalid_params", "message": "mode 必须 discrete|continuous"},
			ws
		)
		return
	var parsed: Dictionary = PathGenerator.parse_path(payload.get("path", []))
	if String(parsed["error"]) != "":
		_server.send_result(
			req_id, false, {"error": "invalid_params", "message": String(parsed["error"])}, ws
		)
		return
	var points: Array = parsed["points"]
	var spacing: float = float(payload.get("spacing", 0.0))
	var count: int = int(payload.get("count", 0))
	var align: String = String(payload.get("align", "path"))
	var include_endpoints: bool = bool(payload.get("include_endpoints", true))
	var verr: String = PathGenerator.validate(
		points, spacing, count, align, include_endpoints, mode
	)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	var samples: Array = PathGenerator.sample(
		points, spacing, count, align, include_endpoints, mode
	)
	if samples.size() > _Server.BATCH_LIMIT:
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				"samples 上限 %d，实际 %d（缩短路径/增大 spacing/减少 count）"
				% [_Server.BATCH_LIMIT, samples.size()]
			},
			ws
		)
		return
	var shape: String = String(payload.get("shape", ""))
	var base_params: Dictionary = payload.get("params", {})
	# continuous 模式 shape 白名单（length 沿 X）
	if mode == "continuous" and shape != "wall" and shape != "fence":
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message":
				"continuous 模式仅支持 wall/fence（length 沿 X），当前 " + shape
			},
			ws
		)
		return
	var probe_mesh = AssetFactory.create_mesh(shape, base_params)
	if probe_mesh == null:
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message":
				(
					"未知 shape: %s（支持 box/cylinder/sphere/prism/wall/ramp/cone/tube/torus/stairs/fence）"
					% shape
				)
			},
			ws
		)
		return
	var material = AssetFactory.create_material(payload.get("material", null))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_server.send_result(
			req_id, false, {"error": "no_active_scene", "message": "无活动场景"}, ws
		)
		return
	var base_name: String = String(payload.get("name", ""))
	if base_name == "":
		base_name = shape
	if mode == "discrete":
		for i in samples.size():
			var s: Dictionary = samples[i]
			_place_one(
				root, probe_mesh, material, base_name, i, s["position"], s["rotation_deg"],
				payload, batch_id, req_id, ws
			)
	else:  # continuous：每段独立 create_mesh（length 注入）
		for i in samples.size():
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
			var seg_mesh := AssetFactory.create_mesh(shape, seg_params)
			_place_one(
				root, seg_mesh, material, base_name, i, seg["position"], seg["rotation_deg"],
				payload, batch_id, req_id, ws
			)
	EditorInterface.mark_scene_as_unsaved()


# _place_one：构造 place_payload + ScenePlacer.place + send_result（discrete/continuous 共用，消除 loop 重复）
func _place_one(
	root: Node,
	mesh: Mesh,
	material: Material,
	base_name: String,
	i: int,
	pos_var: Variant,
	rot_var: Variant,
	payload: Dictionary,
	batch_id: int,
	req_id: String,
	ws: WebSocketPeer
) -> void:
	var pos: Vector3 = pos_var
	var rot: Vector3 = rot_var
	var place_payload := {
		"name": "%s_%d" % [base_name, i],
		"transform":
		{"position": [pos.x, pos.y, pos.z], "rotation_deg": [rot.x, rot.y, rot.z]},
		"parent": payload.get("parent", ""),
		"save": payload.get("save", false),
	}
	var r := ScenePlacer.place(root, mesh, material, place_payload, _undo_stack, batch_id)
	if bool(r["success"]):
		_server.send_result(
			req_id,
			true,
			{"node_path": String(r["node_path"]), "resource_path": String(r["resource_path"])},
			ws
		)
		if _dock:
			_dock.add_to_generated_list(
				String(place_payload["name"]), String(r["node_path"])
			)
	else:
		_server.send_result(
			req_id, false, {"error": String(r["error"]), "message": "place 失败"}, ws
		)
