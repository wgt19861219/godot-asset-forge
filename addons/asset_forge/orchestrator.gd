# orchestrator.gd
# 编排层（claim 5）。从 asset_forge_plugin.gd 搬入 handle_command/_handle_generate_path/_place_one。
# EditorInterface 副作用（get_edited_scene_root / mark_scene_as_unsaved）通过 Callable 注入，
# 本类零 EditorInterface 依赖 → 可 headless 单测。
@tool
class_name Orchestrator
extends RefCounted

# R1（duck typing 换可测性）：_server 是唯一需 mock 的有状态依赖，去 AssetForgeServer 强类型注解。
# MockServer（inner class extends RefCounted）才注得进去。损失的类型安全由 22 case 补回。
var _server: RefCounted = null
# IMPORTANT-2（修订）：clear 责任单一 + 生命周期跟 plugin；Orchestrator 持【非所有者引用】。
# GDScript Array 引用语义：append/pop 直达 plugin 的栈；_exit_tree.clear() 仍由 plugin 执行。
var _undo_stack: Array = []
var _get_root: Callable  # 替 EditorInterface.get_edited_scene_root()
var _mark_unsaved: Callable  # 替 EditorInterface.mark_scene_as_unsaved()
var _dock_add: Callable  # 替 _dock.add_to_generated_list（plugin._dock_add 内部判 _dock null）


func _init(
	server: RefCounted,
	undo_stack: Array,
	get_root: Callable,
	mark_unsaved: Callable,
	dock_add: Callable
) -> void:
	_server = server
	_undo_stack = undo_stack
	_get_root = get_root
	_mark_unsaved = mark_unsaved
	_dock_add = dock_add


# plugin._on_command 信号槽直接转调此方法（req_id 在此首行自提，消除胶水层冗余）。
func handle_command(payload: Dictionary, batch_id: int, ws: WebSocketPeer) -> void:
	var req_id: String = String(payload.get("__req_id", ""))
	# undo（batch_id == -1）
	if bool(payload.get("__undo", false)):
		var ur := ScenePlacer.undo_last(_undo_stack)
		var ur_ok := bool(ur["success"])
		var undo_fields := {"error": String(ur["error"])}
		if ur_ok:
			undo_fields["message"] = "freed %d" % int(ur["freed"])  # P2#8：仅成功时塞 freed 文案（nothing_to_undo 不报 freed 0）
		_server.send_result(req_id, ur_ok, undo_fields, ws)
		return
	# generate_path（路径阵列）—— v3：path 或 path_node 都触发 path 分支（v2 仅 path）
	if payload.has("path") or payload.has("path_node"):
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
	var root: Node = _get_root.call()
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
		if _dock_add.is_valid():
			_dock_add.call(String(place_payload["name"]), String(r["node_path"]))
		# P1-5：mark 前校验 root 仍有效且是当前场景（防场景切换竞态操作失效场景）
		if ScenePlacer.can_mark_scene(root, _get_root.call()):
			_mark_unsaved.call()
	else:
		_server.send_result(req_id, false, {"error": String(r["error"]), "message": "place 失败"}, ws)


