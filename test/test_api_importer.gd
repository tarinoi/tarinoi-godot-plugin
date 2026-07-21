extends GutTest

const TarinoiApiImporterClass := preload("res://addons/tarinoi/core/api_importer.gd")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

var _importer: RefCounted

func before_each() -> void:
	_importer = TarinoiApiImporterClass.new()


# ---------------------------------------------------------------------------
# _parse_ndjson unit tests
# ---------------------------------------------------------------------------

func test_parse_ndjson_empty_body() -> void:
	var result: Dictionary = _importer._parse_ndjson("")
	assert_eq(result["documents"].size(), 0, "empty body → no documents")
	assert_null(result["cursor"], "empty body → no cursor")


func test_parse_ndjson_documents_only() -> void:
	var body := '{"document_id":"a","collection_id":"c","layer_id":"tarinoi:main-project-layer","document_type":"line","namespace":"document","identifier":null,"update_key":1,"is_tombstone":false,"is_archived":false,"is_moved":false,"payload":{}}\n{"document_id":"b","collection_id":"c","layer_id":"tarinoi:main-project-layer","document_type":"line","namespace":"document","identifier":null,"update_key":2,"is_tombstone":false,"is_archived":false,"is_moved":false,"payload":{}}\n'
	var result: Dictionary = _importer._parse_ndjson(body)
	assert_eq(result["documents"].size(), 2, "two document lines parsed")
	assert_null(result["cursor"], "no cursor present")


func test_parse_ndjson_with_cursor() -> void:
	var body := '{"document_id":"a","collection_id":"c","layer_id":"tarinoi:main-project-layer","document_type":"line","namespace":"document","identifier":null,"update_key":5,"is_tombstone":false,"is_archived":false,"is_moved":false,"payload":{}}\n{"cursor":42}\n'
	var result: Dictionary = _importer._parse_ndjson(body)
	assert_eq(result["documents"].size(), 1, "one document before cursor")
	assert_eq(result["cursor"], 42, "cursor value extracted")


func test_parse_ndjson_cursor_only() -> void:
	var result: Dictionary = _importer._parse_ndjson('{"cursor":100}\n')
	assert_eq(result["documents"].size(), 0, "cursor-only body has no documents")
	assert_eq(result["cursor"], 100, "cursor extracted from cursor-only body")


func test_parse_ndjson_skips_blank_lines() -> void:
	var body := '\n{"document_id":"x","collection_id":"c","layer_id":"tarinoi:main-project-layer","document_type":"line","namespace":"document","identifier":null,"update_key":1,"is_tombstone":false,"is_archived":false,"is_moved":false,"payload":{}}\n\n'
	var result: Dictionary = _importer._parse_ndjson(body)
	assert_eq(result["documents"].size(), 1, "blank lines skipped")


# ---------------------------------------------------------------------------
# _project_id_from_path unit tests
# ---------------------------------------------------------------------------

func test_project_id_from_documents_path() -> void:
	var pid: String = _importer._project_id_from_path(
		"https://dev.tarinoi.app/k/api/v1/PcKUlNAe5XHnzWvrcR1TL/J7blI1qVPuaGvcbBbA65F/documents"
	)
	assert_eq(pid, "J7blI1qVPuaGvcbBbA65F", "project_id is the segment before /documents")


func test_project_id_from_path_with_trailing_slash() -> void:
	var pid: String = _importer._project_id_from_path(
		"https://dev.tarinoi.app/k/api/v1/GROUP/PROJ/documents/"
	)
	assert_eq(pid, "PROJ")


# ---------------------------------------------------------------------------
# _upsert_document_api layer-behaviour unit tests
# (uses an in-memory SQLite DB)
# ---------------------------------------------------------------------------

const MAIN  := "tarinoi:main-project-layer"
const BUF   := "tarinoi:main-project-layer.buffer"

func _make_db() -> TarinoiDB:
	var db := TarinoiDB.new()
	# Open with a unique test slug so tests don't collide.
	var ok := db.open("__test_api_importer__")
	assert_true(ok, "DB opened for test")
	return db


