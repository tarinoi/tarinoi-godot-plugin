class_name TarinoiImporter
extends RefCounted

signal sync_started()
signal sync_completed(stats: Dictionary)
signal sync_failed(reason: String)
signal sync_progress(message: String, fraction: float)

const CREDENTIALS_FILE := "user://tarinoi/.credentials"

var _thread: Thread = null
var _version_check := TarinoiDataVersion.new()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Clone if needed, then do a full or incremental import into SQLite.
func sync(repo_url: String) -> void:
	if _is_busy():
		push_warning("TarinoiImporter: operation already in progress")
		return
	sync_started.emit()
	_thread = Thread.new()
	_thread.start(_thread_sync.bind(repo_url))


# ---------------------------------------------------------------------------
# Thread entry point + completion
# ---------------------------------------------------------------------------

func _thread_sync(repo_url: String) -> void:
	var result := _do_sync(repo_url)
	call_deferred("_on_thread_done", result)


func _on_thread_done(result: Dictionary) -> void:
	_join_thread()
	if result.has("error"):
		sync_failed.emit(result["error"])
	else:
		sync_completed.emit(result.get("stats", {}))


# ---------------------------------------------------------------------------
# Top-level sync logic (background thread)
# ---------------------------------------------------------------------------

func _do_sync(repo_url: String) -> Dictionary:
	var token := _read_token()
	if token.is_empty():
		return {"error": "No token found in .tarinoi_credentials (expected: token=<value>)"}

	if not _git_available():
		return {"error": "git not found — ensure git is installed and on PATH"}

	var project_id := _slug_from_url(repo_url)
	if project_id.is_empty():
		return {"error": "Cannot derive project slug from repo URL: %s" % repo_url}

	var local_path := _get_local_path(project_id)

	if not DirAccess.dir_exists_absolute(local_path.path_join(".git")):
		call_deferred("emit_signal", "sync_progress", "Cloning repository…", 0.0)
		var err := _git_clone(repo_url, local_path, token)
		if not err.is_empty():
			return {"error": err}

	var db := TarinoiDB.new()
	if not db.open(project_id):
		return {"error": "Failed to open SQLite database for '%s'" % project_id}

	db.write_meta("project_id", project_id)
	db.write_meta("repo_url", repo_url)

	var last_sha := db.read_meta("last_synced_commit")
	var result: Dictionary

	if last_sha.is_empty():
		call_deferred("emit_signal", "sync_progress", "Importing all documents…", 0.3)
		var head_sha := _git_rev_parse(local_path, "HEAD")
		var stats := _full_import(local_path, db)
		if stats.has("fatal_error"):
			result = {"error": stats["fatal_error"]}
		else:
			if not head_sha.is_empty():
				db.write_meta("last_synced_commit", head_sha)
			result = {"stats": stats}
	else:
		call_deferred("emit_signal", "sync_progress", "Fetching changes…", 0.2)
		result = _incremental_sync(local_path, last_sha, db)

	db.close()
	return result


# ---------------------------------------------------------------------------
# Incremental sync
# ---------------------------------------------------------------------------

