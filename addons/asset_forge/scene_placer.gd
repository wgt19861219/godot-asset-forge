# scene_placer.gd
# MeshInstance3D 放置 / transform / owner / 存 .tscn / undo_last（IMPORTANT-2）
@tool
class_name ScenePlacer
extends RefCounted

const GENERATED_DIR := "res://GeneratedAssets"


# place：返回 {success, node_path, resource_path, error}
static func place(
	root: Node,
	mesh: Mesh,
	material: Material,
	payload: Dictionary,
	undo_stack: Array,
	batch_id: int
) -> Dictionary:
	if root == null:
		return {"success": false, "node_path": "", "resource_path": "", "error": "no_active_scene"}
	var parent: Node = _resolve_parent(root, String(payload.get("parent", "")))
	if parent == null:
		return {"success": false, "node_path": "", "resource_path": "", "error": "parent_not_found"}
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if material != null:
		mi.material_override = material
	mi.name = _unique_node_name(parent, String(payload.get("name", "asset")))
	_apply_transform(mi, payload.get("transform", {}))
	parent.add_child(mi)
	mi.owner = root  # owner=场景根，保存场景时包含本节点
	var entry := {"node": mi, "parent": parent, "batch_id": batch_id, "saved_path": ""}
	undo_stack.append(entry)
	var res_path: String = ""
	if bool(payload.get("save", false)):
		res_path = _save_as_tscn(mi, mi.name)
		entry["saved_path"] = res_path
	# owner 链上的 NodePath（无 owner 或未入树时退化为相对父路径，--script 下 Viewport 未全初始化时 get_path 报错）
	var node_path: String = ""
	if mi.is_inside_tree():
		node_path = str(mi.get_path())
	else:
		node_path = str(parent.get_path_to(mi)) if parent.is_inside_tree() else mi.name
	return {"success": true, "node_path": node_path, "resource_path": res_path, "error": ""}


# undo_last：仅 queue_free 场景节点，绝不删 .tscn（IMPORTANT-2）；batch 原子（Q4）
static func undo_last(undo_stack: Array) -> Dictionary:
	if undo_stack.is_empty():
		return {"success": false, "freed": 0, "error": "nothing_to_undo"}
	var batch_id: int = int(undo_stack[undo_stack.size() - 1]["batch_id"])
	var freed: int = 0
	while not undo_stack.is_empty():
		var top: Dictionary = undo_stack[undo_stack.size() - 1]
		if int(top["batch_id"]) != batch_id:
			break
		# P2#5：Variant 接收——节点可能已被用户 free，强类型 Node 赋值 freed instance 会 SCRIPT ERROR
		var node: Variant = top["node"]
		if is_instance_valid(node):
			(node as Node).queue_free()
			freed += 1  # 只在真释放时计数（节点已失效不计数，回执 freed 忠实反映场景变化）
		undo_stack.pop_back()
	# 注：不删 top["saved_path"]——.tscn 是用户可复用资产，undo 只撤场景节点
	return {"success": true, "freed": freed, "error": ""}


# --- helpers ---


static func _resolve_parent(root: Node, parent_path: String) -> Node:
	if parent_path.is_empty():
		return root
	# 绝对路径 /Root/Xxx：root 通常就是路径首段（编辑器场景根 / 测试 mock root），
	# 直接走 get_node_or_null 会在 root 不被引擎视为"active scene"时（--script 模式）报错，
	# 改为剥掉首段，相对解析到 root 之下，兼容编辑器与 headless。
	if parent_path.begins_with("/"):
		var parts := parent_path.substr(1).split("/", false)
		if parts.size() == 0:
			return root
		# 首段等于 root.name（常见情况）→ 从 root 起；否则从 root 起按完整路径找
		if String(parts[0]) == root.name:
			parts.remove_at(0)
		if parts.size() == 0:
			return root
		return root.get_node_or_null(NodePath("/".join(parts)))
	return root.get_node_or_null(NodePath(parent_path))


