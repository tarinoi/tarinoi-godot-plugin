@tool
extends EditorPlugin

const CREDENTIALS_PATH := "user://tarinoi/.credentials"

var _importer: TarinoiImporter = null
var _api_importer: TarinoiApiImporter = null


func _enter_tree() -> void:
	_register_settings()
	add_autoload_singleton("TarinoiRuntime", "res://addons/tarinoi/autoload/TarinoiRuntime.gd")
	add_tool_menu_item("Tarinoi: Initialize project",       _on_initialize_pressed)
	add_tool_menu_item("Tarinoi: Clone / Sync",             _on_sync_pressed)
	add_tool_menu_item("Tarinoi: Snapshot for Export",      _on_snapshot_pressed)
	add_tool_menu_item("Tarinoi: Regenerate Bindings",      _on_regen_pressed)
	add_tool_menu_item("Tarinoi: Validate Bindings",        _on_validate_pressed)
	add_tool_menu_item("Tarinoi: Set Git access token…",    _on_set_token_pressed)
	add_tool_menu_item("Tarinoi: Set Tarinoi API token…",   _on_set_api_key_pressed)
	add_tool_menu_item("Tarinoi: Clear local data",         _on_clear_data_pressed)


func _exit_tree() -> void:
	remove_autoload_singleton("TarinoiRuntime")
	remove_tool_menu_item("Tarinoi: Initialize project")
	remove_tool_menu_item("Tarinoi: Clone / Sync")
	remove_tool_menu_item("Tarinoi: Snapshot for Export")
	remove_tool_menu_item("Tarinoi: Regenerate Bindings")
	remove_tool_menu_item("Tarinoi: Validate Bindings")
	remove_tool_menu_item("Tarinoi: Set Git access token…")
	remove_tool_menu_item("Tarinoi: Set Tarinoi API token…")
	remove_tool_menu_item("Tarinoi: Clear local data")


# ---------------------------------------------------------------------------
# Initialize project
# ---------------------------------------------------------------------------

func _on_initialize_pressed() -> void:
	var tscn_dest := "res://tarinoi_quickstart.tscn"
	var gd_dest   := "res://tarinoi_quickstart.gd"

	if ResourceLoader.exists(tscn_dest):
		var d := AcceptDialog.new()
		d.title = "Tarinoi: Initialize"
		d.dialog_text = "res://tarinoi_quickstart.tscn already exists.\n\nDelete it first if you want to reinitialize."
		d.min_size = Vector2i(420, 0)
		EditorInterface.get_base_control().add_child(d)
		d.popup_centered()
		d.confirmed.connect(d.queue_free)
		return

	var tscn_content := """[gd_scene format=3]

[ext_resource type="PackedScene" path="res://addons/tarinoi/scenes/tarinoi_quickstart.tscn" id="1"]
[ext_resource type="Script" path="res://tarinoi_quickstart.gd" id="2"]

[node name="TarinoiQuickStart" instance=ExtResource("1")]
script = ExtResource("2")
"""
	var tscn_file := FileAccess.open(tscn_dest, FileAccess.WRITE)
	if tscn_file == null:
		push_error("Tarinoi: failed to write " + tscn_dest)
		return
	tscn_file.store_string(tscn_content)
	tscn_file = null

	var gd_content := """extends "res://addons/tarinoi/scenes/tarinoi_quickstart.gd"


## Override this to register your game's bindings before sync runs.
## Example:
##   func _setup_bindings() -> void:
##       var vars := MyVariables.new()
##       TarinoiRuntime.registry.bind_variable_collection("global", vars)
##       TarinoiRuntime.registry.bind_function_collection("global", MyFunctions.new(vars))
func _setup_bindings() -> void:
\tpass
"""
	var gd_file := FileAccess.open(gd_dest, FileAccess.WRITE)
	if gd_file == null:
		push_error("Tarinoi: failed to write " + gd_dest)
		return
	gd_file.store_string(gd_content)
	gd_file = null

	EditorInterface.get_resource_filesystem().scan()

	var d := AcceptDialog.new()
	d.title = "Tarinoi: Initialize"
	d.dialog_text = "Created:\n  res://tarinoi_quickstart.tscn\n  res://tarinoi_quickstart.gd\n\nSet res://tarinoi_quickstart.tscn as your main scene (Project > Project Settings > Application > Run > Main Scene) and press Play."
	d.min_size = Vector2i(500, 0)
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered()
	d.confirmed.connect(d.queue_free)


# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

func _on_sync_pressed() -> void:
	var sync_source: String = ProjectSettings.get_setting("tarinoi/sync_source", "git")
	if sync_source == "api":
		_do_api_sync()
	else:
		_do_git_sync()


func _do_git_sync() -> void:
	var repo_url: String = ProjectSettings.get_setting("tarinoi/repo_url", "")
	if repo_url.is_empty():
		push_error("Tarinoi: set tarinoi/repo_url in Project Settings first")
		return
	_importer = TarinoiImporter.new()
	_importer.sync_started.connect(func(): print("Tarinoi: sync started…"))
	_importer.sync_progress.connect(func(msg, _f): print("Tarinoi: ", msg))
	_importer.sync_completed.connect(func(stats: Dictionary):
		print("Tarinoi: sync complete — ", stats)
		if ProjectSettings.get_setting("tarinoi/codegen_on_sync", false):
			var db := _open_db()
			if db:
				TarinoiCodegen.new().run(db)
				db.close()
	)
	_importer.sync_failed.connect(func(reason): push_error("Tarinoi sync failed — " + reason))
	_importer.sync(repo_url)


func _do_api_sync() -> void:
	var api_path: String = ProjectSettings.get_setting("tarinoi/api_path", "")
	if api_path.is_empty():
		push_error("Tarinoi: set tarinoi/api_path in Project Settings first")
		return
	_api_importer = TarinoiApiImporter.new()
	_api_importer.sync_started.connect(func(): print("Tarinoi: API sync started…"))
	_api_importer.sync_progress.connect(func(msg, _f): print("Tarinoi: ", msg))
	_api_importer.sync_completed.connect(func(stats: Dictionary):
		print("Tarinoi: API sync complete — ", stats)
		if ProjectSettings.get_setting("tarinoi/codegen_on_sync", false):
			var db := _open_db()
			if db:
				TarinoiCodegen.new().run(db)
				db.close()
	)
	_api_importer.sync_failed.connect(func(reason): push_error("Tarinoi API sync failed — " + reason))
	_api_importer.sync(api_path)


# ---------------------------------------------------------------------------
# Snapshot for Export
# ---------------------------------------------------------------------------

func _on_snapshot_pressed() -> void:
	var sync_source: String = ProjectSettings.get_setting("tarinoi/sync_source", "git")
	var project_id: String
	if sync_source == "api":
		var api_path: String = ProjectSettings.get_setting("tarinoi/api_path", "")
		if api_path.is_empty():
			push_error("Tarinoi: set tarinoi/api_path in Project Settings first")
			return
		project_id = api_path.trim_suffix("/").trim_suffix("/documents").get_file()
	else:
		var repo_url: String = ProjectSettings.get_setting("tarinoi/repo_url", "")
		if repo_url.is_empty():
			push_error("Tarinoi: set tarinoi/repo_url in Project Settings first")
			return
		project_id = repo_url.get_file().trim_suffix(".git")
	if project_id.is_empty():
		push_error("Tarinoi: cannot derive project_id")
		return

	var src := ProjectSettings.globalize_path("user://tarinoi/" + project_id + ".db")
	if not FileAccess.file_exists(src):
		push_error("Tarinoi: no local DB at '%s' — run Sync first" % src)
		return

	var dest_dir := "res://tarinoi/bundled"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest_dir))

	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		push_error("Tarinoi: could not read source DB at '%s'" % src)
		return

	var dest_path := dest_dir + "/" + project_id + ".db"
	var wf := FileAccess.open(dest_path, FileAccess.WRITE)
	if wf == null:
		push_error("Tarinoi: could not write snapshot to '%s'" % dest_path)
		return
	wf.store_buffer(bytes)
	wf = null  # close before reopening with SQLite

	# Scrub development-environment metadata from the snapshot.
	# api_path and api_sync_cursor are dev artifacts with no place in an offline build.
	var abs_dest := ProjectSettings.globalize_path(dest_path)
	var scrub := SQLite.new()
	scrub.path = abs_dest
	scrub.verbosity_level = SQLite.QUIET
	if scrub.open_db():
		scrub.query("DELETE FROM metadata WHERE key IN ('api_path', 'api_sync_cursor')")
		scrub.close_db()

	print("Tarinoi: snapshot written — %d bytes → '%s'" % [bytes.size(), dest_path])


# ---------------------------------------------------------------------------
# Codegen
# ---------------------------------------------------------------------------

