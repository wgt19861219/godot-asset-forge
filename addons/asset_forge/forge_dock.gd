# forge_dock.gd
# Asset Forge Dock UI：端口 / 连接 / token 路径 / 已生成清单 / 日志 / 启停。
@tool
class_name AssetForgeDock
extends Control

signal start_server_pressed
signal stop_server_pressed

const MAX_LOG_LINES: int = 100

var _start_stop_btn: Button
var _port_label: Label
var _conn_label: Label
var _token_label: Label
var _generated_list: ItemList
var _log_edit: TextEdit
var _is_connected: bool = false
var _server_running: bool = false
var _log_lines: Array = []

func _ready() -> void:
	_build_ui()

func set_server_running(running: bool) -> void:
	_server_running = running
	if is_instance_valid(_start_stop_btn):
		var key: int = AssetForgeLocalization.Key.STOP_SERVER if running else AssetForgeLocalization.Key.START_SERVER
		_start_stop_btn.text = AssetForgeLocalization.get_text(key)
	_refresh_connection()

func update_connection(connected: bool) -> void:
	_is_connected = connected
	_refresh_connection()

func set_token_path(path: String) -> void:
	if is_instance_valid(_token_label):
		_token_label.text = path if path != "" else "（未启动）"

func append_log(msg: String) -> void:
	_log_lines.append(msg)
	if _log_lines.size() > MAX_LOG_LINES:
		_log_lines.pop_front()
	if is_instance_valid(_log_edit):
		_log_edit.text = "\n".join(_log_lines)
		_log_edit.scroll_vertical = _log_edit.get_line_count()

func add_to_generated_list(name: String, node_path: String) -> void:
	if is_instance_valid(_generated_list):
		_generated_list.add_item("%s  →  %s" % [name, node_path])

func clear_list() -> void:
	if is_instance_valid(_generated_list):
		_generated_list.clear()

func _refresh_connection() -> void:
	if not is_instance_valid(_conn_label):
		return
	if _is_connected:
		_conn_label.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.CONNECTED)
		_conn_label.add_theme_color_override("font_color", Color.GREEN)
	elif _server_running:
		_conn_label.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.LISTENING)
		_conn_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
	else:
		_conn_label.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.DISCONNECTED)
		_conn_label.add_theme_color_override("font_color", Color.RED)

func _build_ui() -> void:
	custom_minimum_size = Vector2(320, 480)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	# 标题
	var title := Label.new()
	title.text = "Asset Forge"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)
	# 启停
	_start_stop_btn = Button.new()
	_start_stop_btn.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.START_SERVER)
	_start_stop_btn.pressed.connect(_on_start_stop)
	root.add_child(_start_stop_btn)
	# 端口 / 连接 / token
	_port_label = _make_row(root, "端口", "60650")
	var conn_row := HBoxContainer.new()
	_make_key(conn_row, "客户端:")
	_conn_label = Label.new()
	conn_row.add_child(_conn_label)
	root.add_child(conn_row)
	_token_label = _make_row(root, AssetForgeLocalization.get_text(AssetForgeLocalization.Key.TOKEN_INFO), "（未启动）")
	# 已生成清单
	var gen_header := Label.new()
	gen_header.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.GENERATED_LIST)
	root.add_child(gen_header)
	_generated_list = ItemList.new()
	_generated_list.custom_minimum_size = Vector2(0, 120)
	_generated_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_generated_list)
	# 日志
	var log_header := HBoxContainer.new()
	var lh := Label.new()
	lh.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.MESSAGE_LOG)
	lh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_header.add_child(lh)
	var clear_btn := Button.new()
	clear_btn.text = AssetForgeLocalization.get_text(AssetForgeLocalization.Key.CLEAR)
	clear_btn.pressed.connect(_on_clear_log)
	log_header.add_child(clear_btn)
	root.add_child(log_header)
	_log_edit = TextEdit.new()
	_log_edit.editable = false
	_log_edit.custom_minimum_size = Vector2(0, 200)
	_log_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log_edit)

func _make_row(parent: Control, key: String, value: String) -> Label:
	var row := HBoxContainer.new()
	_make_key(row, key + ":")
	var v := Label.new()
	v.text = value
	row.add_child(v)
	parent.add_child(row)
	return v

func _make_key(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(96, 0)
	parent.add_child(l)

func _on_start_stop() -> void:
	if _server_running:
		stop_server_pressed.emit()
	else:
		start_server_pressed.emit()

func _on_clear_log() -> void:
	_log_lines.clear()
	if is_instance_valid(_log_edit):
		_log_edit.text = ""