# generate_path 编排：parse → validate → sample → mode 分流 → _place_one 循环（共享 batch_id，per-point 散回执）
func _handle_generate_path(
	payload: Dictionary, batch_id: int, req_id: String, ws: WebSocketPeer
) -> void:
	var mode := String(payload.get("mode", "discrete"))
	if mode != "discrete" and mode != "continuous":
		_server.send_result(
			req_id, false, {"error": "invalid_params", "message": "mode 必须 discrete|continuous"}, ws
		)
		return
	# A1：root 提前取（path_node 解析 + 后续 place 都需 root；v2 的 root 取值从 sample 之后提到最前）
	var root: Node = _get_root.call()
	if root == null:
		_server.send_result(req_id, false, {"error": "no_active_scene", "message": "无活动场景"}, ws)
		return
	# v3：path/path_node 互斥 + path 源分流
	if payload.has("path") and payload.has("path_node"):
		_server.send_result(
			req_id, false, {"error": "invalid_params", "message": "path 与 path_node 互斥"}, ws
		)
		return
	if not payload.has("path") and not payload.has("path_node"):
		_server.send_result(
			req_id, false, {"error": "invalid_params", "message": "必须提供 path 或 path_node 之一"}, ws
		)
		return
	var points: Array
	if payload.has("path_node"):
		var resolved: Dictionary = ScenePlacer.resolve_path3d(root, String(payload["path_node"]))
		if String(resolved["error"]) != "":
			_server.send_result(
				req_id, false, {"error": "invalid_params", "message": String(resolved["error"])}, ws
			)
			return
		points = resolved["points"]
	else:
		var parsed: Dictionary = PathGenerator.parse_path(payload.get("path", []))
		if String(parsed["error"]) != "":
			_server.send_result(
				req_id, false, {"error": "invalid_params", "message": String(parsed["error"])}, ws
			)
			return
		points = parsed["points"]
	var spacing: float = float(payload.get("spacing", 0.0))
	var count: int = int(payload.get("count", 0))
	var align: String = String(payload.get("align", "path"))
	var include_endpoints: bool = bool(payload.get("include_endpoints", true))
	var align_vertices: bool = bool(payload.get("align_vertices", false))  # v4 新增
	var verr: String = PathGenerator.validate(
		points, spacing, count, align, include_endpoints, mode, align_vertices
	)
	if verr != "":
		_server.send_result(req_id, false, {"error": "invalid_params", "message": verr}, ws)
		return
	# P1#3：sample 前预检采样数上限——防 spacing 过小（>validate 的 _EPS 但仍极小）/ count 过大，
	# 导致 sample 内部 while/for 全量生成海量点后才被 BATCH_LIMIT 拒（单帧 OOM/卡帧，违反"全同步单帧"安全前提）。
	# 预估为粗略上界（spacing 模式 total/spacing，count 模式 count）；放行则 sample 仍受下方 BATCH_LIMIT 二次拦截
	var pre_total := PathGenerator._total_length(points)
	var pre_est: int = 0
	if spacing > 0.0:
		pre_est = int(pre_total / spacing) + 2  # +2 端点余量（discrete 上界；continuous 段数更少，安全）
	elif count >= 1:
		pre_est = count + 1
	if pre_est > AssetForgeServer.BATCH_LIMIT:
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				(
					"采样点预估 %d 超过上限 %d（缩短路径/增大 spacing/减少 count）"
					% [pre_est, AssetForgeServer.BATCH_LIMIT]
				)
			},
			ws
		)
		return
	var samples: Array = PathGenerator.sample(
		points, spacing, count, align, include_endpoints, mode, align_vertices
	)
	# A7：samples 空（continuous 短曲线 0 段 / spacing 过大）→ invalid_params（防 client 卡死）
	if samples.is_empty():
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message": "采样点为 0（路径太短 / spacing 过大 / continuous + total<spacing），无法生成"
			},
			ws
		)
		return
	if samples.size() > AssetForgeServer.BATCH_LIMIT:
		_server.send_result(
			req_id,
			false,
			{
				"error": "invalid_params",
				"message":
				(
					"samples 上限 %d，实际 %d（缩短路径/增大 spacing/减少 count）"
					% [AssetForgeServer.BATCH_LIMIT, samples.size()]
				)
			},
			ws
		)
		return
	var shape: String = String(payload.get("shape", ""))
	var base_params: Dictionary = payload.get("params", {})
	# continuous 模式 shape 白名单（length 沿 X）
	if mode == "continuous" and shape != "wall" and shape != "fence" and shape != "ramp":
		_server.send_result(
			req_id,
			false,
			{
				"error": "unsupported_shape",
				"message": "continuous 模式仅支持 wall/fence/ramp（length 沿 X），当前 " + shape
			},
			ws
		)
		return
	# v11.5：continuous 段是一次性几何，probe + 段循环走 uncached 不污染 _cache（防长路径无界膨胀）；
	# discrete 共享 probe_mesh 故仍走缓存 create_mesh（跨命令复用 base mesh）
	var probe_mesh = (
		AssetFactory.create_mesh_uncached(shape, base_params)
		if mode == "continuous"
		else AssetFactory.create_mesh(shape, base_params)
	)
	if probe_mesh == null:
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
	var base_name: String = String(payload.get("name", ""))
	if base_name == "":
		base_name = shape
	# P0-2：仅当至少一段 place 成功才 mark_scene_as_unsaved（与单件 generate 一致，避免全失败时污染场景脏标记）
	var any_success := false
	if mode == "discrete":
		for i in samples.size():
			var s: Dictionary = samples[i]
			var ok := _place_one(
				PlaceSpec.create(
					root,
					probe_mesh,
					material,
					base_name,
					i,
					s["position"],
					s["rotation_deg"],
					payload,
					batch_id,
					samples.size(),  # v3：total
					req_id,
					ws
				)
			)
			if ok:
				any_success = true
	else:  # continuous：每段独立 create_mesh（length + fence 端柱 / ramp 高度注入）
		var seg_count: int = samples.size()
		# v6：ramp 高度衔接，循环外算一次（仅 ramp 用，弧长基础非弦长）
		var ramp_heights: Array = []
		if shape == "ramp":
			var rise: float = float(base_params.get("height", 1.0))
			var total_len: float = PathGenerator._total_length(points)
			ramp_heights = PathGenerator._compute_seg_heights(samples, total_len, rise)
		for i in seg_count:
			var seg: Dictionary = samples[i]
			var seg_params: Dictionary = base_params.duplicate()
			seg_params["length"] = seg["length"]
			if shape == "fence":
				# v5 端柱共享：所有段保首柱（=接缝柱），仅末段保末柱（=终点柱），
				# 其他段去末柱（避免与下段首柱重叠 z-fighting）。discrete/单件不注入，零回归。
				seg_params["start_post"] = true
				seg_params["end_post"] = i == seg_count - 1
			elif shape == "ramp":
				# v6 高度衔接（_compute_seg_heights 循环外预算，弧长比例，恒定坡度）
				seg_params["start_height"] = float(ramp_heights[i]["start_h"])
				seg_params["end_height"] = float(ramp_heights[i]["end_h"])
			var seg_mesh := AssetFactory.create_mesh_uncached(shape, seg_params)  # v11.5：段 mesh 不进 _cache（一次性几何）
			var seg_ok := _place_one(
				PlaceSpec.create(
					root,
					seg_mesh,
					material,
					base_name,
					i,
					seg["position"],
					seg["rotation_deg"],
					payload,
					batch_id,
					seg_count,  # v3：total
					req_id,
					ws
				)
			)
			if seg_ok:
				any_success = true
	if any_success:
		# P1-5：mark 前校验 root 仍有效且是当前场景（防场景切换竞态）
		if ScenePlacer.can_mark_scene(root, _get_root.call()):
			_mark_unsaved.call()