func _incremental_sync(local_path: String, old_sha: String, db: TarinoiDB) -> Dictionary:
	var fetch_out: Array = []
	var exit := OS.execute("git", ["-C", local_path, "fetch", "origin"], fetch_out, true)
	if exit != 0:
		return {"error": "git fetch failed (exit %d): %s" % [exit, _join_output(fetch_out)]}

	var new_sha := _git_rev_parse(local_path, "FETCH_HEAD")
	if new_sha.is_empty():
		return {"error": "Could not resolve FETCH_HEAD after fetch"}

	var stats := _empty_stats()

	if new_sha == old_sha:
		stats["up_to_date"] = true
		return {"stats": stats}

	var diff_out: Array = []
	OS.execute("git", ["-C", local_path, "diff", old_sha, new_sha, "--name-only"], diff_out, false)
	var changed_files := _split_lines(diff_out)

	exit = OS.execute("git", ["-C", local_path, "reset", "--hard", "FETCH_HEAD"], [], true)
	if exit != 0:
		return {"error": "git reset --hard FETCH_HEAD failed"}

	call_deferred("emit_signal", "sync_progress", "Processing %d changed file(s)…" % changed_files.size(), 0.5)

	for rel_path in changed_files:
		if stats.has("fatal_error"):
			break
		var filename: String = (rel_path as String).get_file()
		var abs_path: String = local_path.path_join(rel_path)
		if not FileAccess.file_exists(abs_path):
			continue
		if filename == "collection.json":
			var col_data := _parse_json_file(abs_path)
			if col_data != null:
				_upsert_collection(col_data, db, stats)
		elif filename.match("b-???.json"):
			_import_bucket_file(abs_path, db, stats)

	if stats.has("fatal_error"):
		return {"error": stats["fatal_error"]}
	db.write_meta("last_synced_commit", new_sha)
	return {"stats": stats}


# ---------------------------------------------------------------------------
# Full import: walk repo, process every collection directory
# ---------------------------------------------------------------------------

func _full_import(repo_path: String, db: TarinoiDB) -> Dictionary:
	var stats := _empty_stats()
	_walk_for_collections(repo_path, db, stats)
	return stats


func _walk_for_collections(dir_path: String, db: TarinoiDB, stats: Dictionary) -> void:
	if FileAccess.file_exists(dir_path.path_join("collection.json")):
		_import_collection_dir(dir_path, db, stats)
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if stats.has("fatal_error"):
			break
		if dir.current_is_dir() and not entry.begins_with("."):
			_walk_for_collections(dir_path.path_join(entry), db, stats)
		entry = dir.get_next()
	dir.list_dir_end()


func _import_collection_dir(dir_path: String, db: TarinoiDB, stats: Dictionary) -> void:
	var col_data := _parse_json_file(dir_path.path_join("collection.json"))
	if col_data == null:
		stats["warnings"].append("Malformed collection.json in: %s" % dir_path)
		return

	_upsert_collection(col_data, db, stats)
	if stats.has("fatal_error"):
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if stats.has("fatal_error"):
			break
		if not dir.current_is_dir() and entry.match("b-???.json"):
			_import_bucket_file(dir_path.path_join(entry), db, stats)
		entry = dir.get_next()
	dir.list_dir_end()


func _import_bucket_file(file_path: String, db: TarinoiDB, stats: Dictionary) -> void:
	var data := _parse_json_file(file_path)
	if data == null or not data is Dictionary:
		stats["warnings"].append("Skipping malformed bucket file: %s" % file_path)
		return
	for doc in (data as Dictionary).values():
		if stats.has("fatal_error"):
			return
		if doc is Dictionary:
			_upsert_document(doc, db, stats)


# ---------------------------------------------------------------------------
# Upsert helpers
# ---------------------------------------------------------------------------

func _upsert_collection(data: Variant, db: TarinoiDB, stats: Dictionary) -> void:
	if not data is Dictionary:
		return
	var dv_err := _version_check.check((data as Dictionary).get("data_version"))
	if not dv_err.is_empty():
		stats["fatal_error"] = dv_err
		return
	var collection_id: String = data.get("document_id", "")
	var payload: Dictionary   = data.get("payload", {})
	if collection_id.is_empty():
		return
	db.execute(
		"INSERT OR REPLACE INTO collections (collection_id, collection_name, collection_type, payload) VALUES (?, ?, ?, ?)",
		[
			collection_id,
			payload.get("label", payload.get("collection_name", "")),
			payload.get("collection_type", ""),
			JSON.stringify(payload),
		]
	)
	stats["collections_updated"] += 1


