class_name TarinoiApiImporter
extends RefCounted

signal sync_started()
signal sync_completed(stats: Dictionary)
signal sync_failed(reason: String)
signal sync_progress(message: String, fraction: float)

const CREDENTIALS_FILE := "user://tarinoi/.credentials"
const MAIN_LAYER  := "tarinoi:main-project-layer"
const BUF_LAYER   := "tarinoi:main-project-layer.buffer"

# HTTPClient poll timeout: give up after this many iterations with no data.
const POLL_TIMEOUT_ITERS := 3000

var _thread: Thread = null
var _version_check := TarinoiDataVersion.new()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Kick off a full-or-incremental sync from the Tarinoi REST API.
## api_path must end with "/documents", e.g.
##   https://dev.tarinoi.app/k/api/v1/<groupId>/<projectId>/documents
func sync(api_path: String) -> void:
	if _is_busy():
		push_warning("TarinoiApiImporter: operation already in progress")
		return
	sync_started.emit()
	_thread = Thread.new()
	_thread.start(_thread_sync.bind(api_path))


# ---------------------------------------------------------------------------
# Thread entry point + completion
# ---------------------------------------------------------------------------

func _thread_sync(api_path: String) -> void:
	var result := _do_sync(api_path)
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

func _do_sync(api_path: String) -> Dictionary:
	var api_key := _read_credential("api_key")
	if api_key.is_empty():
		return {"error": "No API key saved — use Tools > Tarinoi: Set Tarinoi API token…"}

	var project_id := _project_id_from_path(api_path)
	if project_id.is_empty():
		return {"error": "Cannot derive project_id from api_path: %s" % api_path}

	var db := TarinoiDB.new()
	if not db.open(project_id):
		return {"error": "Failed to open SQLite database for '%s'" % project_id}

	db.write_meta("project_id", project_id)
	db.write_meta("api_path", api_path)

	var cursor := db.read_meta("api_sync_cursor")
	var is_incremental := not cursor.is_empty()

	if is_incremental:
		call_deferred("emit_signal", "sync_progress", "Fetching changes since cursor %s…" % cursor, 0.1)
	else:
		call_deferred("emit_signal", "sync_progress", "Starting full sync…", 0.0)

	var result := _run_sync(api_path, api_key, cursor, db)
	db.close()
	return result


# ---------------------------------------------------------------------------
# Sync loop: paginate until no more cursor
# ---------------------------------------------------------------------------

func _run_sync(api_path: String, api_key: String, start_cursor: String, db: TarinoiDB) -> Dictionary:
	var stats := _empty_stats()
	var skip_tls: bool = ProjectSettings.get_setting("tarinoi/api/skip_tls_verify", false)

	var parsed_url := _parse_url(api_path)
	if parsed_url.is_empty():
		return {"error": "Cannot parse api_path URL: %s" % api_path}

	var scheme: String  = parsed_url["scheme"]
	var host: String    = parsed_url["host"]
	var port: int       = parsed_url["port"]
	var base_path: String = parsed_url["path"]

	var cursor := start_cursor
	var cursor_advanced := false
	var page := 0

	while true:
		var query_path := base_path
		if not cursor.is_empty():
			query_path += "?cursor=" + cursor

		call_deferred("emit_signal", "sync_progress",
			"Fetching page %d…" % page, clampf(0.1 + page * 0.05, 0.1, 0.9))

		var fetch_result := _fetch_page(host, port, query_path, api_key, scheme == "https", skip_tls)
		if fetch_result.has("error"):
			return {"error": fetch_result["error"]}

		var body: String = fetch_result["body"]
		var parsed := _parse_ndjson(body)

		for doc in parsed["documents"]:
			var dv_err := _version_check.check((doc as Dictionary).get("data_version"))
			if not dv_err.is_empty():
				return {"error": dv_err}
			_upsert_document_api(doc as Dictionary, db, stats)

		var new_cursor: Variant = parsed["cursor"]
		if new_cursor != null:
			cursor = str(new_cursor)
			cursor_advanced = true
			db.write_meta("api_sync_cursor", cursor)
			page += 1
		else:
			break

	# If the API didn't supply an explicit pagination cursor, derive the cursor
	# from the highest update_key in the DB.  This covers both a fresh full sync
	# (cursor starts empty) and an incremental single-page response (cursor starts
	# non-empty but the API returns no new value).
	if not cursor_advanced:
		var rows := db.query_rows("SELECT MAX(update_key) AS max_key FROM documents")
		if rows.size() > 0 and rows[0]["max_key"] != null:
			cursor = str(int(rows[0]["max_key"]))
			db.write_meta("api_sync_cursor", cursor)

	_rebuild_collections(db, stats)
	return {"stats": stats}


