@tool
extends EditorExportPlugin
## Ships the Snapshot for Export database with every export. Godot's export
## filters only pick up resources, so a .db under res:// is otherwise left out
## and an offline build starts with no dialogue.

const BUNDLED_DIR := "res://tarinoi/bundled"


func _get_name() -> String:
	return "Tarinoi"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var shipped := 0
	var dir := DirAccess.open(BUNDLED_DIR)
	if dir:
		for file in dir.get_files():
			if file.get_extension() == "db":
				var path := BUNDLED_DIR + "/" + file
				add_file(path, FileAccess.get_file_as_bytes(path), false)
				shipped += 1
	if shipped == 0 and ProjectSettings.get_setting("tarinoi/behaviour/offline_mode", false):
		TarinoiLogger.warn("offline_mode is on but %s has no snapshot — run Tarinoi: Snapshot for Export, or the build starts with no dialogue" % BUNDLED_DIR)