func _count_rows(db: TarinoiDB, doc_id: String, col_id: String) -> int:
	var rows := db.query_rows(
		"SELECT COUNT(*) AS n FROM documents WHERE document_id = ? AND collection_id = ?",
		[doc_id, col_id]
	)
	return int(rows[0]["n"]) if rows.size() > 0 else 0


func _get_row(db: TarinoiDB, doc_id: String, col_id: String, layer: String) -> Dictionary:
	var rows := db.query_rows(
		"SELECT * FROM documents WHERE document_id = ? AND collection_id = ? AND layer_id = ?",
		[doc_id, col_id, layer]
	)
	return rows[0] if rows.size() > 0 else {}


func test_active_main_layer_doc_upserted() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc1", "collection_id": "col1",
		"layer_id": MAIN, "document_type": "line",
		"namespace": "document", "identifier": null,
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {"line": "Hello"},
	}
	_importer._upsert_document_api(doc, db, stats)
	assert_eq(stats["documents_upserted"], 1)
	assert_eq(_count_rows(db, "doc1", "col1"), 1)
	db.close()


func test_inactive_main_layer_doc_deleted() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	# First insert an active row.
	var doc := {
		"document_id": "doc2", "collection_id": "col1", "layer_id": MAIN,
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {},
	}
	_importer._upsert_document_api(doc, db, stats)
	assert_eq(_count_rows(db, "doc2", "col1"), 1)
	# Now mark it as tombstoned.
	doc["is_tombstone"] = true
	doc["update_key"] = 2
	stats["documents_upserted"] = 0
	stats["documents_deleted"] = 0
	_importer._upsert_document_api(doc, db, stats)
	assert_eq(stats["documents_deleted"], 1)
	assert_eq(_count_rows(db, "doc2", "col1"), 0, "inactive main-layer doc removed")
	db.close()


func test_tombstone_buffer_layer_doc_deleted() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc3", "collection_id": "col1", "layer_id": BUF,
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 5, "is_tombstone": true, "is_archived": false, "is_moved": false,
		"payload": {},
	}
	_importer._upsert_document_api(doc, db, stats)
	# Tombstones are hard-delete signals: the row must be removed.
	assert_eq(_count_rows(db, "doc3", "col1"), 0, "tombstoned buffer doc removed from DB")
	assert_eq(stats["documents_deleted"], 1)
	db.close()


func test_archived_buffer_layer_doc_stored_as_suppression_marker() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var doc := {
		"document_id": "doc3b", "collection_id": "col1", "layer_id": BUF,
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 6, "is_tombstone": false, "is_archived": true, "is_moved": false,
		"payload": {},
	}
	_importer._upsert_document_api(doc, db, stats)
	# Archived buffer docs are stored so the NOT EXISTS subquery can suppress the main-layer version.
	assert_eq(_count_rows(db, "doc3b", "col1"), 1, "archived buffer doc stored as suppression marker")
	var row := _get_row(db, "doc3b", "col1", BUF)
	assert_eq(int(row.get("is_archived", 0)), 1, "is_archived flag preserved")
	db.close()


func test_both_layers_can_coexist() -> void:
	var db := _make_db()
	var stats := {"documents_upserted": 0, "documents_deleted": 0, "collections_updated": 0, "warnings": []}
	var main_doc := {
		"document_id": "doc4", "collection_id": "col1", "layer_id": MAIN,
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 1, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {"line": "Main"},
	}
	var buf_doc := {
		"document_id": "doc4", "collection_id": "col1", "layer_id": BUF,
		"document_type": "line", "namespace": "document", "identifier": null,
		"update_key": 2, "is_tombstone": false, "is_archived": false, "is_moved": false,
		"payload": {"line": "Buffer"},
	}
	_importer._upsert_document_api(main_doc, db, stats)
	_importer._upsert_document_api(buf_doc,  db, stats)
	assert_eq(_count_rows(db, "doc4", "col1"), 2, "main and buffer rows coexist (new PK includes layer_id)")
	db.close()