func _on_regen_pressed() -> void:
	var db := _open_db()
	if db == null:
		return
	TarinoiCodegen.new().run(db)
	db.close()


func _on_validate_pressed() -> void:
	var db := _open_db()
	if db == null:
		return
	TarinoiCodegen.new().validate_only(db)
	db.close()


func _open_db() -> TarinoiDB:
	var sync_source: String = ProjectSettings.get_setting("tarinoi/sync_source", "git")
	var project_id: String
	if sync_source == "api":
		var api_path: String = ProjectSettings.get_setting("tarinoi/api_path", "")
		if api_path.is_empty():
			push_error("Tarinoi: set tarinoi/api_path in Project Settings first")
			return null
		var stripped := api_path.trim_suffix("/").trim_suffix("/documents")
		project_id = stripped.get_file()
	else:
		var repo_url: String = ProjectSettings.get_setting("tarinoi/repo_url", "")
		if repo_url.is_empty():
			push_error("Tarinoi: set tarinoi/repo_url in Project Settings first")
			return null
		project_id = repo_url.get_file().trim_suffix(".git")

	if project_id.is_empty():
		push_error("Tarinoi: cannot derive project_id")
		return null
	var db := TarinoiDB.new()
	if not db.open(project_id):
		push_error("Tarinoi: failed to open DB for project '%s' — run Sync first" % project_id)
		return null
	return db


# ---------------------------------------------------------------------------
# Set Token dialog
# ---------------------------------------------------------------------------

func _on_set_token_pressed() -> void:
	_show_credential_dialog(
		"Tarinoi: Set Access Token",
		"Enter your GitLab personal access token.",
		"Token already saved. Enter a new value to replace it.",
		"glpat-xxxxxxxxxxxxxxxxxxxx",
		"token"
	)


# ---------------------------------------------------------------------------
# Set API Key dialog
# ---------------------------------------------------------------------------

func _on_set_api_key_pressed() -> void:
	_show_credential_dialog(
		"Tarinoi: Set API Key",
		"Enter your Tarinoi REST API key.",
		"API key already saved. Enter a new value to replace it.",
		"tarinoi-xxxx…",
		"api_key"
	)


func _show_credential_dialog(title: String, prompt_new: String, prompt_existing: String,
		placeholder: String, cred_key: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.min_size = Vector2i(400, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)

	var has_key := _credential_is_saved(cred_key)
	var status := Label.new()
	status.text = prompt_existing if has_key else prompt_new
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status)

	var input := LineEdit.new()
	input.secret = true
	input.placeholder_text = placeholder
	input.custom_minimum_size = Vector2i(0, 30)
	vbox.add_child(input)

	dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

	dialog.confirmed.connect(func():
		var value := input.text.strip_edges()
		if not value.is_empty():
			_save_credential(cred_key, value)
			_refresh_credential_status()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())


# ---------------------------------------------------------------------------
# Clear local data
# ---------------------------------------------------------------------------

func _on_clear_data_pressed() -> void:
	var sync_source: String = ProjectSettings.get_setting("tarinoi/sync_source", "git")
	var project_id: String
	if sync_source == "api":
		var api_path: String = ProjectSettings.get_setting("tarinoi/api_path", "")
		if api_path.is_empty():
			push_error("Tarinoi: set tarinoi/api_path in Project Settings first")
			return
		var stripped := api_path.trim_suffix("/").trim_suffix("/documents")
		project_id = stripped.get_file()
	else:
		var repo_url: String = ProjectSettings.get_setting("tarinoi/repo_url", "")
		if repo_url.is_empty():
			push_error("Tarinoi: set tarinoi/repo_url in Project Settings first")
			return
		project_id = repo_url.get_file().trim_suffix(".git")

	if project_id.is_empty():
		push_error("Tarinoi: cannot derive project_id for clear")
		return

	var db_path   := ProjectSettings.globalize_path("user://tarinoi/" + project_id + ".db")
	var repo_path := ProjectSettings.globalize_path("user://tarinoi/repos/" + project_id)

	if FileAccess.file_exists(db_path):
		DirAccess.remove_absolute(db_path)
		print("Tarinoi: removed DB — ", db_path)
	if DirAccess.dir_exists_absolute(repo_path):
		OS.move_to_trash(repo_path)
		print("Tarinoi: removed cloned repo — ", repo_path)
	print("Tarinoi: local data cleared for project '%s'" % project_id)


# ---------------------------------------------------------------------------
# Credentials helpers
# ---------------------------------------------------------------------------

