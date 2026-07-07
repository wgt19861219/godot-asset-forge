# log_helper.gd
# Asset Forge 集中式日志（带时间戳，stdout 输出）。
# P2-9：原 logged 信号 + _instance 单例已移除——信号全仓无人 connect（死信号），
# 单例持 RefCounted 永不释放；日志只 print stdout（dock 日志区走 server.log_emitted，不经此）。
@tool
class_name LogHelper
extends RefCounted

const LOG_PREFIX := "[Asset Forge]"


static func format_message(message: String) -> String:
	return "%s [%s] %s" % [LOG_PREFIX, Time.get_time_string_from_system(), message]


static func log(message: String, enabled: bool = true) -> void:
	if not enabled:
		return
	print(format_message(message))


static func error(message: String, enabled: bool = true) -> void:
	LogHelper.log("ERROR: " + message, enabled)


static func warning(message: String, enabled: bool = true) -> void:
	LogHelper.log("WARNING: " + message, enabled)