# ---------------------------------------------------------------------------
# Collections rebuild
# ---------------------------------------------------------------------------

## Rebuilds the collections table from all collection-manifest documents
## currently in the DB.  Called after every sync so that any collection
## that was stored (including from a previous run) is reflected correctly.
func _rebuild_collections(db: TarinoiDB, stats: Dictionary) -> void:
	var rows := db.query_rows(
		"SELECT document_id, payload FROM documents WHERE document_type = 'collection-manifest' AND is_tombstone = 0 AND is_archived = 0 AND is_moved = 0"
	)
	var count := 0
	for row in rows:
		var doc_id: String   = row["document_id"]
		var payload_str: String = row["payload"]
		var p: Variant = JSON.parse_string(payload_str)
		if not p is Dictionary:
			continue
		var pd := p as Dictionary
		db.execute(
			"INSERT OR REPLACE INTO collections (collection_id, collection_name, collection_type, payload) VALUES (?, ?, ?, ?)",
			[
				doc_id,
				pd.get("label", pd.get("collection_name", "")),
				pd.get("collection_type", ""),
				payload_str,
			]
		)
		count += 1
	stats["collections_updated"] = count


# ---------------------------------------------------------------------------
# HTTP: fetch one page
# ---------------------------------------------------------------------------

func _fetch_page(host: String, port: int, path: String, api_key: String,
		use_tls: bool, skip_tls_verify: bool) -> Dictionary:
	var client := HTTPClient.new()

	var tls_opts: TLSOptions = null
	if use_tls:
		tls_opts = TLSOptions.client_unsafe() if skip_tls_verify else TLSOptions.client()

	var err: int
	if use_tls:
		err = client.connect_to_host(host, port, tls_opts)
	else:
		err = client.connect_to_host(host, port)

	if err != OK:
		return {"error": "Could not connect to '%s' (error %d) — check tarinoi/api/path in Project Settings > Tarinoi and your network connection" % [host, err]}

	# Wait for connection (or TLS handshake)
	var iters := 0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		err = client.poll()
		if err != OK:
			return {"error": "HTTPClient poll error during connect: %d" % err}
		iters += 1
		if iters > POLL_TIMEOUT_ITERS:
			return {"error": "HTTPClient timed out connecting to %s" % host}
		OS.delay_usec(1000)

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"error": "HTTPClient failed to connect to %s (status %d)" % [host, client.get_status()]}

	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Accept: application/x-ndjson",
	])
	err = client.request(HTTPClient.METHOD_GET, path, headers)
	if err != OK:
		return {"error": "HTTPClient request failed: error %d" % err}

	# Wait for response headers
	iters = 0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		err = client.poll()
		if err != OK:
			return {"error": "HTTPClient poll error during request: %d" % err}
		iters += 1
		if iters > POLL_TIMEOUT_ITERS:
			return {"error": "HTTPClient timed out waiting for response from %s" % host}
		OS.delay_usec(1000)

	if not client.has_response():
		return {"error": "HTTPClient: no response from server"}

	var response_code := client.get_response_code()
	if response_code != 200:
		return {"error": "%s (HTTP %d for path: %s)" % [_http_error_hint(response_code), response_code, path]}

	# Read body
	var body_bytes := PackedByteArray()
	iters = 0
	while client.get_status() == HTTPClient.STATUS_BODY:
		err = client.poll()
		if err != OK:
			return {"error": "HTTPClient poll error reading body: %d" % err}
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			body_bytes.append_array(chunk)
			iters = 0
		else:
			iters += 1
			if iters > POLL_TIMEOUT_ITERS:
				return {"error": "HTTPClient timed out reading response body"}
			OS.delay_usec(1000)

	return {"body": body_bytes.get_string_from_utf8()}


# ---------------------------------------------------------------------------
# NDJSON parsing
# ---------------------------------------------------------------------------

## Splits an NDJSON body into document objects and an optional trailing cursor.
## Returns: { "documents": Array[Dictionary], "cursor": Variant (null if absent) }
func _parse_ndjson(body: String) -> Dictionary:
	var documents: Array = []
	var cursor: Variant = null

	for raw_line in body.split("\n"):
		var line := (raw_line as String).strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed == null or not parsed is Dictionary:
			continue
		var obj := parsed as Dictionary
		if obj.has("cursor") and obj.size() == 1:
			cursor = obj["cursor"]
		else:
			documents.append(obj)

	return {"documents": documents, "cursor": cursor}


# ---------------------------------------------------------------------------
# Upsert: buffer-aware layer logic
# ---------------------------------------------------------------------------

