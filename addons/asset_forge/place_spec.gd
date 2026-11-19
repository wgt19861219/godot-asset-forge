class_name PlaceSpec
extends RefCounted
## PlaceSpec：_place_one 的防呆参数对象（V3-1，2026-11-19）。
## 原 _place_one 11 个位置参数易传错序；收敛为具名属性 + static factory 构造期校验——
## 缺必填字段（root/mesh/base_name/payload/ws）返回 null 并 push_error，错误用法到不了放置层。
## 注意：这是构造期校验而非编译期防呆（GDScript 无编译期不可表示构造）。
## material 可为 null（AssetFactory.create_material 容忍）；rot 缺省 Vector3.ZERO。

var root: Node
var mesh: Mesh
var material: Material  # 可空
var base_name: String
var index: int
var pos: Vector3
var rot: Vector3
var payload: Dictionary
var batch_id: int
var total: int
var req_id: String
var ws: WebSocketPeer


static func create(
	p_root: Node,
	p_mesh: Mesh,
	p_material: Material,
	p_base_name: String,
	p_index: int,
	p_pos: Variant,
	p_rot: Variant,
	p_payload: Dictionary,
	p_batch_id: int,
	p_total: int,
	p_req_id: String,
	p_ws: WebSocketPeer
) -> PlaceSpec:
	if p_root == null or p_mesh == null or p_base_name == "" or p_ws == null:
		push_error("PlaceSpec.create 缺必填字段（root/mesh/base_name/ws 不可为空）")
		return null
	var s := PlaceSpec.new()
	s.root = p_root
	s.mesh = p_mesh
	s.material = p_material
	s.base_name = p_base_name
	s.index = p_index
	s.pos = p_pos
	s.rot = p_rot if p_rot != null else Vector3.ZERO
	s.payload = p_payload if p_payload != null else {}
	s.batch_id = p_batch_id
	s.total = p_total
	s.req_id = p_req_id
	s.ws = p_ws
	return s