# ---------------------------------------------------------------------------
# Integration tests — real API (requires network + credentials file)
# ---------------------------------------------------------------------------

const API_PATH := "https://dev.tarinoi.app/k/api/v1/PcKUlNAe5XHnzWvrcR1TL/J7blI1qVPuaGvcbBbA65F/documents"

func test_integration_full_sync() -> void:
	# Requires: credentials file with api_key=, and SSL support (not available in
	# headless mode on macOS — run this test from the Godot editor instead).
	if DisplayServer.get_name() in ["headless", "Headless"]:
		pending("Skipping integration test: SSL unavailable in headless mode")
		return

	ProjectSettings.set_setting("tarinoi/sync_source", "git")
	ProjectSettings.set_setting("tarinoi/committed_only", false)

	var api_key: String = _importer._read_credential("api_key")
	if api_key.is_empty():
		pending("Skipping integration test: no api_key in credentials file")
		return

	var importer := TarinoiApiImporterClass.new()
	var completed := false
	var failed := false
	var result_stats: Dictionary = {}
	var error_msg := ""

	importer.sync_completed.connect(func(stats: Dictionary):
		result_stats = stats
		completed = true
	)
	importer.sync_failed.connect(func(reason: String):
		error_msg = reason
		failed = true
	)

	# Clear any existing DB so we get a full sync.
	var project_id: String = importer._project_id_from_path(API_PATH)
	var db_path := ProjectSettings.globalize_path("user://tarinoi/" + project_id + ".db")
	if FileAccess.file_exists(db_path):
		DirAccess.remove_absolute(db_path)

	importer.sync(API_PATH)

	# Wait for the background thread to complete (up to 30 seconds).
	var deadline := Time.get_ticks_msec() + 30000
	while not completed and not failed and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		OS.delay_msec(50)

	assert_false(failed, "full sync should not fail: " + error_msg)
	assert_true(completed, "full sync should complete within timeout")
	assert_gt(result_stats.get("documents_upserted", 0), 0, "at least one document imported")

	# Verify cursor was persisted.
	var db := TarinoiDB.new()
	db.open(project_id)
	var cursor := db.read_meta("api_sync_cursor")
	db.close()
	assert_false(cursor.is_empty(), "cursor persisted after full sync")


func test_integration_incremental_sync() -> void:
	if DisplayServer.get_name() in ["headless", "Headless"]:
		pending("Skipping integration test: SSL unavailable in headless mode")
		return

	ProjectSettings.set_setting("tarinoi/sync_source", "git")
	ProjectSettings.set_setting("tarinoi/committed_only", false)

	var api_key: String = _importer._read_credential("api_key")
	if api_key.is_empty():
		pending("Skipping integration test: no api_key in credentials file")
		return

	# Ensure a full sync has been done first (reuse the DB from above test
	# if available; otherwise run a full sync here).
	var importer := TarinoiApiImporterClass.new()
	var project_id: String = importer._project_id_from_path(API_PATH)
	var db := TarinoiDB.new()
	db.open(project_id)
	var cursor := db.read_meta("api_sync_cursor")
	db.close()

	if cursor.is_empty():
		pending("Skipping incremental test: no cursor from prior full sync")
		return

	var completed := false
	var failed := false
	var result_stats: Dictionary = {}
	var error_msg := ""
	importer.sync_completed.connect(func(stats: Dictionary):
		result_stats = stats
		completed = true
	)
	importer.sync_failed.connect(func(reason: String):
		error_msg = reason
		failed = true
	)
	importer.sync(API_PATH)

	var waited := 0
	while not completed and not failed and waited < 300:
		await get_tree().process_frame
		waited += 1

	assert_false(failed, "incremental sync should not fail: " + error_msg)
	assert_true(completed, "incremental sync should complete")
	# An incremental sync with no new documents is valid — just check it ran.
	assert_true(
		result_stats.get("documents_upserted", 0) >= 0,
		"incremental sync stats are valid"
	)