## Tombstones are hard-delete signals from the server: remove the matching row
## from the client DB regardless of layer.  Archived/moved documents are stored
## with their flags intact; in the buffer layer they act as suppression markers
## (the NOT EXISTS subquery in active_filter() hides the main-layer version).
## Collection manifests are also evicted from the collections table (used by codegen)
## when tombstoned; _rebuild_collections() repopulates that table after each sync.
func _upsert_document_api(doc: Dictionary, db: TarinoiDB, stats: Dictionary) -> void:
	var doc_id: String = doc.get("document_id", "")
	var col_id: String = doc.get("collection_id", "")
	var layer:  String = doc.get("layer_id", "")
	if doc_id.is_empty() or col_id.is_empty():
		return

	if doc.get("is_tombstone", false):
		# Hard delete: the server instructs the client to remove this row.
		db.execute(
			"DELETE FROM documents WHERE document_id = ? AND collection_id = ? AND layer_id = ?",
			[doc_id, col_id, layer]
		)
		# Also evict from collections table if this was a collection manifest.
		db.execute("DELETE FROM collections WHERE collection_id = ?", [doc_id])
		stats["documents_deleted"] += 1
		return

	var is_archived: bool = doc.get("is_archived", false)
	var is_moved:    bool = doc.get("is_moved",    false)
	var payload: Variant  = doc.get("payload", {})
	if payload == null:
		payload = {}

	db.execute("""
		INSERT OR REPLACE INTO documents
		(document_id, collection_id, document_type, layer_id, namespace, identifier,
		 update_key, is_tombstone, is_archived, is_moved, payload)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
	""", [
		doc_id,
		col_id,
		doc.get("document_type", ""),
		layer,
		doc.get("namespace", "document"),
		doc.get("identifier"),
		doc.get("update_key", 0),
		1 if is_archived else 0,
		1 if is_moved    else 0,
		JSON.stringify(payload),
	])

	if is_archived or is_moved:
		stats["documents_deleted"] += 1
	else:
		stats["documents_upserted"] += 1


# ---------------------------------------------------------------------------
# URL helpers
# ---------------------------------------------------------------------------

## Parses a URL into {scheme, host, port, path}.
func _parse_url(url: String) -> Dictionary:
	var scheme := ""
	var rest := url
	if url.begins_with("https://"):
		scheme = "https"
		rest = url.substr(8)
	elif url.begins_with("http://"):
		scheme = "http"
		rest = url.substr(7)
	else:
		return {}

	var slash_pos := rest.find("/")
	var host_port := rest.substr(0, slash_pos) if slash_pos >= 0 else rest
	var path      := rest.substr(slash_pos)    if slash_pos >= 0 else "/"

	var default_port := 443 if scheme == "https" else 80
	var port := default_port
	var colon_pos := host_port.rfind(":")
	if colon_pos >= 0:
		port = int(host_port.substr(colon_pos + 1))
		host_port = host_port.substr(0, colon_pos)

	return {"scheme": scheme, "host": host_port, "port": port, "path": path}


## Derives the project_id (DB file slug) from the api_path.
## e.g. .../v1/<groupId>/<projectId>/documents → <projectId>
func _project_id_from_path(api_path: String) -> String:
	var stripped := api_path.trim_suffix("/")
	stripped = stripped.trim_suffix("/documents")
	return stripped.get_file()


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

func _read_credential(key: String) -> String:
	if not FileAccess.file_exists(CREDENTIALS_FILE):
		return ""
	var file := FileAccess.open(CREDENTIALS_FILE, FileAccess.READ)
	if file == null:
		return ""
	var prefix := key.to_lower() + "="
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.to_lower().begins_with(prefix):
			return line.substr(prefix.length()).strip_edges()
	return ""


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

## Translates a non-200 HTTP status into an actionable hint for self-diagnosis.
func _http_error_hint(response_code: int) -> String:
	match response_code:
		401, 403:
			return "API sync failed: rejected credentials — check your API token (Tools > Tarinoi: Set Tarinoi API token…)"
		404:
			return "API sync failed: project not found — check tarinoi/api/path in Project Settings > Tarinoi"
		_:
			if response_code >= 500:
				return "API sync failed: server error — the Tarinoi API may be temporarily unavailable, try again shortly"
			return "API sync failed: unexpected response"


func _empty_stats() -> Dictionary:
	return {
		"documents_upserted":  0,
		"documents_deleted":   0,
		"collections_updated": 0,
		"warnings":            [],
	}


func _is_busy() -> bool:
	return _thread != null and _thread.is_alive()


func _join_thread() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