# v3 path_node：读 Path3D 节点 → curve.baked_points → to_global（局部→世界）→ Array[Vector3]
# 失败返 {"points": [], "error": "..."}；成功返 {"points": Array[Vector3], "error": ""}
static func resolve_path3d(root: Node, path_node: String) -> Dictionary:
	var node: Node = _resolve_parent(root, path_node)
	if node == null:
		return {"points": [], "error": "path_node 节点未找到: " + path_node}
	if not (node is Path3D):
		return {"points": [], "error": "path_node 必须是 Path3D 节点，实际类型: " + node.get_class()}
	var path3d: Path3D = node as Path3D
	if path3d.curve == null:
		return {"points": [], "error": "Path3D curve 未设置（请在编辑器绘制曲线）"}
	var baked: PackedVector3Array = path3d.curve.get_baked_points()
	if baked.size() < 2:
		return {"points": [], "error": "Path3D curve baked points < 2（需至少 2 点定义路径）"}
	var points: Array = []
	for v in baked:
		points.append(path3d.to_global(v))  # 局部→世界坐标
	return {"points": points, "error": ""}


static func _unique_node_name(parent: Node, base_name: String) -> String:
	# P2-10：sanitize base_name（防 / .. 导致 NodePath 解析跳出兄弟 + Windows <>:"|?* 非法字符）
	var nm := _sanitize_name(base_name)
	if parent.get_node_or_null(NodePath(nm)) == null:
		return nm
	var i := 1
	while i <= 1000:
		var cand := "%s_%03d" % [nm, i]
		if parent.get_node_or_null(NodePath(cand)) == null:
			return cand
		i += 1
	return "%s_%d" % [nm, Time.get_ticks_msec()]


static func _apply_transform(node: Node3D, t: Variant) -> void:
	if not (t is Dictionary):
		return
	var d: Dictionary = t
	if d.has("position"):
		node.position = _vec3(d, "position")
	if d.has("rotation_deg"):
		node.rotation_degrees = _vec3(d, "rotation_deg")
	if d.has("scale"):
		node.scale = _vec3(d, "scale")


static func _vec3(d: Dictionary, key: String) -> Vector3:
	if not d.has(key):
		return Vector3.ZERO
	var arr: Variant = d[key]
	if arr is Array:
		var a := arr as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector3.ZERO
	if arr is PackedFloat64Array:  # A-1：补 PackedFloat64Array 分支，与 asset_factory._vec3 约定一致
		var a2 := arr as PackedFloat64Array
		return Vector3(a2[0], a2[1], a2[2]) if a2.size() >= 3 else Vector3.ZERO
	return Vector3.ZERO


# P2-10：sanitize 名字（节点名/文件名共用）——只留字母数字 + 下划线/连字符，其余替 '_'
# 防 ../../ 路径注入（跳出 GENERATED_DIR 覆盖项目 .tscn）+ Windows <>:"|?* 非法字符
static func _sanitize_name(name: String) -> String:
	var sanitized := ""
	for ch in name:
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			sanitized += ch
		else:
			sanitized += "_"
	if sanitized.is_empty():
		sanitized = "asset"
	return sanitized


static func _save_as_tscn(node: Node, name: String) -> String:
	# P2-10：检查 DirAccess 返回值（res:// 只读/权限不足不再静默继续 → 返 "" 让 client 知道）
	var dir_err := DirAccess.make_dir_recursive_absolute(GENERATED_DIR)
	if dir_err != OK:
		LogHelper.error("ScenePlacer: 创建目录失败 %s（err=%d）" % [GENERATED_DIR, dir_err])
		return ""
	var safe_name := _sanitize_name(name)  # P2-10：防 ../../ 路径注入 + Windows 非法字符
	var ps := PackedScene.new()
	if ps.pack(node) != OK:
		LogHelper.error("ScenePlacer: pack 失败 " + safe_name)
		return ""
	var path := GENERATED_DIR.path_join(safe_name + ".tscn")
	if ResourceSaver.save(ps, path) != OK:
		LogHelper.error("ScenePlacer: save 失败 " + path)
		return ""
	return path
