class_name TarinoiLogger

enum Level { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3, OFF = 4 }

const _SETTING = "tarinoi/behaviour/log_level"

# BBCode color tags for DEBUG and INFO — printed via print_rich().
# WARN and ERROR use push_warning/push_error (Godot colors them in Output + Debugger).
const _DEBUG_TAG = "[color=#888888][DEBUG][/color]"
const _INFO_TAG  = "[color=#4d9de0][INFO] [/color]"


static func debug(msg: String) -> void:
	if _level() <= Level.DEBUG:
		print_rich("%s [Tarinoi] %s" % [_DEBUG_TAG, msg])


static func info(msg: String) -> void:
	if _level() <= Level.INFO:
		print_rich("%s [Tarinoi] %s" % [_INFO_TAG, msg])


static func warn(msg: String) -> void:
	if _level() <= Level.WARN:
		push_warning("[WARN]  [Tarinoi] " + msg)


static func error(msg: String) -> void:
	if _level() <= Level.ERROR:
		push_error("[ERROR] [Tarinoi] " + msg)


static func _level() -> int:
	return ProjectSettings.get_setting(_SETTING, Level.INFO) as int