func _upsert_document(doc: Dictionary, db: TarinoiDB, stats: Dictionary) -> void:
	var dv_err := _version_check.check(doc.get("data_version"))
	if not dv_err.is_empty():
		stats["fatal_error"] = dv_err
		return

	var doc_id: String = doc.get("document_id", "")
	var col_id: String = doc.get("collection_id", "")
	if doc_id.is_empty() or col_id.is_empty():
		return

	if doc.get("is_tombstone", false) or doc.get("is_archived", false) or doc.get("is_moved", false):
		db.execute(
			"DELETE FROM documents WHERE document_id = ? AND collection_id = ?",
			[doc_id, col_id]
		)
		stats["documents_deleted"] += 1
		return

	var payload: Variant = doc.get("payload", {})
	if payload == null:
		payload = {}

	db.execute("""
		INSERT OR REPLACE INTO documents
		(document_id, collection_id, document_type, layer_id, namespace, identifier,
		 update_key, is_tombstone, is_archived, is_moved, payload)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?)
	""", [
		doc_id,
		col_id,
		doc.get("document_type", ""),
		doc.get("layer_id", ""),
		doc.get("namespace", "document"),
		doc.get("identifier"),
		doc.get("update_key", 0),
		JSON.stringify(payload),
	])
	stats["documents_upserted"] += 1


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

func _git_clone(repo_url: String, local_path: String, token: String) -> String:
	DirAccess.make_dir_recursive_absolute(local_path.get_base_dir())
	var auth_url := _build_auth_url(repo_url, token)
	var output: Array = []
	var exit := OS.execute("git", ["clone", auth_url, local_path], output, true)
	if exit != 0:
		return "git clone failed (exit %d): %s" % [exit, _join_output(output)]
	return ""


func _git_rev_parse(local_path: String, ref: String) -> String:
	var output: Array = []
	var exit := OS.execute("git", ["-C", local_path, "rev-parse", ref], output, false)
	if exit != 0 or output.is_empty():
		return ""
	return (output[0] as String).strip_edges()


func _git_available() -> bool:
	return OS.execute("git", ["--version"], []) == 0


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

func _parse_json_file(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	return JSON.parse_string(file.get_as_text())


## Reads a named credential (e.g. "token" or "api_key") from the credentials file.
func _read_credential(key: String) -> String:
	if not FileAccess.file_exists(CREDENTIALS_FILE):
		push_error("TarinoiImporter: credentials file not found — use Tools > Tarinoi: Set Token…")
		return ""
	var file := FileAccess.open(CREDENTIALS_FILE, FileAccess.READ)
	if file == null:
		push_error("TarinoiImporter: cannot open credentials file")
		return ""
	var prefix := key.to_lower() + "="
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.to_lower().begins_with(prefix):
			return line.substr(prefix.length()).strip_edges()
	push_error("TarinoiImporter: no '%s=' entry in credentials file" % key)
	return ""


func _read_token() -> String:
	return _read_credential("token")


func _build_auth_url(repo_url: String, token: String) -> String:
	for scheme in ["https://", "http://"]:
		if repo_url.begins_with(scheme):
			return scheme + "oauth2:" + token + "@" + repo_url.substr(scheme.length())
	return repo_url


func _slug_from_url(repo_url: String) -> String:
	return repo_url.get_file().trim_suffix(".git")


func _get_local_path(project_id: String) -> String:
	return ProjectSettings.globalize_path("user://tarinoi/repos/" + project_id)


func _empty_stats() -> Dictionary:
	return {
		"documents_upserted":  0,
		"documents_deleted":   0,
		"collections_updated": 0,
		"warnings":            [],
	}


func _split_lines(output: Array) -> PackedStringArray:
	if output.is_empty():
		return PackedStringArray()
	return (output[0] as String).split("\n", false)


func _join_output(output: Array) -> String:
	return "\n".join(output) if output.size() > 0 else ""


func _is_busy() -> bool:
	return _thread != null and _thread.is_alive()


func _join_thread() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