# _place_one：构造 place_payload + ScenePlacer.place + send_result（discrete/continuous 共用，消除 loop 重复）
# V3-1（2026-11-19）：11 个位置参数收敛为 PlaceSpec（防呆构造期校验），单参签名
func _place_one(spec: PlaceSpec) -> bool:
	# P0-2：返回成功与否，调用方累计 any_success 决定是否 mark_scene_as_unsaved
	if spec == null:
		# PlaceSpec.create 拒绝（缺必填已 push_error）。此处无从补失败回执——
		# req_id/ws/total 全在 spec 内，null 即信息全失。上游预校验（root:116/
		# probe_mesh:233-250/base_name:253-254 兜底）保证生产不可达；若未来放宽
		# 必填校验，须在两个调用点（discrete/continuous 循环内）对 null 补发
		# 失败回执，否则 client 按 total 计数会缺条（终审 M-7 契约记录）。
		return false
	var pos: Vector3 = spec.pos
	var rot: Vector3 = spec.rot
	var place_payload := {
		"name": "%s_%d" % [spec.base_name, spec.index],
		"transform": {"position": [pos.x, pos.y, pos.z], "rotation_deg": [rot.x, rot.y, rot.z]},
		"parent": spec.payload.get("parent", ""),
		"save": spec.payload.get("save", false),
	}
	var r := ScenePlacer.place(
		spec.root, spec.mesh, spec.material, place_payload, _undo_stack, spec.batch_id
	)
	if bool(r["success"]):
		_server.send_result(
			spec.req_id,
			true,
			{
				"node_path": String(r["node_path"]),
				"resource_path": String(r["resource_path"]),
				"total": spec.total  # v3 新增（D 方案：client 收第一条读 total 收齐）
			},
			spec.ws
		)
		if _dock_add.is_valid():
			_dock_add.call(String(place_payload["name"]), String(r["node_path"]))
		return true  # P0-2：成功（调用方累计 any_success）
	_server.send_result(
		spec.req_id,
		false,
		{"error": String(r["error"]), "message": "place 失败", "total": spec.total},
		spec.ws
	)
	return false  # P0-2：失败