func _save_credential(key: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://tarinoi")
	)
	# Read existing lines, replace matching key or append.
	var lines: PackedStringArray = PackedStringArray()
	var found := false
	if FileAccess.file_exists(CREDENTIALS_PATH):
		var rf := FileAccess.open(CREDENTIALS_PATH, FileAccess.READ)
		if rf:
			while not rf.eof_reached():
				var line := rf.get_line()
				if line.strip_edges().to_lower().begins_with(key.to_lower() + "="):
					lines.append(key + "=" + value)
					found = true
				else:
					lines.append(line)
	if not found:
		lines.append(key + "=" + value)

	var wf := FileAccess.open(CREDENTIALS_PATH, FileAccess.WRITE)
	if wf == null:
		push_error("Tarinoi: failed to write credentials file")
		return
	for line in lines:
		if not line.strip_edges().is_empty():
			wf.store_line(line)
	print("Tarinoi: saved credential '%s'" % key)


func _credential_is_saved(key: String) -> bool:
	if not FileAccess.file_exists(CREDENTIALS_PATH):
		return false
	var file := FileAccess.open(CREDENTIALS_PATH, FileAccess.READ)
	if file == null:
		return false
	var prefix := key.to_lower() + "="
	while not file.eof_reached():
		if file.get_line().strip_edges().to_lower().begins_with(prefix):
			return true
	return false



# ---------------------------------------------------------------------------
# ProjectSettings
# ---------------------------------------------------------------------------

func _register_settings() -> void:
	_add_setting("tarinoi/repo_url",             TYPE_STRING, "")
	_add_setting("tarinoi/auto_sync",            TYPE_BOOL,   false)
	_add_setting("tarinoi/sync_source",          TYPE_STRING, "git")
	ProjectSettings.add_property_info({
		"name": "tarinoi/sync_source",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "git,api",
	})
	_add_setting("tarinoi/api_path",             TYPE_STRING, "")
	_add_setting("tarinoi/committed_only",       TYPE_BOOL,   false)
	_add_setting("tarinoi/api_skip_tls_verify",  TYPE_BOOL,   false)
	_add_setting("tarinoi/api_poll_enabled",     TYPE_BOOL,   false)
	_add_setting("tarinoi/api_poll_interval",    TYPE_INT,    10)
	_add_setting("tarinoi/demo_collection_id",   TYPE_STRING, "")
	_add_setting("tarinoi/demo_start_card_id",   TYPE_STRING, "")
	_add_setting("tarinoi/codegen_output_path",  TYPE_STRING, "res://demo/bindings/generated/")
	_add_setting("tarinoi/codegen_on_sync",      TYPE_BOOL,   false)
	_add_setting("tarinoi/offline_mode",         TYPE_BOOL,   false)
	_add_setting("tarinoi/log_level",            TYPE_INT,    TarinoiLogger.Level.INFO)
	_add_setting("tarinoi/data_provider",        TYPE_STRING, "")
	ProjectSettings.add_property_info({
		"name": "tarinoi/data_provider",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.gd",
	})
	ProjectSettings.add_property_info({
		"name":        "tarinoi/log_level",
		"type":        TYPE_INT,
		"hint":        PROPERTY_HINT_ENUM,
		"hint_string": "DEBUG:0,INFO:1,WARN:2,ERROR:3,OFF:4",
	})

	# Read-only status fields — updated dynamically; never stored in project.godot.
	for cred_field in ["tarinoi/git_token", "tarinoi/api_token"]:
		if not ProjectSettings.has_setting(cred_field):
			ProjectSettings.set_setting(cred_field, "")
		ProjectSettings.set_initial_value(cred_field, "")
		ProjectSettings.add_property_info({
			"name": cred_field,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_NONE,
			"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY,
		})
	_refresh_credential_status()


func _refresh_credential_status() -> void:
	var git_status := "saved — change via Tools > Tarinoi: Set Git access token…" \
		if _credential_is_saved("token") \
		else "not set — use Tools > Tarinoi: Set Git access token…"
	var api_status := "saved — change via Tools > Tarinoi: Set Tarinoi API token…" \
		if _credential_is_saved("api_key") \
		else "not set — use Tools > Tarinoi: Set Tarinoi API token…"
	ProjectSettings.set_setting("tarinoi/git_token", git_status)
	ProjectSettings.set_setting("tarinoi/api_token",  api_status)


func _add_setting(name: String, type: int, default: Variant) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type})
